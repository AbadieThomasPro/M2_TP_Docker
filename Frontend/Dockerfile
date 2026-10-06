# OS de base minimal, Node est installé nous-mêmes
FROM alpine:3.20

# nodejs : exécute le serveur / tini : init PID 1, relaie SIGTERM / tzdata : fuseaux horaires
RUN apk add --no-cache nodejs tini tzdata

# Fuseau horaire des logs
ENV TZ=Europe/Paris

# Utilisateur sans droits root pour faire tourner le serveur
RUN adduser -D -H front

# Dossier de l'application
WORKDIR /app

# Copie du code (appartient à root, lecture seule pour "front")
COPY server.js ./
COPY src/ ./src/

# Arguments modifiables au run : port, mémoire max de Node (Mo) et adresse du proxy
ENV PORT=80 \
    NODE_MAX_MEMORY=128 \
    PROXY_HOST=proxy \
    PROXY_PORT=80

# Ports documentés du conteneur
EXPOSE 80

# Bascule sur l'utilisateur non-root
USER front

# Vérifie que le serveur répond (utilisé par depends_on dans le compose)
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/ || exit 1

# tini en PID 1 pour transmettre les signaux à Node
ENTRYPOINT ["/sbin/tini", "--"]

# exec remplace le shell par Node pour qu'il reçoive bien SIGTERM
CMD ["sh", "-c", "exec node --max-old-space-size=${NODE_MAX_MEMORY} server.js"]
