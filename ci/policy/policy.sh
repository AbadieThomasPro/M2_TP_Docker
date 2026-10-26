#!/bin/sh
# Étape policy de la CI : chaque image livrée doit respecter les règles du projet, vérifiées sur
# l'image construite elle-même (un Dockerfile conforme peut produire une image qui ne l'est pas,
# par exemple si une couche de base change). IMAGE_TAG : version produite par l'étape build.

set -u
TAG=${IMAGE_TAG:-latest}
REPORT=/reports/policy.txt
rc=0
: > "$REPORT"

say() { echo "$*" | tee -a "$REPORT"; }

say "== Politique des images docker-cloud/*:$TAG =="
for s in front gateway back cleaner autoscaler; do
  img="docker-cloud/$s:$TAG"
  if ! docker image inspect "$img" > /dev/null 2>&1; then
    say "ERREUR  $img : image absente (l'étape build a-t-elle tourné ?)"; rc=1; continue
  fi
  user=$(docker image inspect -f '{{.Config.User}}' "$img")
  hc=$(docker image inspect -f '{{if .Config.Healthcheck}}{{len .Config.Healthcheck.Test}}{{else}}0{{end}}' "$img")
  size=$(docker image inspect -f '{{.Size}}' "$img")
  errs=""
  # Non-root : en cas de faille, l'attaquant n'a pas les droits root dans le conteneur
  case "$user" in ""|root|0|0:*) errs="$errs utilisateur root ;" ;; esac
  # Healthcheck : sans lui, depends_on (compose) et la mise à jour progressive (Swarm) ne savent pas
  # quand le service est prêt
  [ "$hc" -gt 0 ] || errs="$errs pas de HEALTHCHECK ;"
  # Images Node : npm sert au build, pas à l'exécution (multi-stage) ; sa présence trahirait un stage oublié.
  # Conteneur sans réseau, supprimé aussitôt : on ne fait qu'y chercher la commande
  case "$s" in
    front|back)
      if docker run --rm --network none --entrypoint sh "$img" -c 'command -v npm' > /dev/null 2>&1; then
        errs="$errs npm présent dans l'image livrée ;"
      fi ;;
  esac
  mb=$((size / 1000000))
  if [ -z "$errs" ]; then say "OK      $img (utilisateur $user, $mb Mo)"; else say "ERREUR  $img :$errs"; rc=1; fi
done

if [ "$rc" -eq 0 ]; then say "Policy : toutes les images sont conformes"; else say "Policy : ÉCHEC"; fi
exit "$rc"
