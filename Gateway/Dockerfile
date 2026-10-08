# Version d'Alpine en ARG pour la changer sur les 3 images depuis .env, sans toucher au Dockerfile
ARG ALPINE_VERSION=3.20

# Alpine plutôt que l'image nginx : ~8 Mo, moins de surface d'attaque, et aucune image toute faite du Hub
FROM alpine:${ALPINE_VERSION}

# Métadonnées au format standard OCI : l'image se décrit elle-même dans docker inspect
LABEL org.opencontainers.image.title="docker-cloud-gateway" \
      org.opencontainers.image.description="Passerelle d'API nginx : seul chemin du front vers le back" \
      org.opencontainers.image.authors="Thomas Abadie" \
      org.opencontainers.image.source="https://github.com/AbadieThomasPro/M2_TP_Docker"

# nginx : référence légère pour un reverse proxy, et une autre techno que les images Node
# gettext-envsubst : seul sous-paquet utile de gettext, pour générer la config au run sans tout installer
# tzdata : logs à l'heure de Paris plutôt qu'en UTC
# --no-cache : l'index apk ne sert plus après l'install, inutile de l'embarquer
RUN apk add --no-cache nginx gettext-envsubst tzdata

# Port en ARG : une seule valeur pour EXPOSE et ENV PORT, qui restent donc cohérents
ARG PORT=80

# Valeurs par défaut en ENV : l'image démarre seule, le compose les surcharge sans rebuild
# MAX_UPLOAD_MB : la gateway refuse les fichiers trop gros avant même qu'ils atteignent le back
ENV TZ=Europe/Paris \
    PORT=${PORT} \
    WORKER_PROCESSES=1 \
    WORKER_CONNECTIONS=512 \
    BACK_HOST=back \
    BACK_PORT=3000 \
    MAX_UPLOAD_MB=10

# Indique à l'utilisateur de l'image le port de la gateway
EXPOSE ${PORT}

# Copiés en dernier : ce sont eux qui changent le plus, les couches au-dessus restent en cache
# --chmod évite un RUN chmod, donc une couche de moins
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Utilisateur déjà créé par le paquet nginx : inutile d'en créer un pour ne pas tourner en root
USER nginx

# SIGQUIT plutôt que SIGTERM : nginx termine les requêtes en cours au lieu de les couper
STOPSIGNAL SIGQUIT

# 127.0.0.1 et non localhost : localhost se résout en IPv6 (::1) alors que nginx n'écoute qu'en IPv4
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1

# Script d'init : la config dépend des variables du run, elle ne peut pas être figée au build
ENTRYPOINT ["/entrypoint.sh"]

# Commande séparée de l'init : remplaçable au run (nginx -t, sh) tout en gardant la config générée
# daemon off : nginx doit rester au premier plan, sinon le conteneur s'arrête aussitôt
CMD ["nginx", "-e", "/dev/stderr", "-c", "/tmp/nginx.conf", "-g", "daemon off;"]
