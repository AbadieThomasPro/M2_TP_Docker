# Étape « security » de la CI : failles connues des dépendances npm livrées (back et front)
ARG ALPINE_VERSION=3.22

FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-cloud-ci-security" \
      org.opencontainers.image.description="Étape security de la CI : npm audit des dépendances du back et du front" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# npm audit ne lit que package.json et package-lock.json, puis interroge la base de failles du registre npm
RUN apk add --no-cache nodejs npm

# Cache npm dans /tmp (le reste est en lecture seule) ; pas de message de mise à jour ni d'appel aux dons
# dans le rapport. AUDIT_LEVEL : gravité à partir de laquelle l'étape échoue (high par défaut, voir .env)
ENV npm_config_cache=/tmp/npm-cache \
    npm_config_update_notifier=false \
    npm_config_fund=false \
    AUDIT_LEVEL=high

RUN adduser -D -H -u 2001 ci && mkdir -m 1777 /reports

COPY --chmod=755 audit.sh /usr/local/bin/audit.sh

USER ci

ENTRYPOINT ["/usr/local/bin/audit.sh"]
