# Image Gateway (serveur web)

[← Retour au README](../../README.md) · [Documentation](../README.md)

Passerelle d'API (API gateway) basée sur nginx, utilisé en reverse proxy : elle fait la **liaison entre le front et le back**. Elle n'est pas publiée sur la machine hôte : seul le front la contacte, par son nom de service `gateway`, sur le réseau `interne-front`.

**Pourquoi « gateway » et pas « proxy » ?** Techniquement, nginx reste un reverse proxy. Mais son rôle dans l'architecture est plus large : c'est le **seul chemin vers l'API**. Il bloque tout ce qui n'est pas `/api`, impose des limites (taille des uploads) et répartira la charge entre les instances du back. Le nom « gateway » décrit ce rôle, et il évite la confusion avec le relais `/api` du front, qui fait lui aussi office de proxy.

## Routage

| Requête reçue | Traitement | Rôle |
|---|---|---|
| `/api/...` | Redirigée vers `back:3000` | Appels à l'API (ex. `/api/files`) |
| `/health` | _Répond lui-même_ `OK` | Santé de la gateway (healthcheck) |
| tout le reste | `404` | La gateway ne sert qu'à joindre l'API : rien d'autre n'est accessible à travers elle. |

La gateway isole le back : le front ne connaît que l'adresse `gateway`, pas celle du back. On peut changer ou déplacer le back en modifiant seulement `BACK_HOST` et `BACK_PORT` de la gateway.

## Envois de fichiers et scaling

