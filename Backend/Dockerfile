# Version d'Alpine en ARG pour la changer sur les 3 images depuis .env, sans toucher au Dockerfile
# (déclarée avant le premier FROM : utilisable par les deux stages)
ARG ALPINE_VERSION=3.20

# ---------------------------------------------------------------------------
# Stage 1 "deps" : installe les dépendances npm. Jeté à la fin : npm et son cache
# ne se retrouvent pas dans l'image finale (plus petite, moins d'outils pour un attaquant)
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS deps

# npm n'est utile qu'ici, pour installer express et multer
RUN apk add --no-cache nodejs npm

WORKDIR /app

# Fichiers de dépendances copiés seuls, avant le code : tant qu'ils ne changent pas,
# la couche npm ci reste en cache et un changement de code ne relance pas l'installation
COPY package.json package-lock.json ./

# npm ci plutôt que npm install : installe exactement les versions du package-lock (build reproductible)
# --omit=dev : aucune dépendance de développement en production
RUN npm ci --omit=dev --no-audit --no-fund

# ---------------------------------------------------------------------------
# Stage 2 : image finale, uniquement ce qu'il faut pour faire tourner l'API
# ---------------------------------------------------------------------------
# Alpine plutôt que l'image node : ~8 Mo, moins de surface d'attaque, et aucune image toute faite du Hub
FROM alpine:${ALPINE_VERSION}

# Métadonnées au format standard OCI : l'image se décrit elle-même dans docker inspect
LABEL org.opencontainers.image.title="docker-cloud-back" \
      org.opencontainers.image.description="API du mini cloud de stockage" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# nodejs sans npm : les dépendances arrivent déjà installées depuis le stage "deps"
# tini : Node en PID 1 ignore SIGTERM, tini le relaie (sinon SIGKILL après 10 s)
# tzdata : logs à l'heure de Paris plutôt qu'en UTC
# --no-cache : l'index apk ne sert plus après l'install, inutile de l'embarquer
RUN apk add --no-cache nodejs tini tzdata

# GID du groupe partagé en ARG, fourni par .env : le cleaner doit recevoir exactement la même valeur
# pour pouvoir supprimer les fichiers du back (un nom de groupe ne compte pas, seul le numéro compte)
ARG STORAGE_GID=1500

# Groupe "stockage" partagé avec le cleaner, et utilisateur dédié "back" dont c'est le groupe principal :
# les fichiers qu'il crée appartiennent au groupe. Non-root : en cas de faille, l'attaquant n'est pas root
RUN addgroup -g ${STORAGE_GID} stockage && adduser -D -H -G stockage back

# Dossier de stockage (et .incoming pour les envois en cours) créé AVANT le VOLUME : Docker recopie
# ces droits dans un volume neuf, sinon il appartiendrait à root et l'API (non-root) ne pourrait pas écrire.
# 2775 : groupe en écriture (le cleaner supprime = écrit dans le DOSSIER) et bit setgid (tout ce qui
# est créé dedans hérite du groupe stockage)
RUN mkdir -p /data/files/.incoming && chown -R back:stockage /data && chmod -R 2775 /data

# Données hors de la couche du conteneur : elles survivent à sa suppression et à un rebuild,
# même lancé sans compose (Docker crée alors un volume anonyme au lieu d'écrire dans le conteneur)
VOLUME /data

# Port en ARG : une seule valeur pour EXPOSE et ENV PORT, qui restent donc cohérents
ARG PORT=3000

# Valeurs par défaut en ENV : l'image démarre seule, le compose les surcharge sans rebuild
# NODE_OPTIONS : lu par Node lui-même, évite de passer par un shell dans la CMD pour fixer la mémoire
# PHRASE en ENV : changer la réponse de l'API ne demande pas de rebuild
# STORAGE_DIR en ENV : le code lit le chemin au lieu de l'écrire en dur (doit rester sous /data, le volume)
# MAX_UPLOAD_MB : même défaut que la gateway, le back refuse aussi les fichiers trop gros
# TTL_* : durée de vie des fichiers (heures) ; STORAGE_QUOTA_MB : 0 = pas de quota par défaut
ENV TZ=Europe/Paris \
    PORT=${PORT} \
    NODE_OPTIONS="--max-old-space-size=128" \
    PHRASE="Hello World depuis le back !" \
    STORAGE_DIR=/data/files \
    MAX_UPLOAD_MB=10 \
    TTL_DEFAULT_H=24 \
    TTL_MAX_H=168 \
    STORAGE_QUOTA_MB=0

# Indique à l'utilisateur de l'image le port de l'API
EXPOSE ${PORT}

# Chemin fixe pour que les COPY et la CMD ne dépendent pas du répertoire courant
WORKDIR /app

# Dépendances récupérées toutes faites du stage "deps" : seul le résultat est copié, pas npm
COPY --from=deps /app/node_modules ./node_modules

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

# Forme exec sans shell : Node est lancé directement par tini et reçoit SIGTERM
CMD ["node", "src/server.js"]
