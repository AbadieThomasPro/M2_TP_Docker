#!/bin/sh
# Autoscaler de la stack Swarm : ajoute ou retire des instances selon le CPU et la mémoire mesurés.
# Swarm n'a pas d'autoscaling natif : ce script le fait avec le client docker (via le socket de l'hôte).
# Seuils issus du benchmark (README, partie Scalabilité) ; aucun nom de service en dur : il ne pilote
# que les services portant le label autoscale.enabled=true, entre leurs labels autoscale.min et autoscale.max.

# Variable non définie = erreur : une faute de frappe ne doit pas donner un seuil vide
set -u

INTERVAL=${AUTOSCALE_INTERVAL_S:-10}
CPU_UP=${AUTOSCALE_CPU_UP:-70}
CPU_DOWN=${AUTOSCALE_CPU_DOWN:-25}
MEM_UP=${AUTOSCALE_MEM_UP:-80}
MEM_DOWN=${AUTOSCALE_MEM_DOWN:-50}
UP_SAMPLES=${AUTOSCALE_UP_SAMPLES:-3}
DOWN_SAMPLES=${AUTOSCALE_DOWN_SAMPLES:-6}
COOLDOWN_UP=${AUTOSCALE_COOLDOWN_UP_S:-30}
COOLDOWN_DOWN=${AUTOSCALE_COOLDOWN_DOWN_S:-60}
HOST_BUDGET=${AUTOSCALE_HOST_BUDGET_PCT:-80}
HEARTBEAT=${HEARTBEAT_FILE:-/tmp/heartbeat}
STATS_FILE=/tmp/stats

# Mode healthcheck : sain si la dernière boucle date de moins de 3 intervalles (pas de réseau à tester)
if [ "${1:-}" = "--healthcheck" ]; then
  [ -f "$HEARTBEAT" ] || exit 1
  age=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT") ))
  [ "$age" -le $(( INTERVAL * 3 )) ]
  exit
fi

# Dates en UTC : pas de tzdata dans l'image, comme le cleaner
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

# État par service (relevés consécutifs, date de la dernière action) en variables shell : un seul
# processus, rien sur disque. Le nom du service devient un suffixe de variable valide
key() { echo "$1" | tr -c 'A-Za-z0-9\n' '_'; }
get() { eval "echo \${${1}_${2}:-0}"; }
put() { eval "${1}_${2}=\$3"; }

# SIGTERM (docker stop, mise à jour du service) : on n'attend pas la fin du relevé en cours,
# il est arrêté tout de suite ; aucune décision n'est à moitié prise, sortie en 0
stop=0
job_pid=""
trap 'stop=1; [ -n "$job_pid" ] && kill "$job_pid" 2>/dev/null' TERM INT

# Un seul docker stats pour tous les services à chaque boucle (et pas un par service) : ~2 s de CPU
# en moins par service. En arrière-plan + wait : le trap s'exécute dès l'arrivée du signal
collect_stats() {
  docker stats --no-stream --format '{{.Name}};{{.CPUPerc}};{{.MemPerc}}' > "$STATS_FILE" 2>/dev/null &
  job_pid=$!
  wait "$job_pid"
  job_pid=""
}

# "instances CPU% mémoire%" d'un service. Le CPU est la MOYENNE des instances, en % de la LIMITE du
# service : docker stats le donne en % d'un cœur (une instance saturée à 0,65 CPU affiche 65 %, elle
# n'atteindrait jamais un seuil de 70 %), et une somme grandirait avec le nombre d'instances (deux erreurs
# de l'exemple fourni). La mémoire est celle de la PIRE instance : une seule tuée par OOM fait échouer
# des requêtes ; MemPerc est déjà rapporté à la limite du conteneur
svc_metrics() {
  awk -F';' -v prefix="$1." -v nano="$2" '
    index($1, prefix) == 1 {
      gsub(/%/, "", $2); gsub(/%/, "", $3)
      n++; cpu += $2
      if ($3 + 0 > mem) mem = $3 + 0
    }
    END {
      if (n == 0) { print 0, 0, 0; exit }
      limit = (nano > 0) ? nano / 1e9 : 1
      printf "%d %d %d\n", n, cpu / n / limit, mem
    }' "$STATS_FILE"
}

