#!/bin/sh
# Arrêt immédiat si une commande échoue : mieux vaut un conteneur arrêté qu'un nginx avec une config cassée
set -e

# Config générée au démarrage pour que port, workers, taille d'upload et adresse du back se règlent au run.
# Liste de variables explicite : sans elle, envsubst effacerait aussi $host, $remote_addr... de nginx.
envsubst '${PORT} ${WORKER_PROCESSES} ${WORKER_CONNECTIONS} ${BACK_HOST} ${BACK_PORT} ${MAX_UPLOAD_MB}' \
  < /etc/nginx/nginx.conf.template > /tmp/nginx.conf

# exec "$@" : la CMD remplace le shell en PID 1 et reçoit donc directement les signaux.
# Lancer la CMD plutôt qu'un nginx écrit en dur permet de la remplacer au run (nginx -t, sh).
exec "$@"
