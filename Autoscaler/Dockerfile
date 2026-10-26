# Version d'Alpine en ARG, comme les autres images : une seule valeur à changer dans .env
ARG ALPINE_VERSION=3.22

FROM alpine:${ALPINE_VERSION}

# Métadonnées au format standard OCI : l'image se décrit elle-même dans docker inspect
LABEL org.opencontainers.image.title="docker-cloud-autoscaler" \
      org.opencontainers.image.description="Ajuste le nombre d'instances des services Swarm selon leur CPU et leur mémoire" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# docker-cli seul : le client suffit pour lire les mesures et changer le nombre d'instances, le moteur
# reste celui de l'hôte (via le socket). Ni bash ni curl, contrairement à l'exemple fourni : le shell
# BusyBox et awk d'Alpine font le calcul, comme pour le cleaner
RUN apk add --no-cache docker-cli

# GID du groupe propriétaire du socket Docker, fourni par .env : sur Docker Desktop c'est 0 (mesuré),
# ailleurs souvent le groupe "docker". Seul ce numéro donne le droit de parler au moteur
ARG DOCKER_GID=0

# Utilisateur dédié (UID 1003, distinct de back 1001 et cleaner 1002), avec son propre groupe principal,
# et membre en plus du groupe du socket : pas root, mais autorisé à piloter Docker. Si le GID n'existe
# pas encore dans l'image (cas d'un groupe "docker" de l'hôte), on le crée sous ce nom
RUN adduser -D -H -u 1003 autoscaler \
 && grp=$(awk -F: -v g="${DOCKER_GID}" '$3 == g { print $1 }' /etc/group) \
 && if [ -z "$grp" ]; then addgroup -g "${DOCKER_GID}" docker && grp=docker; fi \
 && addgroup autoscaler "$grp"

# Valeurs par défaut en ENV : l'image démarre seule, la stack les surcharge sans rebuild.
# Seuils et délais justifiés par le benchmark (voir .env et README) ; DOCKER_CONFIG dans /tmp :
# le client Docker veut y écrire, et le reste du système de fichiers est en lecture seule
ENV AUTOSCALE_INTERVAL_S=10 \
    AUTOSCALE_CPU_UP=70 \
    AUTOSCALE_CPU_DOWN=25 \
    AUTOSCALE_MEM_UP=80 \
    AUTOSCALE_MEM_DOWN=50 \
    AUTOSCALE_UP_SAMPLES=3 \
    AUTOSCALE_DOWN_SAMPLES=6 \
    AUTOSCALE_COOLDOWN_UP_S=30 \
    AUTOSCALE_COOLDOWN_DOWN_S=60 \
    AUTOSCALE_HOST_BUDGET_PCT=80 \
    HEARTBEAT_FILE=/tmp/heartbeat \
    DOCKER_CONFIG=/tmp/.docker

# Script copié en dernier (ce qui change le plus) ; --chmod évite un RUN chmod, donc une couche
COPY --chmod=755 autoscale.sh /usr/local/bin/autoscale.sh

USER autoscaler

# Pas de port à tester : sain si la dernière boucle date de moins de 3 intervalles
# (un relevé docker stats peut prendre quelques secondes)
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=2 \
  CMD ["/usr/local/bin/autoscale.sh", "--healthcheck"]

# Script conçu pour être PID 1 (trap SIGTERM, comme le cleaner) : pas besoin de tini.
# Forme exec : le shell du script reçoit directement le signal
ENTRYPOINT ["/usr/local/bin/autoscale.sh"]
