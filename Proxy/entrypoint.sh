#!/bin/sh
set -e

# Génère la config nginx à partir des variables d'environnement du run.
# La liste limite envsubst à nos variables, pour ne pas toucher aux $host, $remote_addr... de nginx.
envsubst '${PORT} ${WORKER_PROCESSES} ${WORKER_CONNECTIONS} ${BACK_HOST} ${BACK_PORT}' \
  < /etc/nginx/nginx.conf.template > /tmp/nginx.conf

# exec : nginx remplace le shell et devient PID 1, il reçoit donc directement les signaux
exec nginx -e /dev/stderr -c /tmp/nginx.conf -g 'daemon off;'
