# ARG avant FROM : version d'Alpine choisie au build (seul ARG utilisable dans FROM)
ARG ALPINE_VERSION=3.20

# OS de base minimal, Node est installé nous-mêmes
FROM alpine:${ALPINE_VERSION}

# nodejs : exécute l'API / tini : init PID 1, relaie SIGTERM / tzdata : fuseaux horaires
RUN apk add --no-cache nodejs tini tzdata

# Utilisateur sans droits root pour faire tourner l'API
RUN adduser -D -H back

# ARG (build) : port d'écoute, sert à EXPOSE et de valeur par défaut à ENV PORT
ARG PORT=3000

# ENV (run) : valeurs par défaut, surchargées par environment: du compose
ENV TZ=Europe/Paris \
    PORT=${PORT} \
    NODE_MAX_MEMORY=128 \
    PHRASE="Hello World depuis le back !"

# Port documenté du conteneur
EXPOSE ${PORT}

# Dossier de l'application
WORKDIR /app

# Code copié en dernier : il change souvent, les couches au-dessus restent en cache
# (appartient à root, lecture seule pour "back")
COPY src/ ./src/

# Bascule sur l'utilisateur non-root
USER back

# Vérifie que l'API répond (utilisé par depends_on dans le compose)
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/health || exit 1

# tini en PID 1 pour transmettre les signaux à Node
ENTRYPOINT ["/sbin/tini", "--"]

# exec remplace le shell par Node pour qu'il reçoive bien SIGTERM
CMD ["sh", "-c", "exec node --max-old-space-size=${NODE_MAX_MEMORY} src/server.js"]
