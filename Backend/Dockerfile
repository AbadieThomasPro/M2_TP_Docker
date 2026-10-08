# Version d'Alpine en ARG pour la changer sur les 3 images depuis .env, sans toucher au Dockerfile
ARG ALPINE_VERSION=3.20

# Alpine plutôt que l'image node : ~8 Mo, moins de surface d'attaque, et aucune image toute faite du Hub
FROM alpine:${ALPINE_VERSION}

# nodejs sans npm : l'API n'utilise que des modules natifs (pas d'Express)
# tini : Node en PID 1 ignore SIGTERM, tini le relaie (sinon SIGKILL après 10 s)
# tzdata : logs à l'heure de Paris plutôt qu'en UTC
# --no-cache : l'index apk ne sert plus après l'install, inutile de l'embarquer
RUN apk add --no-cache nodejs tini tzdata

# Utilisateur dédié, distinct du front : en cas de faille, l'attaquant n'est pas root
RUN adduser -D -H back

# Port en ARG : une seule valeur pour EXPOSE et ENV PORT, qui restent donc cohérents
ARG PORT=3000

# Valeurs par défaut en ENV : l'image démarre seule, le compose les surcharge sans rebuild
# (PHRASE en ENV : changer la réponse de l'API ne demande pas de rebuild)
ENV TZ=Europe/Paris \
    PORT=${PORT} \
    NODE_MAX_MEMORY=128 \
    PHRASE="Hello World depuis le back !"

# Indique à l'utilisateur de l'image le port de l'API
EXPOSE ${PORT}

# Chemin fixe pour que les COPY et la CMD ne dépendent pas du répertoire courant
WORKDIR /app

# Code copié en dernier : il change souvent, les couches au-dessus restent en cache
# Fichiers laissés à root : "back" peut les lire mais pas les modifier
COPY src/ ./src/

# Bascule après les COPY : l'installation a besoin de root, l'exécution non
USER back

# Route /health dédiée : vérifie que l'API répond sans dépendre de la logique métier
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/health || exit 1

# tini en PID 1 pour relayer les signaux et nettoyer les processus zombies
ENTRYPOINT ["/sbin/tini", "--"]

# sh -c pour lire NODE_MAX_MEMORY ; exec pour que Node remplace le shell et reçoive SIGTERM
CMD ["sh", "-c", "exec node --max-old-space-size=${NODE_MAX_MEMORY} src/server.js"]
