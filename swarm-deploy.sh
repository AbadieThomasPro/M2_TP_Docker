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

# Le .env n'est pas versionné : sans lui, chaque valeur serait vide et les services recevraient des réglages faux
[ -f .env ] || { echo ".env absent : le créer avec  cp .env.example .env"; exit 1; }

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
  echo "Swarm n'est pas actif. Activez-le une fois avec : docker swarm init"
  echo "(réversible avec : docker swarm leave --force)"
  exit 1
fi

# set -a : chaque variable lue dans le .env est exportée, donc visible par docker stack deploy.
# Chargé avant les builds : l'image de l'autoscaler en a besoin pour ses arguments.
# Fins de ligne Windows retirées : un .env en CRLF donnerait des valeurs terminées par \r (services cassés)
set -a
eval "$(tr -d '\r' < .env)"
set +a

docker compose build

# L'autoscaler n'existe qu'en Swarm (le compose n'a pas d'instances à piloter) : docker compose build
# ne le connaît pas, on le construit à part, avec les mêmes valeurs du .env
docker build -t docker-cloud/autoscaler --build-arg ALPINE_VERSION="$ALPINE_VERSION" --build-arg DOCKER_GID="$DOCKER_GID" ./Autoscaler

docker stack deploy -c docker-stack.yml cloud
docker stack services cloud
