# Étape « lint » de la CI : une image = une étape = ses outils, et rien d'autre
ARG ALPINE_VERSION=3.22

# Alpine comme toutes nos images (pas d'image d'outil toute faite du Hub) ; la version fixée
# fige aussi celles de shellcheck et de Node : même résultat sur toutes les machines
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-cloud-ci-lint" \
      org.opencontainers.image.description="Étape lint de la CI : scripts shell, JavaScript et règles des Dockerfile" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# shellcheck : erreurs courantes des scripts shell (variables non protégées, syntaxe propre à bash...)
# nodejs : node --check vérifie la syntaxe du JavaScript sans l'exécuter
# Pas de hadolint : absent des paquets Alpine ; les règles des Dockerfile sont vérifiées par lint.sh
RUN apk add --no-cache shellcheck nodejs

# Rapports partagés entre étapes par un volume : un volume neuf reprend les droits de ce dossier,
# 1777 (comme /tmp) pour que chaque étape, avec son propre utilisateur, puisse y écrire
RUN adduser -D -H -u 2001 ci && mkdir -m 1777 /reports

COPY --chmod=755 lint.sh /usr/local/bin/lint.sh

USER ci

# Pas de HEALTHCHECK : ce n'est pas un service, le conteneur s'arrête dès la fin de la vérification.
# Le code de sortie est le contrat : 0 = étape verte, sinon le pipeline s'arrête
ENTRYPOINT ["/usr/local/bin/lint.sh"]
