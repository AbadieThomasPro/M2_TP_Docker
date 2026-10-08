# Version d'Alpine en ARG, comme les autres images : une seule valeur à changer dans .env
ARG ALPINE_VERSION=3.22

# Alpine : son BusyBox fournit déjà sh, date, find, rm et stat, tout ce dont le script a besoin
FROM alpine:${ALPINE_VERSION}

# Métadonnées au format standard OCI : l'image se décrit elle-même dans docker inspect
LABEL org.opencontainers.image.title="docker-cloud-cleaner" \
      org.opencontainers.image.description="Worker qui supprime les fichiers expirés et les envois abandonnés" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# Aucun apk add : pas de runtime (Node, Python) pour une boucle de quelques lignes,
# donc image minimale et rien à mettre à jour en dehors d'Alpine

# Même GID que le groupe du back (fourni par .env) : c'est ce numéro qui donne le droit d'écrire
# dans le dossier de stockage, donc d'y supprimer des fichiers
ARG STORAGE_GID=1500

# Utilisateur dédié, membre du groupe partagé "stockage" : il supprime sans être root ni être "back".
# UID 1002, distinct de back (1001) : avec le même UID, le noyau le prendrait pour le propriétaire
# des fichiers, et le groupe partagé ne servirait plus à rien (seuls les numéros comptent, pas les noms)
RUN addgroup -g ${STORAGE_GID} stockage && adduser -D -H -u 1002 -G stockage cleaner

# Valeurs par défaut en ENV : l'image démarre seule, le compose les surcharge sans rebuild
# CLEANUP_INTERVAL_S : délai entre deux passes ; INCOMING_MAX_AGE_MIN : âge d'un envoi considéré abandonné
ENV STORAGE_DIR=/data/files \
    CLEANUP_INTERVAL_S=60 \
    INCOMING_MAX_AGE_MIN=60 \
    HEARTBEAT_FILE=/tmp/heartbeat

# Pas de VOLUME /data : lancé seul, le worker n'a rien à nettoyer ; c'est le compose qui lui
# partage le volume du back (un VOLUME créerait ici un volume anonyme vide et trompeur)

# Script copié en dernier (ce qui change le plus) ; --chmod évite un RUN chmod, donc une couche
COPY --chmod=755 cleanup.sh /usr/local/bin/cleanup.sh

USER cleaner

# Pas de réseau (network_mode: none dans le compose) : le healthcheck vérifie la date de la dernière passe
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=2 \
  CMD ["/usr/local/bin/cleanup.sh", "--healthcheck"]

# Le script est conçu pour être PID 1 : il gère lui-même SIGTERM (trap) et n'a pas d'enfant durable,
# donc pas besoin de tini. Forme exec : le shell du script reçoit directement le signal
ENTRYPOINT ["/usr/local/bin/cleanup.sh"]
