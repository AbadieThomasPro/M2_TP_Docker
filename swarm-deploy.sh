#!/bin/sh
# Déploie la stack en mode Swarm (scalabilité). Équivalent Windows : swarm-deploy.ps1
#
# Usage : ./swarm-deploy.sh
# Retrait : docker stack rm cloud
#
# 1. Swarm doit être actif : un nœud unique suffit (docker swarm init).
# 2. Les images sont construites par docker compose : Swarm ignore "build" et utilise des images existantes.
# 3. Le .env est chargé dans l'environnement : docker stack deploy ne le lit pas lui-même.

# Arrêt à la première erreur : ne pas déployer avec des images qui n'ont pas pu être construites
set -e
cd "$(dirname "$0")"

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
  echo "Swarm n'est pas actif. Activez-le une fois avec : docker swarm init"
  echo "(réversible avec : docker swarm leave --force)"
  exit 1
fi

docker compose build

# set -a : chaque variable lue dans le .env est exportée, donc visible par docker stack deploy
set -a
. ./.env
set +a

docker stack deploy -c docker-stack.yml cloud
docker stack services cloud
