# Version d'Alpine en ARG pour la changer sur les 3 images depuis .env, sans toucher au Dockerfile
ARG ALPINE_VERSION=3.20

# Alpine plutôt que l'image nginx : ~8 Mo, moins de surface d'attaque, et aucune image toute faite du Hub
FROM alpine:${ALPINE_VERSION}

# nginx : référence légère pour un reverse proxy, et une autre techno que les images Node
# gettext-envsubst : seul sous-paquet utile de gettext, pour générer la config au run sans tout installer
# tzdata : logs à l'heure de Paris plutôt qu'en UTC
# --no-cache : l'index apk ne sert plus après l'install, inutile de l'embarquer
RUN apk add --no-cache nginx gettext-envsubst tzdata

# Port en ARG : une seule valeur pour EXPOSE et ENV PORT, qui restent donc cohérents
ARG PORT=80

# Valeurs par défaut en ENV : l'image démarre seule, le compose les surcharge sans rebuild
ENV TZ=Europe/Paris \
    PORT=${PORT} \
    WORKER_PROCESSES=1 \
    WORKER_CONNECTIONS=512 \
    BACK_HOST=back \
    BACK_PORT=3000

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

# Script de démarrage : la config dépend des variables du run, elle ne peut pas être figée au build
ENTRYPOINT ["/entrypoint.sh"]
