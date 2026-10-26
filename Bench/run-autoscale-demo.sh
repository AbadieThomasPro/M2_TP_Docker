#!/bin/sh
# Démonstration de l'autoscaler (mode Swarm) : charge longue, puis repos, avec le nombre d'instances
# affiché toutes les 10 s. Équivalent Windows : run-autoscale-demo.ps1
#
# Prérequis : stack déployée (./swarm-deploy.sh).
# Usage     : ./Bench/run-autoscale-demo.sh [durée de charge en s] [requêtes en parallèle] [durée de repos en s]
#             ./Bench/run-autoscale-demo.sh 180 50 300

# Variable non définie = erreur, comme dans les scripts des images
set -u
LOAD_S=${1:-180}
CONC=${2:-50}
REST_S=${3:-300}

cd "$(dirname "$0")/.." || exit 1

if [ -z "$(docker service ls -q --filter name=cloud_autoscaler)" ]; then
  echo "Stack Swarm introuvable : la déployer d'abord avec ./swarm-deploy.sh"
  exit 1
fi
# Image de l'outil construite à la demande : la stack Swarm ne la construit pas, ce n'est pas un service de l'application
docker image inspect docker-cloud/bench > /dev/null 2>&1 || docker compose --profile bench build bench

start=$(date +%s)
echo "début $(date +%H:%M:%S) : charge $LOAD_S s à $CONC en parallèle, puis repos $REST_S s"

docker service rm bench > /dev/null 2>&1
# ab en service Swarm ponctuel sur le réseau public de la stack : il attaque le front comme un vrai client.
# -n très grand : sinon ab s'arrête à 50 000 requêtes avant la fin de la durée demandée
docker service create --name bench --network cloud_public --restart-condition none --limit-cpu 1 --limit-memory 32M \
  --detach docker-cloud/bench -t "$LOAD_S" -n 10000000 -c "$CONC" http://front/api/files > /dev/null

# Boucle bornée (nombre de tours fixé) : le script s'arrête toujours seul, rien ne reste en arrière-plan
rounds=$(( (LOAD_S + REST_S) / 10 + 3 ))
i=0
while [ "$i" -lt "$rounds" ]; do
  t=$(( $(date +%s) - start ))
  phase=charge; [ "$t" -ge $(( LOAD_S + 5 )) ] && phase=repos
  echo "t=${t}s $phase $(docker service ls --filter label=autoscale.enabled=true --format '{{.Name}}={{.Replicas}}' | sed 's/^cloud_//; s/ (max.*//' | tr '\n' ' ')"
  sleep 10
  i=$(( i + 1 ))
done

echo "--- résultat de ab"
docker service logs bench --raw 2>&1 | grep -E 'Complete requests|Failed requests|Non-2xx|Requests per second|^ *(50|95|99)%'
docker service rm bench > /dev/null
echo "--- décisions de l'autoscaler"
# Durée relative : une date absolue dépendrait du fuseau de la machine
docker service logs --raw --since "$(( $(date +%s) - start + 5 ))s" cloud_autoscaler 2>&1 | grep -v 'relevé'
echo "fin $(date +%H:%M:%S)"