# Garde-fou machine : la somme des limites de TOUTES les instances de tous les services, plus l'instance
# demandée, doit rester sous HOST_BUDGET % du CPU et de la mémoire de l'hôte. Les limites par service
# protègent d'une instance qui s'emballe, pas d'une multiplication d'instances : c'est ce contrôle-là
# qui garantit que la machine ne dépasse jamais 80 %. Renvoie "cpu% mem% accepté(0/1)"
host_budget() {
  docker service inspect $(docker service ls -q) --format \
    '{{.Spec.TaskTemplate.Resources.Limits.NanoCPUs}} {{.Spec.TaskTemplate.Resources.Limits.MemoryBytes}} {{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{else}}1{{end}}' 2>/dev/null |
  awk -v addc="$1" -v addm="$2" -v ncpu="$HOST_CPUS" -v hmem="$HOST_MEM" -v pct="$HOST_BUDGET" '
    { c += $1 * $3; m += $2 * $3 }
    END {
      c += addc; m += addm
      ok = (c <= ncpu * 1e9 * pct / 100) && (m <= hmem * pct / 100)
      printf "%d %d %d\n", c / 1e9 / ncpu * 100, m / hmem * 100, ok
    }'
}

# --detach : la commande rend la main tout de suite, la boucle continue de mesurer pendant que Swarm
# démarre ou arrête l'instance
scale() {
  log "$1 : $2 -> $3 instance(s) ($4)"
  docker service scale --detach "$1=$3" > /dev/null 2>&1 || log "$1 : ERREUR, docker service scale a échoué"
}

