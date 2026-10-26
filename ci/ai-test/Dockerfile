# Étape « ai-test » de la CI (optionnelle) : un agent Claude écrit des tests de l'API à partir de la
# spécification, puis notre script les relance lui-même pour décider du résultat
ARG ALPINE_VERSION=3.22

# Alpine comme toutes nos images (l'exemple du cours part de python:3.12-slim, une image du Hub)
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-cloud-ci-ai-test" \
      org.opencontainers.image.description="Étape ai-test de la CI : tests de l'API écrits par un agent Claude, relancés et jugés par node --test" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# nodejs : le SDK de l'agent, les tests écrits (node:test) et le serveur testé tournent sur Node.
# npm : installation des dépendances ci-dessous seulement (outil de CI, pas une image livrée).
# bash : l'outil Bash de Claude Code exige un vrai shell (« No suitable shell found » avec le seul
# sh de BusyBox, constaté) ; l'agent ne peut de toute façon lancer que node --test
RUN apk add --no-cache nodejs npm bash

# SDK de l'agent, version figée par le package-lock : il embarque le binaire natif de Claude Code.
# npm ci installe les variantes glibc ET musl (278 + 272 Mo, mesuré) : seule la musl sert sur Alpine,
# l'autre est supprimée dans la même couche (méthode indiquée par la doc du SDK). ~560 Mo au final,
# acceptable pour un outil de CI jamais déployé
WORKDIR /agent
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund \
 && find node_modules/@anthropic-ai -maxdepth 1 -name 'claude-agent-sdk-linux-*' ! -name '*-musl' -exec rm -rf {} + \
 && rm -rf /root/.npm

# Dépendances du back (express, multer) dans /deps, comme l'image « test » : les tests écrits par
# l'agent lancent le vrai serveur, dont le code reste monté en lecture seule
WORKDIR /deps
COPY --from=back package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && rm -rf /root/.npm
ENV NODE_PATH=/deps/node_modules

# Non-root : Claude Code refuse d'ailleurs de tourner sans surveillance en root.
# /reports et /tests en 1777 : les volumes neufs reprennent ces droits (voir ci/lint)
RUN adduser -D -H -u 2001 ci && mkdir -m 1777 /reports /tests

# HOME dans /tmp (tmpfs) : Claude Code y écrit sa configuration, le reste est en lecture seule.
# Pas de mise à jour automatique ni de trafic non essentiel : la version testée doit rester celle de l'image
ENV HOME=/tmp/home \
    SHELL=/bin/bash \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    CI_IA_MODEL=claude-opus-5-5 \
    CI_IA_MAX_TURNS=40 \
    CI_IA_BUDGET_USD=3

COPY ai-test.mjs /agent/ai-test.mjs

USER ci
WORKDIR /workspace

# Pas de HEALTHCHECK : étape ponctuelle, le code de sortie est le contrat (0 vert, 1 tests rouges,
# 2 agent en échec ou jeton absent)
CMD ["node", "/agent/ai-test.mjs"]
