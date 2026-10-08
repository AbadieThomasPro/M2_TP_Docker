#!/bin/sh
# Worker de nettoyage du cloud de fichiers éphémères.
# Supprime les fichiers expirés (expiration lue dans le nom : <epoch>-<aléatoire>__<nom>)
# et les envois abandonnés dans .incoming/. N'utilise que BusyBox : aucun paquet à installer.

# Variable non définie = erreur : une faute de frappe ne doit pas viser un mauvais dossier
set -u

STORAGE_DIR=${STORAGE_DIR:-/data/files}
INTERVAL=${CLEANUP_INTERVAL_S:-60}
INCOMING_MAX_AGE_MIN=${INCOMING_MAX_AGE_MIN:-60}
HEARTBEAT=${HEARTBEAT_FILE:-/tmp/heartbeat}

# Mode healthcheck : sain si la dernière passe date de moins de 2 intervalles (pas de réseau nécessaire)
if [ "${1:-}" = "--healthcheck" ]; then
  [ -f "$HEARTBEAT" ] || exit 1
  age=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT") ))
  [ "$age" -le $(( INTERVAL * 2 )) ]
  exit
fi

# Dates en UTC : pas de tzdata dans l'image, on l'indique plutôt que d'afficher une heure trompeuse
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# Noms des fichiers expirés (date du nom <= maintenant), un par ligne.
# awk filtre tout en un seul processus au lieu d'un test par fichier
expired_files() {
  ls -1 "$STORAGE_DIR" | awk -F- -v now="$1" '$1 ~ /^[0-9]+$/ && $1 + 0 <= now'
}

# Sous-commande lancée par clean_pass : suppression rapide par lots (xargs regroupe des centaines de
# noms par appel à rm, au lieu d'un processus par fichier, trop lent avec un dixième de CPU).
# Séparateur \0 : les noms peuvent contenir des espaces
if [ "${1:-}" = "--delete-expired" ]; then
  cd "$STORAGE_DIR" || exit 1
  expired_files "$2" | tr '\n' '\0' | xargs -0 -r rm -f -- 2>/dev/null
  exit 0
fi

# SIGTERM (docker stop) : la suppression en cours est arrêtée immédiatement. C'est sans risque :
# chaque suppression (unlink) est atomique, un fichier est soit supprimé, soit intact, jamais à
# moitié. Le reste sera traité au prochain démarrage. Le worker sort ensuite proprement (code 0),
# en moins d'1 s quel que soit le nombre de fichiers, donc jamais tué au bout des 10 s.
stop=0
job_pid=""
trap 'stop=1; log "SIGTERM reçu : arrêt de la suppression en cours (chaque suppression est atomique)"; [ -n "$job_pid" ] && kill -TERM "-$job_pid" 2>/dev/null' TERM INT

clean_pass() {
  start=$(date +%s)
  before=$(expired_files "$start" | wc -l)
  # Le signal a pu arriver pendant ce comptage (plusieurs secondes sur des milliers de fichiers
  # avec peu de CPU) : on ne lance pas une suppression qu'il faudrait aussitôt interrompre
  [ "$stop" -eq 1 ] && return

  # Suppression en arrière-plan + wait : le trap s'exécute dès l'arrivée du signal, sans attendre
  # la fin. setsid la place dans son propre groupe de processus : le trap arrête tout le groupe
  # (sh, awk, xargs, rm) d'un coup, sans laisser d'orphelin
  setsid "$0" --delete-expired "$start" &
  job_pid=$!
  wait "$job_pid"
  # Un wait interrompu par le signal rend la main tout de suite : on attend la vraie fin du groupe
  wait "$job_pid" 2>/dev/null
  job_pid=""

  # Arrêt demandé : pas de bilan (relister des milliers de fichiers retarderait l'arrêt pour rien),
  # les fichiers restants seront traités au prochain démarrage
  if [ "$stop" -eq 1 ]; then
    log "passe interrompue après $(( $(date +%s) - start )) s"
    return
  fi

  remaining=$(expired_files "$start" | wc -l)
  # Contrôle après coup : un refus de droits (rm qui échoue) ne doit pas passer inaperçu
  refused=0
  if [ "$remaining" -gt 0 ]; then
    refused=$remaining
    log "ERREUR : $refused fichier(s) expiré(s) non supprimé(s) (droits du dossier ?) ; exemple : $(expired_files "$start" | head -n 1)"
  fi

  # Envois abandonnés : un .part plus vieux que INCOMING_MAX_AGE_MIN ne sera jamais terminé
  abandoned=$(find "$STORAGE_DIR/.incoming" -type f -name '*.part' -mmin +"$INCOMING_MAX_AGE_MIN" 2>/dev/null | wc -l)
  find "$STORAGE_DIR/.incoming" -type f -name '*.part' -mmin +"$INCOMING_MAX_AGE_MIN" -exec rm -f -- {} + 2>/dev/null

  log "passe terminée en $(( $(date +%s) - start )) s : $(( before - remaining )) expiré(s) supprimé(s), $abandoned envoi(s) abandonné(s), $refused refus"
}

log "démarrage : dossier $STORAGE_DIR, passe toutes les $INTERVAL s, envois abandonnés après $INCOMING_MAX_AGE_MIN min"

sleep_pid=""
while [ "$stop" -eq 0 ]; do
  clean_pass
  # Preuve de vie pour le healthcheck, écrite dans /tmp (tmpfs : le reste du conteneur est en lecture seule)
  touch "$HEARTBEAT"
  [ "$stop" -eq 1 ] && break
  # sleep en arrière-plan + wait : un sleep au premier plan bloquerait le trap jusqu'à la fin de
  # l'attente ; wait, lui, est interrompu immédiatement par le signal
  sleep "$INTERVAL" &
  sleep_pid=$!
  wait "$sleep_pid"
done

# Une attente interrompue laisse un sleep orphelin : on le termine avant de sortir
# (variable vide si l'arrêt est arrivé pendant la toute première passe)
[ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null
log "arrêt propre"
exit 0