decide() {
  svc=$1
  read -r min max nano membytes want <<EOF
$(docker service inspect "$svc" --format '{{index .Spec.Labels "autoscale.min"}} {{index .Spec.Labels "autoscale.max"}} {{.Spec.TaskTemplate.Resources.Limits.NanoCPUs}} {{.Spec.TaskTemplate.Resources.Limits.MemoryBytes}} {{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null)
EOF
  # Labels absents ou faux : on ne touche pas au service plutôt que de deviner des bornes
  for v in "$min" "$max" "$nano" "$membytes" "$want"; do
    is_int "$v" || { log "$svc : labels autoscale.min / autoscale.max invalides, service ignoré"; return; }
  done

  read -r running cpu mem <<EOF
$(svc_metrics "$svc" "$nano")
EOF
  summary="$summary ${svc#*_}=${running}/${want} cpu=${cpu}% mem=${mem}%"
  k=$(key "$svc")
  now=$(date +%s)

  # Nombre d'instances hors bornes (scale manuel excessif, labels modifiés) : on le ramène dans les bornes.
  # Le plafond est donc respecté même si quelqu'un d'autre a changé le service
  if [ "$want" -lt "$min" ] || [ "$want" -gt "$max" ]; then
    target=$want
    [ "$want" -lt "$min" ] && target=$min
    [ "$want" -gt "$max" ] && target=$max
    scale "$svc" "$want" "$target" "hors des bornes $min-$max"
    put last "$k" "$now"
    return
  fi

  # Changement en cours (instance qui démarre ou s'arrête) : les mesures ne portent que sur une partie
  # des instances, on attend qu'elles soient toutes là avant de compter de nouveaux relevés
  if [ "$running" -ne "$want" ]; then
    put up "$k" 0; put down "$k" 0
    return
  fi

  up=$(get up "$k"); down=$(get down "$k"); last=$(get last "$k")

  # Hystérésis : on monte au-dessus de 70 %, on ne descend qu'en dessous de 25 %. Entre les deux, rien :
  # sans cet écart, une instance retirée ferait remonter la charge et le service oscillerait
  if [ "$cpu" -gt "$CPU_UP" ] || [ "$mem" -gt "$MEM_UP" ]; then
    up=$((up + 1)); down=0
  elif [ "$cpu" -lt "$CPU_DOWN" ] && [ "$mem" -lt "$MEM_DOWN" ]; then
    down=$((down + 1)); up=0
  else
    up=0; down=0
  fi

  # Plusieurs relevés de suite : un pic isolé (une grosse requête) ne crée pas d'instance.
  # Délai après une action : la nouvelle instance doit avoir le temps de prendre sa part de la charge
  if [ "$up" -ge "$UP_SAMPLES" ] && [ $((now - last)) -ge "$COOLDOWN_UP" ]; then
    up=0
    if [ "$want" -ge "$max" ]; then
      log "$svc : surcharge (cpu $cpu %, mem $mem %) mais plafond de $max instance(s) atteint"
    else
      read -r bcpu bmem ok <<EOF
$(host_budget "$nano" "$membytes")
EOF
      if [ "${ok:-0}" = "1" ]; then
        scale "$svc" "$want" $((want + 1)) "cpu $cpu %, mem $mem % au-dessus des seuils $CPU_UP % / $MEM_UP % sur $UP_SAMPLES relevés ; machine après ajout : cpu $bcpu %, mem $bmem %"
        last=$now
      else
        log "$svc : montée REFUSÉE, la stack dépasserait $HOST_BUDGET % de la machine (cpu ${bcpu:-?} %, mem ${bmem:-?} % après ajout)"
      fi
    fi
  elif [ "$down" -ge "$DOWN_SAMPLES" ] && [ $((now - last)) -ge "$COOLDOWN_DOWN" ]; then
    down=0
    if [ "$want" -gt "$min" ]; then
      scale "$svc" "$want" $((want - 1)) "cpu $cpu %, mem $mem % sous les seuils $CPU_DOWN % / $MEM_DOWN % sur $DOWN_SAMPLES relevés"
      last=$now
    fi
  fi

  put up "$k" "$up"; put down "$k" "$down"; put last "$k" "$last"
}

# Vérifications au démarrage : sans accès au socket, ou hors d'un manager, l'autoscaler ne pourrait
# rien faire. On sort en erreur avec un message clair (Swarm relance la tâche) plutôt que de tourner à vide
info=$(docker info --format '{{.NCPU}} {{.MemTotal}} {{.Swarm.ControlAvailable}}' 2>&1) || {
  log "ERREUR : moteur Docker inaccessible (socket monté ? groupe DOCKER_GID ?) : $info"
  exit 1
}
read -r HOST_CPUS HOST_MEM manager <<EOF
$info
EOF
if [ "$manager" != "true" ]; then
  log "ERREUR : ce nœud n'est pas un manager Swarm, impossible de changer le nombre d'instances"
  exit 1
fi

log "démarrage : relevé toutes les $INTERVAL s ; +1 si cpu > $CPU_UP % ou mem > $MEM_UP % ($UP_SAMPLES relevés, pause $COOLDOWN_UP s) ; -1 si cpu < $CPU_DOWN % et mem < $MEM_DOWN % ($DOWN_SAMPLES relevés, pause $COOLDOWN_DOWN s) ; machine : $HOST_CPUS CPU, plafond $HOST_BUDGET %"

sleep_pid=""
while [ "$stop" -eq 0 ]; do
  collect_stats
  [ "$stop" -eq 1 ] && break
  summary=""
  for svc in $(docker service ls --filter label=autoscale.enabled=true --format '{{.Name}}' 2>/dev/null); do
    decide "$svc"
  done
  log "relevé :${summary:- aucun service avec le label autoscale.enabled=true}"
  # Preuve de vie pour le healthcheck, dans /tmp (tmpfs : le reste du conteneur est en lecture seule)
  touch "$HEARTBEAT"
  [ "$stop" -eq 1 ] && break
  # sleep en arrière-plan + wait : un sleep au premier plan retarderait le trap jusqu'à la fin de l'attente
  sleep "$INTERVAL" &
  sleep_pid=$!
  wait "$sleep_pid"
done

[ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null
log "arrêt propre"
exit 0
