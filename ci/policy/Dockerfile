# Étape « policy » de la CI : vérifie les images CONSTRUITES (pas seulement leurs Dockerfile)
ARG ALPINE_VERSION=3.22

FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-cloud-ci-policy" \
      org.opencontainers.image.description="Étape policy de la CI : utilisateur non-root, healthcheck, pas de npm dans les images livrées" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# Le client Docker suffit pour inspecter les images du moteur de l'hôte (par le socket)
RUN apk add --no-cache docker-cli

# Même principe que l'autoscaler : utilisateur non-root, membre du groupe propriétaire du socket
# (0 sur Docker Desktop, groupe « docker » ailleurs), groupe créé s'il n'existe pas dans l'image
ARG DOCKER_GID=0
RUN adduser -D -H -u 2001 ci \
 && grp=$(awk -F: -v g="${DOCKER_GID}" '$3 == g { print $1 }' /etc/group) \
 && if [ -z "$grp" ]; then addgroup -g "${DOCKER_GID}" docker && grp=docker; fi \
 && addgroup ci "$grp" \
 && mkdir -m 1777 /reports

# Le client Docker veut écrire sa configuration ; le reste du système de fichiers est en lecture seule
ENV DOCKER_CONFIG=/tmp/.docker

COPY --chmod=755 policy.sh /usr/local/bin/policy.sh

USER ci

ENTRYPOINT ["/usr/local/bin/policy.sh"]
