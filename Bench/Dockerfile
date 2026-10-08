# Version d'Alpine en ARG, comme les autres images : une seule valeur à changer dans .env
ARG ALPINE_VERSION=3.20

# Alpine plutôt qu'une image de bench toute faite du Hub : contrainte du TP, et ~8 Mo
FROM alpine:${ALPINE_VERSION}

# Métadonnées au format standard OCI : l'image se décrit elle-même dans docker inspect
LABEL org.opencontainers.image.title="docker-cloud-bench" \
      org.opencontainers.image.description="Outil de charge (ab) pour mesurer les ressources des services" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# apache2-utils pour ab : outil de charge HTTP léger, disponible en paquet Alpine (wrk ou k6 seraient à compiler)
# --no-cache : l'index apk ne sert plus après l'install, inutile de l'embarquer
RUN apk add --no-cache apache2-utils

# Même un outil de test ne tourne pas en root : rien ne le justifie
RUN adduser -D -H bench
USER bench

# ab en ENTRYPOINT : le conteneur s'utilise comme une commande (modèle « outil CLI » du cours)
ENTRYPOINT ["ab"]

# Test par défaut remplaçable au run : 1000 requêtes, 10 en parallèle, sur le front comme un vrai client
CMD ["-n", "1000", "-c", "10", "http://front/api/phrase"]
