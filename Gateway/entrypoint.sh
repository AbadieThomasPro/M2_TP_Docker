#!/bin/sh
# Arrêt immédiat si une commande échoue : mieux vaut un conteneur arrêté qu'un nginx avec une config cassée
set -e

# Config générée au démarrage pour que port, workers et adresse du back se règlent au run.
# Liste de variables explicite : sans elle, envsubst effacerait aussi $host, $remote_addr... de nginx.
envsubst '${PORT} ${WORKER_PROCESSES} ${WORKER_CONNECTIONS} ${BACK_HOST} ${BACK_PORT}' \
  < /etc/nginx/nginx.conf.template > /tmp/nginx.conf

# exec : nginx remplace le shell en PID 1, sinon le shell recevrait les signaux à sa place
# daemon off : nginx doit rester au premier plan, sinon le conteneur s'arrête aussitôt
exec nginx -e /dev/stderr -c /tmp/nginx.conf -g 'daemon off;'
