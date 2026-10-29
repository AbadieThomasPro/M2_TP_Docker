#!/bin/sh
# Déploiement continu (CD) : publie sur la stack Swarm les images que la CI vient de valider, puis
# attend que Swarm ait fini la mise à jour progressive. Équivalent Windows : ci/deploy.ps1
#
# Usage : ./ci/deploy.sh [tag]
#   tag : version à déployer ; par défaut le hash git court du commit testé (suffixé "-modifie" si le
#         dossier contient des changements non commités : l'image ne correspond alors à aucun commit)
# Code de sortie : 0 si toutes les instances tournent la nouvelle version, 1 sinon (retour arrière
# de Swarm, délai dépassé) : l'ancienne version reste alors en service.

set -u
cd "$(dirname "$0")/.." || exit 1

STACK=cloud
SERVICES="back gateway front cleaner autoscaler"
# 5 min : une mise à jour complète (5 services, monitor de 30 s chacun, une instance à la fois) en
# prend 2 à 3 ; au-delà, quelque chose est bloqué et le pipeline doit échouer plutôt qu'attendre
TIMEOUT_S=${DEPLOY_TIMEOUT_S:-300}

# Le .env n'est pas versionné : sans lui, la stack serait déployée avec des réglages vides
[ -f .env ] || { echo ".env absent : le créer avec  cp .env.example .env"; exit 1; }

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
  echo "Swarm inactif : déploiement impossible (l'activer une fois avec docker swarm init)"
  exit 1
fi

tag=${1:-}
if [ -z "$tag" ]; then
  tag=$(git rev-parse --short HEAD) || exit 1
  [ -n "$(git status --porcelain)" ] && tag="$tag-modifie"
fi

# Les images validées par la CI portent le tag "latest" (build du pipeline) : on leur donne le tag de
# version, sans les reconstruire, pour déployer exactement ce qui a été testé
for s in $SERVICES; do
  if ! docker image inspect "docker-cloud/$s:$tag" > /dev/null 2>&1; then
    docker tag "docker-cloud/$s:latest" "docker-cloud/$s:$tag" || { echo "Image docker-cloud/$s introuvable : lancer d'abord le build"; exit 1; }
  fi
done

# docker stack deploy ne lit pas le .env : on l'exporte, comme swarm-deploy.sh. Fins de ligne Windows
# retirées (.env extrait en CRLF sous Windows) : sinon chaque valeur finit par \r, les services
# reçoivent des réglages faux (constaté : le back ne démarrait plus, et Swarm revenait en arrière)
set -a
eval "$(tr -d '\r' < .env)"
set +a
export IMAGE_TAG="$tag"

start=$(date +%s)
echo "Déploiement de la version $tag sur la stack $STACK"
docker stack deploy -c docker-stack.yml "$STACK" > /dev/null || exit 1

# Attente bornée de la convergence : chaque service doit tourner la nouvelle image, avec toutes ses
# instances, et sans mise à jour en cours. Un retour arrière de Swarm est un échec du déploiement
while :; do
  pending=""
  failed=""
  for s in $SERVICES; do
    svc="${STACK}_$s"
    img=$(docker service inspect -f '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$svc")
    # Statut ignoré s'il date d'un déploiement précédent (avant celui-ci)
    state=$(docker service inspect -f '{{if .UpdateStatus}}{{if .UpdateStatus.StartedAt}}{{.UpdateStatus.StartedAt.Unix}} {{.UpdateStatus.State}}{{end}}{{end}}' "$svc")
    since=${state%% *}
    [ -n "$state" ] && [ "$since" -lt $((start - 2)) ] && state=""
    state=${state#* }
    reps=$(docker service ls --filter "name=$svc" --format '{{.Replicas}}' | head -n 1)
    running=${reps%%/*}
    wanted=${reps#*/}
    wanted=${wanted%% *}
    case "$state" in
      rollback_completed|paused) failed="$failed $s($state)" ;;
    esac
    case "$img" in
      *":$tag"|*":$tag@"*) ;;
      *) pending="$pending $s" ; continue ;;
    esac
    if [ "$state" = "updating" ] || [ "$state" = "rollback_started" ] || [ "$running" != "$wanted" ]; then
      pending="$pending $s"
    fi
  done
  elapsed=$(( $(date +%s) - start ))
  if [ -n "$failed" ]; then
    echo "ÉCHEC du déploiement après ${elapsed} s : retour arrière de Swarm pour$failed"
    echo "La version précédente est restée en service."
    exit 1
  fi
  if [ -z "$pending" ]; then
    echo "Version $tag en service sur les 5 services (${elapsed} s)"
    docker stack services "$STACK" --format '{{.Name}}  {{.Replicas}}  {{.Image}}'
    exit 0
  fi
  if [ "$elapsed" -ge "$TIMEOUT_S" ]; then
    echo "ÉCHEC : déploiement non terminé après ${TIMEOUT_S} s (en attente :$pending)"
    exit 1
  fi
  echo "  ${elapsed} s : mise à jour en cours pour$pending"
  sleep 5
done
