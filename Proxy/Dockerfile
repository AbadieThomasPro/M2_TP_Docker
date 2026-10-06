# OS de base minimal, nginx est installé nous-mêmes
FROM alpine:3.20

# nginx : reverse proxy / gettext-envsubst : génère la config depuis les variables / tzdata : fuseaux horaires
RUN apk add --no-cache nginx gettext-envsubst tzdata

# Fuseau horaire des logs
ENV TZ=Europe/Paris

# Modèle de config et script de démarrage (exécutable)
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Arguments modifiables au run : port, ressources nginx et adresses du front et du back
ENV PORT=80 \
    WORKER_PROCESSES=1 \
    WORKER_CONNECTIONS=512 \
    FRONT_HOST=front \
    FRONT_PORT=80 \
    BACK_HOST=back \
    BACK_PORT=3000

# Port documenté du conteneur
EXPOSE 80

# Utilisateur non-root "nginx", créé par le paquet nginx
USER nginx

# SIGQUIT = arrêt gracieux de nginx (termine les requêtes en cours)
STOPSIGNAL SIGQUIT

# Vérifie que le proxy répond (127.0.0.1 car nginx n'écoute qu'en IPv4)
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1

# Script qui génère la config puis lance nginx
ENTRYPOINT ["/entrypoint.sh"]
