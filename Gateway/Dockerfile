# ARG avant FROM : version d'Alpine choisie au build (seul ARG utilisable dans FROM)
ARG ALPINE_VERSION=3.20

# OS de base minimal, nginx est installé nous-mêmes
FROM alpine:${ALPINE_VERSION}

# nginx : passerelle d'API (reverse proxy) / gettext-envsubst : génère la config depuis les variables / tzdata : fuseaux horaires
RUN apk add --no-cache nginx gettext-envsubst tzdata

# ARG (build) : port d'écoute, sert à EXPOSE et de valeur par défaut à ENV PORT
ARG PORT=80

# ENV (run) : valeurs par défaut, surchargées par environment: du compose
ENV TZ=Europe/Paris \
    PORT=${PORT} \
    WORKER_PROCESSES=1 \
    WORKER_CONNECTIONS=512 \
    BACK_HOST=back \
    BACK_PORT=3000

# Port documenté du conteneur
EXPOSE ${PORT}

# Modèle de config et script de démarrage (exécutable), copiés en dernier
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Utilisateur non-root "nginx", créé par le paquet nginx
USER nginx

# SIGQUIT = arrêt gracieux de nginx (termine les requêtes en cours)
STOPSIGNAL SIGQUIT

# Vérifie que la gateway répond (127.0.0.1 car nginx n'écoute qu'en IPv4)
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1

# Script qui génère la config puis lance nginx
ENTRYPOINT ["/entrypoint.sh"]
