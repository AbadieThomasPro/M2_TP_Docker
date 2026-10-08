# Version d'Alpine en ARG pour la changer sur les 3 images depuis .env, sans toucher au Dockerfile
ARG ALPINE_VERSION=3.20

# Alpine plutôt que l'image node : ~8 Mo, moins de surface d'attaque, et aucune image toute faite du Hub
FROM alpine:${ALPINE_VERSION}

# Métadonnées au format standard OCI : l'image se décrit elle-même dans docker inspect
LABEL org.opencontainers.image.title="docker-cloud-front" \
      org.opencontainers.image.description="Front du mini cloud de stockage : sert la page et relaie /api vers la gateway" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# nodejs sans npm : le serveur n'utilise que des modules natifs
# tini : Node en PID 1 ignore SIGTERM, tini le relaie (sinon SIGKILL après 10 s)
# tzdata : logs à l'heure de Paris plutôt qu'en UTC
# --no-cache : l'index apk ne sert plus après l'install, inutile de l'embarquer
RUN apk add --no-cache nodejs tini tzdata

# Utilisateur dédié : en cas de faille dans le serveur, l'attaquant n'est pas root
RUN adduser -D -H front

# Port en ARG : une seule valeur pour EXPOSE et ENV PORT, qui restent donc cohérents
ARG PORT=80

# Valeurs par défaut en ENV : l'image démarre seule, le compose les surcharge sans rebuild
# NODE_OPTIONS : lu par Node lui-même, évite de passer par un shell dans la CMD pour fixer la mémoire
ENV TZ=Europe/Paris \
    PORT=${PORT} \
    NODE_OPTIONS="--max-old-space-size=128" \
    GATEWAY_HOST=gateway \
    GATEWAY_PORT=80

# Indique à l'utilisateur de l'image quel port publier
EXPOSE ${PORT}

# Chemin fixe pour que les COPY et la CMD ne dépendent pas du répertoire courant
WORKDIR /app

# Code copié en dernier : il change souvent, les couches au-dessus restent en cache
# Fichiers laissés à root : "front" peut les lire mais pas les modifier
COPY server.js ./
COPY src/ ./src/

# Bascule après les COPY : l'installation a besoin de root, l'exécution non
USER front

# Permet au compose de n'ouvrir l'accès qu'une fois le serveur réellement prêt
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/ || exit 1

# tini en PID 1 pour relayer les signaux et nettoyer les processus zombies
ENTRYPOINT ["/sbin/tini", "--"]

# Forme exec sans shell : Node est lancé directement par tini et reçoit SIGTERM
CMD ["node", "server.js"]
