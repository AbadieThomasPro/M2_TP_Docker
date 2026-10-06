# OS de base minimal, Node est installé nous-mêmes
FROM alpine:3.20

# nodejs : exécute l'API / tini : init PID 1, relaie SIGTERM / tzdata : fuseaux horaires
RUN apk add --no-cache nodejs tini tzdata

# Fuseau horaire des logs
ENV TZ=Europe/Paris

# Utilisateur sans droits root pour faire tourner l'API
RUN adduser -D -H back

# Dossier de l'application
WORKDIR /app

# Copie du code (appartient à root, lecture seule pour "back")
COPY src/ ./src/

# Arguments modifiables au run : port, mémoire max de Node (Mo) et phrase renvoyée
ENV PORT=3000 \
    NODE_MAX_MEMORY=128 \
    PHRASE="Hello World depuis le back !"

# Port documenté du conteneur
EXPOSE 3000

# Bascule sur l'utilisateur non-root
USER back

# Vérifie que l'API répond (utilisé par depends_on dans le compose)
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/health || exit 1

# tini en PID 1 pour transmettre les signaux à Node
ENTRYPOINT ["/sbin/tini", "--"]

# exec remplace le shell par Node pour qu'il reçoive bien SIGTERM
CMD ["sh", "-c", "exec node --max-old-space-size=${NODE_MAX_MEMORY} src/server.js"]