| Directive (`nginx.conf.template`) | Justification | Vérifié |
|---|---|---|
| `proxy_request_buffering off` | Par défaut, nginx **reçoit l'envoi en entier** dans un fichier temporaire avant de le transmettre au back : double écriture disque, attente avant que le back ne commence, et un `/tmp` assez grand pour 50 Mo par envoi simultané. Désactivé, l'envoi est transmis au back **au fil de l'eau** et écrit une seule fois, dans le volume. | Envoi de 40 Mo ralenti à 4 Mo/s, en regardant les fichiers ouverts par nginx (`/proc/*/fd`, car nginx supprime son fichier temporaire de l'arborescence tout en le gardant ouvert) : **1 fichier temporaire** avec la mise en tampon par défaut, **0** avec notre réglage. |
| `proxy_http_version 1.1` + `Connection ""` | Sans mise en tampon, nginx doit pouvoir transmettre un corps envoyé par morceaux (`chunked`), ce qui n'existe qu'en HTTP/1.1. Par défaut, nginx parle HTTP/1.0 au back. | Envois de 40 Mo → `201`. |
| `client_max_body_size ${MAX_UPLOAD_MB}m` | Inchangé : le refus (`413`) reste fait par nginx **avant** que le corps n'atteigne le back. | Envoi de 60 Mo (limite 50) → `413`. |
| `proxy_max_temp_file_size 0` | Par défaut, quand le back envoie plus vite que le client ne télécharge, nginx stocke la différence **sur disque** (jusqu'à 1 Go). Avec un `/tmp` en lecture seule hormis un `tmpfs` de 8 Mo, ce stockage déborde. Avec `0`, nginx relaie au rythme du client, sans fichier temporaire. | **Avant** : téléchargement de 40 Mo à 2 Mo/s **coupé à 7 Mo**, avec un `200` côté client (échec silencieux) et `No space left on device` dans les logs nginx. **Après** : 40 Mo reçus en entier, `/tmp` vide, gateway à 9,8 Mo de mémoire. |
| `resolver 127.0.0.11 valid=10s ipv6=off` | Le DNS interne de Docker est interrogé toutes les 10 s au plus, au lieu d'une seule fois au démarrage : les instances du back ajoutées ou retirées par `docker compose up --scale back=N` sont prises en compte **sans redémarrer nginx**. `ipv6=off` : nos réseaux sont en IPv4, inutile d'attendre des réponses AAAA. | `--scale back=3` : les 3 instances répondent à tour de rôle (`X-Served-By` différent), et la gateway n'a pas été redémarrée. Retour à 1 instance → `200`. |
| `set $back_upstream ...` + `proxy_pass $back_upstream` | Une adresse écrite en dur dans `proxy_pass` est résolue une seule fois, au démarrage. Passer par une variable oblige nginx à utiliser le `resolver` à chaque requête. | Idem. |

**Conséquence sur le démarrage :** avant, nginx refusait de démarrer s'il ne trouvait pas `back`. Maintenant, il démarre et répond `502` à `/api/` tant que le back est absent (testé : `502` sans back, `200` dès son retour). Le `depends_on: service_healthy` de la gateway reste utile pour ne pas exposer ces `502` au démarrage de la stack.

## Image de base

`alpine:3.22`, comme les autres images. On n'utilise pas l'image officielle `nginx` : nginx est installé par nos soins depuis les paquets Alpine.

## Dépendances installées

Installées via `apk add --no-cache`.

| Dépendance | Rôle | Pourquoi ce choix |
|---|---|---|
| `nginx` | Serveur web / reverse proxy | Référence pour ce rôle : léger, performant, et une techno différente des images Node, adaptée au besoin « serveur web ». |
| `gettext-envsubst` | Commande `envsubst` | Remplace les `${VARIABLES}` du modèle de config par les valeurs passées au run. On installe uniquement ce sous-paquet, et non `gettext` complet, pour garder une image légère. |
| `tzdata` | Base des fuseaux horaires | Heure de Paris dans les logs d'accès nginx. |

Pas de `tini` ici : nginx est conçu pour tourner en PID 1. Son processus maître gère lui-même les signaux et ses processus workers.

## Manipulations sur l'OS

| Instruction | Explication |
|---|---|
| `ENV TZ=Europe/Paris` | Fuseau horaire du conteneur. |
| `COPY nginx.conf.template /etc/nginx/` | Modèle de configuration nginx, avec des variables à remplacer au démarrage. |
| `COPY --chmod=755 entrypoint.sh /` | Script de démarrage, rendu exécutable directement à la copie (pas de `RUN chmod` en plus). |
| `USER nginx` | L'utilisateur `nginx` est créé par le paquet nginx : pas besoin d'en créer un. nginx tourne donc sans les droits root. |
| Fichiers d'exécution dans `/tmp` (config générée, PID, fichiers temporaires) | Un utilisateur non-root ne peut pas écrire dans `/etc/nginx` ni `/var/lib/nginx` : tout ce que nginx écrit au run va dans `/tmp`. |
| Logs vers `/dev/stdout` et `/dev/stderr` | Les logs ne sont pas écrits dans des fichiers dans le conteneur : ils sont visibles avec `docker logs`. |

## Ports exposés

| Port | Usage |
|---|---|
| `80` | Port HTTP de la gateway, joint par le front sur le réseau `interne-front` (`GATEWAY_PORT`). Il n'est pas publié sur la machine hôte. |

## Arguments de build (ARG)

| ARG | Défaut | Rôle |
|---|---|---|
| `ALPINE_VERSION` | `3.22` | Version de l'OS de base. |
| `PORT` | `80` | Port documenté (`EXPOSE`) et valeur par défaut de `ENV PORT`. |

## Arguments attendus au run (ENV)

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `80` (vient de l'ARG) | Port d'écoute de nginx. |
| `WORKER_PROCESSES` | `1` | Nombre de processus workers nginx. À aligner sur le nombre de CPU alloués au conteneur (`cpus:` dans le compose). |
| `WORKER_CONNECTIONS` | `512` | Connexions simultanées max par worker. Plus la valeur est haute, plus nginx peut consommer de mémoire. |
| `BACK_HOST` / `BACK_PORT` | `back` / `3000` | Adresse du conteneur back (nom du service dans le compose). |
| `MAX_UPLOAD_MB` | `10` (`50` dans le `.env`) | Taille max d'un upload (`client_max_body_size`). Un fichier plus gros est refusé par la gateway (`413`) avant d'atteindre le back, ce qui protège sa mémoire et le stockage. Testé : 2 Mo envoyés avec une limite à 1 Mo → `413`. |
| `TZ` | `Europe/Paris` | Fuseau horaire. |

## Healthcheck

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1
```

La route `/health` est traitée directement par nginx, sans passer par le back : elle vérifie uniquement que la gateway est en vie.

On utilise `127.0.0.1` et non `localhost` : dans Alpine, `localhost` se résout d'abord en IPv6 (`::1`), alors que nginx n'écoute qu'en IPv4. Le healthcheck échouait avec `localhost`.

## Entrypoint et gestion des signaux

```dockerfile
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-e", "/dev/stderr", "-c", "/tmp/nginx.conf", "-g", "daemon off;"]
```

C'est le modèle **« wrapper d'init »** du cours : l'`ENTRYPOINT` prépare l'environnement, la `CMD` contient la commande à lancer. Le script `entrypoint.sh` fait deux choses :

1. **Génère la config** : `envsubst` remplace les variables du modèle et écrit `/tmp/nginx.conf`. La liste des variables est donnée explicitement à `envsubst` pour ne pas effacer les variables propres à nginx (`$host`, `$remote_addr`...).
2. **Lance la `CMD` avec `exec "$@"`** : la commande remplace le shell et devient PID 1, elle reçoit donc directement les signaux de Docker. `daemon off` garde nginx au premier plan, sinon le conteneur s'arrêterait aussitôt.

**Pourquoi séparer la commande du script ?** La `CMD` devient remplaçable au run tout en gardant la config générée. Par exemple, `docker compose run --rm gateway nginx -t -c /tmp/nginx.conf` vérifie la config générée (testé : « syntax is ok »), et `docker compose run --rm gateway sh` ouvre un shell pour déboguer.

**Pourquoi `STOPSIGNAL SIGQUIT` ?** Pour nginx, SIGTERM provoque un arrêt *rapide* qui coupe les connexions en cours, alors que SIGQUIT provoque un arrêt *gracieux* qui termine les requêtes en cours avant de quitter. Avec `STOPSIGNAL`, `docker stop` envoie SIGQUIT au lieu de SIGTERM. Si un SIGTERM est quand même reçu, nginx le gère aussi et s'arrête.

Résultat testé : `docker stop` arrête la gateway en moins d'une seconde.

## Build et run

La gateway a besoin du back sur le même réseau Docker. Elle démarre même s'il est absent (le nom `back` est résolu à chaque requête), mais répond alors `502` à `/api/`. Le front se branche ensuite sur ce réseau et joint la gateway par son nom.

```bash
docker build -t gateway ./Gateway
docker network create tp-net
docker run -d --name back  --network tp-net back
docker run -d --name gateway --network tp-net \
  -e WORKER_PROCESSES=1 -e WORKER_CONNECTIONS=512 --memory=48m --memory-swap=48m --cpus=0.1 gateway
docker run -d --name front --network tp-net -p 8080:80 front
```

Puis `http://localhost:8080/` affiche l'application. Le compose remplace ces commandes et gère l'ordre de démarrage.
