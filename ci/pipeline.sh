#!/bin/sh
# Pipeline CI/CD complet : joue le rôle d'un serveur de CI (Jenkins, GitLab Runner...), chaque étape
# étant un conteneur. Équivalent Windows : ci/pipeline.ps1
#
#   0. build        images de l'application + images des étapes de CI
#   1. lint ∥ test  (en parallèle)               ┐ ci/compose.yml : une étape ne démarre que si
#   2. security ∥ policy (après lint ET test)    ┘ les précédentes sont sorties avec le code 0
#   3. intégration  vraie stack isolée (projet docker-cloud-it), tests de bout en bout, arrêt en code 0
#   4. déploiement  ci/deploy.sh : mise à jour progressive sur Swarm (si Swarm est actif)
#
# Usage : ./ci/pipeline.sh [--sans-deploiement] [--ia]
#   --ia : ajoute l'étape ai-test (tests écrits par un agent Claude, jeton dans ci/ia.env)
# Code de sortie : 0 si tout est vert. Au premier échec, le pipeline s'arrête : rien n'est déployé,
# la version en service reste en place. Rapports : ci/reports/

set -u
cd "$(dirname "$0")/.." || exit 1

DEPLOY=1
IA=0
for arg in "$@"; do
  case "$arg" in
    --sans-deploiement) DEPLOY=0 ;;
    # Étape IA sur demande seulement : elle consomme la limite de l'abonnement Claude de l'utilisateur
    --ia) IA=1 ;;
    *) echo "Option inconnue : $arg (options : --sans-deploiement, --ia)"; exit 2 ;;
  esac
done

CI="docker compose -f ci/compose.yml --env-file .env"
if [ "$IA" -eq 1 ]; then
  # Échec franc et immédiat sans jeton : demander l'IA et ne pas l'avoir n'est jamais un succès
  if ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=.*sk-ant-' ci/ia.env 2> /dev/null || grep -q 'FAUX-JETON' ci/ia.env; then
    echo "❌ --ia demandé sans jeton : copier ci/ia.env.example en ci/ia.env et y mettre le sien (claude setup-token)"
    exit 2
  fi
  CI="$CI --profile ia"
fi
IT="docker compose -p docker-cloud-it -f docker-compose.yml -f ci/compose.integration.yml --env-file .env"
SUMMARY=""
T0=$(date +%s)

# Fins de ligne Windows retirées (.env extrait en CRLF sous Windows), comme swarm-deploy.sh
set -a
eval "$(tr -d '\r' < .env)"
set +a

# Toujours exécuté, même après un échec ou un Ctrl+C : aucune stack de test ni conteneur d'étape ne
# doit rester derrière le pipeline (ressources, port, volume)
cleanup() {
  $IT --profile integration down -v --remove-orphans > /dev/null 2>&1
  $CI down -v > /dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM

step_start() { STEP=$1; STEP_T=$(date +%s); echo; echo "▶ $STEP"; }
step_ok() { d=$(( $(date +%s) - STEP_T )); SUMMARY="$SUMMARY
  ✅ $STEP (${d} s)"; }
# Échec : résumé, puis arrêt immédiat avec le code de l'étape
step_fail() {
  d=$(( $(date +%s) - STEP_T ))
  SUMMARY="$SUMMARY
  ❌ $STEP (${d} s)"
  echo "$SUMMARY"
  echo
  echo "❌ Pipeline en ÉCHEC à l'étape « $STEP » : rien n'est déployé, la version en service ne change pas."
  echo "   Rapports : ci/reports/"
  exit "${1:-1}"
}

# Rapports de l'exécution précédente effacés : un vieux rapport ne doit pas passer pour le nouveau
rm -rf ci/reports && mkdir -p ci/reports

step_start "build : images de l'application et de la CI"
docker compose config --quiet && $CI config --quiet || step_fail 1
docker compose build --quiet || step_fail 1
docker build --quiet -t docker-cloud/autoscaler --build-arg ALPINE_VERSION="$ALPINE_VERSION" --build-arg DOCKER_GID="$DOCKER_GID" ./Autoscaler > /dev/null || step_fail 1
$CI build --quiet || step_fail 1
step_ok

step_start "lint ∥ test, puis security ∥ policy"
# Conteneurs neufs à chaque exécution : un conteneur d'étape d'une exécution passée ne doit pas être
# pris pour un succès
$CI down -v > /dev/null 2>&1
$CI up --abort-on-container-failure
rc=$?
$CI cp lint:/reports/. ci/reports/ > /dev/null 2>&1
# Tests écrits par l'agent copiés pour relecture humaine, même (surtout) si l'étape a échoué
[ "$IA" -eq 1 ] && mkdir -p ci/reports/ai-tests && $CI cp ai-test:/tests/. ci/reports/ai-tests/ > /dev/null 2>&1
[ "$rc" -eq 0 ] || step_fail "$rc"
step_ok

step_start "intégration : stack isolée, tests de bout en bout"
$IT up -d --wait || step_fail 1
$IT run --name docker-cloud-it-tests integration
rc=$?
docker cp docker-cloud-it-tests:/reports/junit-integration.xml ci/reports/ > /dev/null 2>&1
docker rm docker-cloud-it-tests > /dev/null 2>&1
[ "$rc" -eq 0 ] || step_fail "$rc"
# Arrêt propre vérifié : chaque service de la stack doit sortir avec le code 0 (SIGTERM traité)
ids=$($IT ps -q)
$IT stop > /dev/null 2>&1
bad=""
for id in $ids; do
  code=$(docker inspect -f '{{.State.ExitCode}}' "$id")
  [ "$code" = "0" ] || bad="$bad $(docker inspect -f '{{.Name}}' "$id")=$code"
done
if [ -n "$bad" ]; then echo "Arrêt non propre :$bad"; step_fail 1; fi
echo "Arrêt de la stack de test : code 0 pour chaque service"
step_ok

if [ "$DEPLOY" -eq 1 ] && [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "active" ]; then
  step_start "déploiement : mise à jour progressive sur Swarm"
  sh ci/deploy.sh || step_fail 1
  step_ok
else
  SUMMARY="$SUMMARY
  ⏭  déploiement ignoré (option --sans-deploiement, ou Swarm inactif)"
fi

echo "$SUMMARY"
echo
echo "✅ Pipeline vert en $(( $(date +%s) - T0 )) s. Rapports : ci/reports/"
