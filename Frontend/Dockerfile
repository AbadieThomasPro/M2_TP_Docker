# Version d'Alpine en ARG pour la changer sur toutes les images depuis .env, sans toucher au Dockerfile
# (déclarée avant le premier FROM : utilisable par les deux stages)
ARG ALPINE_VERSION=3.22

# ---------------------------------------------------------------------------
# Stage 1 "build" : compile l'application Angular. Jeté à la fin : npm, la CLI Angular,
# TypeScript et les ~300 Mo de node_modules ne se retrouvent pas dans l'image finale
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS build

# npm pour installer les outils de build ; nodejs 22 (Alpine 3.22) : Angular 22 exige Node >= 22.22
RUN apk add --no-cache nodejs npm

# Pas de question interactive sur la télémétrie de la CLI Angular pendant un build automatique
ENV NG_CLI_ANALYTICS=false

WORKDIR /build

# Fichiers de dépendances copiés seuls, avant les sources : tant qu'ils ne changent pas,
# la couche npm ci (la plus longue) reste en cache quand on modifie le code
COPY app/package.json app/package-lock.json ./

# npm ci : versions exactes du package-lock (build reproductible). Les dépendances de dev
# sont nécessaires ici (CLI, compilateur) : c'est le stage jetable qui les porte, pas l'image finale
RUN npm ci --no-audit --no-fund

COPY app/ ./

# Build de production : fichiers minifiés, noms avec empreinte (main-XXXX.js), sortie dans dist/
RUN npx ng build

# ---------------------------------------------------------------------------
# Stage 2 : image finale, uniquement le serveur et les fichiers compilés
# ---------------------------------------------------------------------------
# Alpine plutôt que l'image node : ~8 Mo, moins de surface d'attaque, et aucune image toute faite du Hub
FROM alpine:${ALPINE_VERSION}

# Métadonnées au format standard OCI : l'image se décrit elle-même dans docker inspect
LABEL org.opencontainers.image.title="docker-cloud-front" \
      org.opencontainers.image.description="Front du cloud de fichiers éphémères : sert l'application Angular et relaie /api vers la gateway" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# nodejs sans npm : le serveur n'utilise que des modules natifs, et l'application est déjà compilée
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

# Fichiers laissés à root : "front" peut les lire mais pas les modifier
COPY server.js ./

# Résultat du build seulement (HTML, JS, CSS compilés) : ni sources TypeScript, ni node_modules, ni npm.
# Copié en dernier : c'est ce qui change le plus souvent
COPY --from=build /build/dist/cloud-front/browser ./public/

# Bascule après les COPY : l'installation a besoin de root, l'exécution non
USER front

# Permet au compose de n'ouvrir l'accès qu'une fois le serveur réellement prêt
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/ || exit 1

# tini en PID 1 pour relayer les signaux et nettoyer les processus zombies
ENTRYPOINT ["/sbin/tini", "--"]

# Forme exec sans shell : Node est lancé directement par tini et reçoit SIGTERM
CMD ["node", "server.js"]
