# Étape « test » de la CI : exécute les tests de l'API (node:test), isolée de l'outillage du lint
ARG ALPINE_VERSION=3.22

# Même base et même Node 22 que l'image du back : les tests tournent dans l'environnement livré
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="docker-cloud-ci-test" \
      org.opencontainers.image.description="Étape test de la CI : tests de l'API du back, rapport JUnit" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# npm sert ici à installer express et multer, dont dépend le serveur testé (outil de CI, pas image livrée)
RUN apk add --no-cache nodejs npm

# Dépendances du back installées DANS l'image, depuis son package-lock (contexte « back » fourni par le
# compose) : le code, monté en lecture seule, n'a pas de node_modules et ne doit pas en recevoir
WORKDIR /deps
COPY --from=back package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && rm -rf /root/.npm

# Node cherche les modules requis par le code testé dans ce dossier en plus de l'arborescence du code
ENV NODE_PATH=/deps/node_modules

# 1777 : le volume de rapports reprend ces droits, toutes les étapes peuvent y écrire (voir ci/lint)
RUN adduser -D -H -u 2001 ci && mkdir -m 1777 /reports

USER ci

# Deux rapports en une exécution : lisible dans le journal (spec), et JUnit, le format standard lu par
# les serveurs de CI (Jenkins, GitLab, GitHub). Tests trouvés par les motifs par défaut de Node
CMD ["node", "--test", "--test-reporter=spec", "--test-reporter-destination=stdout", "--test-reporter=junit", "--test-reporter-destination=/reports/junit-unit.xml"]
