# M2 TP Docker - Docker Cloud

Mise en place d'une architecture virtualisée basée sur Docker : images personnalisées (front, back, serveur web) orchestrées avec Docker Compose.

Aucune image applicative n'est récupérée telle quelle depuis Docker Hub : chaque image part d'un OS minimal (`alpine`) et tout le reste est installé et configuré par nos soins.

## Architecture

```
                 machine hôte
                      │ :8080 (seul port publié)
  ┌───────────────────┼──────────────────────────────────────────┐
  │ réseau "public"   ▼                                          │
  │            ┌─────────────┐                                   │
  │            │    front    │  Node : page + relais /api        │
  │            └──────┬──────┘                                   │
  ├───────────────────┼──────────────────────────────────────────┤
  │ réseau "interne"  │ http://proxy/api/...  (internal: true)   │
  │                   ▼                                          │
  │            ┌─────────────┐        ┌─────────────┐            │
  │            │    proxy    │ ─────▶ │    back     │            │
  │            │    nginx    │  :3000 │ Node : API  │            │
  │            └─────────────┘        └─────────────┘            │
  └──────────────────────────────────────────────────────────────┘
```

1. Le navigateur charge la page sur `http://localhost:8080` (front).
2. `app.js` appelle `/api/phrase` sur la même origine, donc le front.
3. Le `server.js` du front relaie l'appel vers `http://proxy/api/phrase` (nom du service Docker).
4. Le proxy nginx transmet la requête au back (`back:3000`), qui renvoie la phrase en JSON.

Seul le front est accessible depuis l'extérieur. Le proxy et le back ne sont joignables que sur le réseau interne.

## Structure du projet

```
.
├── Frontend/
│   ├── Dockerfile
│   ├── server.js        # serveur HTTP Node : sert la page et relaie /api vers le proxy
│   └── src/
│       ├── index.html   # page affichée
│       └── app.js       # JS client : récupère et affiche la phrase
├── Backend/
│   ├── Dockerfile
│   └── src/
│       └── server.js    # API HTTP Node qui renvoie une phrase
├── Proxy/
│   ├── Dockerfile
│   ├── nginx.conf.template  # config nginx avec ${VARIABLES} remplacées au démarrage
│   └── entrypoint.sh        # génère la config puis lance nginx
├── docker-compose.yml       # orchestration des 3 conteneurs
├── .gitattributes           # force les .sh en fins de ligne LF
└── README.md
```

---

## Image Frontend

**Point d'entrée** de l'architecture. Le `server.js` a deux rôles :

| Requête reçue | Traitement |
|---|---|
| `/`, `/index.html`, `/app.js` | Fichiers de `src/` servis au navigateur |
| `/api/...` | Relayée vers `http://${PROXY_HOST}:${PROXY_PORT}` (le proxy), puis la réponse est renvoyée au navigateur |
| autre | `404` |

Le relais est nécessaire car le navigateur ne peut pas résoudre le nom de service Docker `proxy` : seul un conteneur du réseau interne le peut. Le navigateur appelle donc `/api/phrase` sur le front (même origine, pas de CORS), et c'est le front qui contacte le proxy. Si le proxy est injoignable, le front répond `502`.

### Image de base

| Choix | Justification |
|---|---|
| `alpine:3.20` | OS minimal (~8 Mo) : surface d'attaque réduite et image légère. On n'utilise pas l'image officielle `node` : Node est installé nous-mêmes. |
| Version fixée (`3.20`) plutôt que `latest` | Build reproductible : la même version d'OS et de Node à chaque build, pas de changement surprise. |

### Dépendances installées

Installées via `apk add --no-cache` (`--no-cache` : on ne conserve pas l'index des paquets dans l'image, ce qui l'allège).

| Dépendance | Rôle | Pourquoi ce choix |
|---|---|---|
| `nodejs` | Exécute `server.js`, qui distribue la page et relaie `/api` | Seul le runtime est installé, sans `npm` : le serveur et le relais utilisent uniquement le module natif `http`, donc aucune librairie externe n'est nécessaire. |
| `tini` | Init minimal lancé en PID 1 | Transmet correctement les signaux (SIGTERM lors d'un `docker stop`) à Node et nettoie les processus zombies. Sans lui, Node en PID 1 peut ignorer SIGTERM et le conteneur est tué brutalement après 10 s. |
| `tzdata` | Base des fuseaux horaires | Permet d'avoir l'heure de Paris (`TZ=Europe/Paris`) dans les logs au lieu de l'UTC. |

`wget`, utilisé par le healthcheck, est déjà fourni par BusyBox dans Alpine : rien à installer.

### Manipulations sur l'OS

| Instruction | Explication |
|---|---|
| `ENV TZ=Europe/Paris` | Fuseau horaire du conteneur (s'appuie sur `tzdata`). |
| `RUN adduser -D -H front` | Crée un utilisateur `front` sans mot de passe (`-D`) ni dossier personnel (`-H`). Le serveur tourne avec cet utilisateur et non en root : en cas de faille, l'attaquant n'a pas les droits root dans le conteneur. |
| `WORKDIR /app` | Dossier de travail de l'application. |
| `COPY server.js ./` et `COPY src/ ./src/` | Les fichiers appartiennent à root : l'utilisateur `front` peut les lire mais pas les modifier. `server.js` reste en dehors de `src/` pour ne jamais être servi au navigateur. |
| `USER front` | Bascule sur l'utilisateur non-root pour l'exécution. |

### Ports exposés

| Port | Usage |
|---|---|
| `80` | Port HTTP du serveur front (valeur par défaut de `PORT`). C'est le seul port publié sur la machine hôte dans le compose (`8080:80`). |

`EXPOSE` documente les ports : leur publication réelle se fait au run (`-p` ou `ports:` dans le compose).

### Arguments attendus au run

Variables d'environnement surchargeables avec `-e` ou `environment:` dans le compose :

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `80` | Port d'écoute du serveur HTTP. |
| `NODE_MAX_MEMORY` | `128` | Mémoire max du tas Node en Mo (`--max-old-space-size`). À aligner sur la limite mémoire du conteneur pour que Node libère la mémoire avant d'être tué par Docker. |
| `PROXY_HOST` | `proxy` | Hôte vers lequel relayer `/api` : le nom du service proxy dans le compose. |
| `PROXY_PORT` | `80` | Port du proxy. |
| `TZ` | `Europe/Paris` | Fuseau horaire. |

### Healthcheck

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/ || exit 1
```

Docker interroge la page toutes les 10 s. Le conteneur passe en `healthy` quand le serveur répond, ce qui permettra au compose d'ordonner le démarrage (`depends_on: condition: service_healthy`).

### Entrypoint et gestion de SIGTERM

```dockerfile
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["sh", "-c", "exec node --max-old-space-size=${NODE_MAX_MEMORY} server.js"]
```

- **`ENTRYPOINT` = `tini`** : toujours exécuté en PID 1, il relaie les signaux au processus enfant.
- **`CMD` via `sh -c`** : nécessaire pour que la variable `${NODE_MAX_MEMORY}` soit remplacée au lancement.
- **`exec`** : remplace le shell par Node, pour que ce soit Node (et non `sh`) qui reçoive SIGTERM.
- **Dans `server.js`** : à la réception de SIGTERM, le serveur arrête d'accepter les connexions, termine celles en cours puis quitte avec le code 0.

Résultat testé : un `docker stop` arrête le conteneur en moins d'une seconde, au lieu d'attendre le kill forcé à 10 s.

### Build et run

```bash
docker build -t front ./Frontend
docker run -d --name front -p 8080:80 -e NODE_MAX_MEMORY=128 -e PROXY_HOST=proxy --memory=192m --cpus=0.5 front
```

Seul, le front sert la page, mais `/api/phrase` renvoie `502` tant qu'aucun proxy n'est joignable : voir la section Orchestration.

---

## Image Backend

Petite API HTTP qui renvoie une phrase en JSON. Le front la récupère en passant par le proxy.

### Routes

| Route | Réponse |
|---|---|
| `GET /api/phrase` | `{"phrase": "..."}` : la phrase à afficher dans le front |
| `GET /health` | `OK` : utilisée par le healthcheck |
| Toute autre route | `404` avec `{"error": "Not found"}` |

### Image de base

Même choix que le Frontend : `alpine:3.20`, OS minimal en version fixée, avec Node installé par nos soins.

### Dépendances installées

Installées via `apk add --no-cache`, comme pour le Frontend.

| Dépendance | Rôle | Pourquoi ce choix |
|---|---|---|
| `nodejs` | Exécute `src/server.js`, l'API HTTP | Seul le runtime est installé, sans `npm` : l'API n'utilise que le module natif `http` (pas d'Express), donc aucune librairie externe n'est nécessaire. |
| `tini` | Init minimal lancé en PID 1 | Relaie SIGTERM à Node et nettoie les processus zombies, pour un arrêt propre lors d'un `docker stop`. |
| `tzdata` | Base des fuseaux horaires | Heure de Paris dans les logs de l'API. |

`wget` (healthcheck) est fourni par BusyBox : rien à installer.

### Manipulations sur l'OS

| Instruction | Explication |
|---|---|
| `ENV TZ=Europe/Paris` | Fuseau horaire du conteneur. |
| `RUN adduser -D -H back` | Crée un utilisateur `back` sans mot de passe ni dossier personnel. L'API ne tourne pas en root. Un utilisateur distinct de celui du front permet d'identifier chaque service. |
| `WORKDIR /app` | Dossier de travail de l'application. |
| `COPY src/ ./src/` | Copie du code de l'API, qui appartient à root : `back` peut le lire mais pas le modifier. Tout le code est dans `src/`, car l'API ne sert aucun fichier statique à séparer du code serveur. |
| `USER back` | Bascule sur l'utilisateur non-root pour l'exécution. |

### Ports exposés

| Port | Usage |
|---|---|
| `3000` | Port de l'API (valeur par défaut de `PORT`). Il n'est pas publié sur la machine hôte : seul le proxy y accède, via le réseau interne du compose. |

### Arguments attendus au run

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `3000` | Port d'écoute de l'API. |
| `NODE_MAX_MEMORY` | `128` | Mémoire max du tas Node en Mo (`--max-old-space-size`), à aligner sur la limite mémoire du conteneur. |
| `PHRASE` | `Hello World depuis le back !` | Phrase renvoyée par `/api/phrase`. Elle peut être changée au lancement sans rebuild de l'image. |
| `TZ` | `Europe/Paris` | Fuseau horaire. |

### Healthcheck

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/health || exit 1
```

Contrairement au front, on interroge une route dédiée `/health` : elle vérifie que l'API répond sans dépendre de la logique métier. Le conteneur passe en `healthy`, ce qui permet au proxy de démarrer seulement quand le back est prêt (`depends_on: condition: service_healthy`).

### Entrypoint et gestion de SIGTERM

```dockerfile
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["sh", "-c", "exec node --max-old-space-size=${NODE_MAX_MEMORY} src/server.js"]
```

Même mécanisme que le Frontend : `tini` en PID 1 relaie les signaux, `sh -c` remplace `${NODE_MAX_MEMORY}`, puis `exec` laisse la place à Node. Dans `server.js`, SIGTERM ferme le serveur proprement puis le processus quitte avec le code 0.

Résultat testé : `docker stop` arrête le conteneur en moins d'une seconde.

### Build et run

```bash
docker build -t back ./Backend
docker run -d --name back -p 3000:3000 -e PHRASE="Bonjour depuis le back" -e NODE_MAX_MEMORY=128 --memory=192m --cpus=0.5 back
```

Le `-p 3000:3000` sert uniquement à tester l'API seule (`curl http://localhost:3000/api/phrase`). Dans le compose, le back n'est pas publié.

---

## Image Proxy (serveur web)

Reverse proxy nginx : il fait la **liaison entre le front et le back**. Il n'est pas publié sur la machine hôte : seul le front le contacte, par son nom de service `proxy`, sur le réseau interne.

### Routage

| Requête reçue | Traitement | Rôle |
|---|---|---|
| `/api/...` | Redirigée vers `back:3000` | Appels à l'API (ex. `/api/phrase`) |
| `/health` | _Répond lui-même_ `OK` | Santé du proxy (healthcheck) |
| tout le reste | `404` | Le proxy ne sert qu'à joindre l'API : rien d'autre n'est accessible à travers lui. |

Le proxy isole le back : le front ne connaît que l'adresse `proxy`, pas celle du back. On peut changer ou déplacer le back en modifiant seulement `BACK_HOST` et `BACK_PORT` du proxy.

### Image de base

`alpine:3.20`, comme les autres images. On n'utilise pas l'image officielle `nginx` : nginx est installé par nos soins depuis les paquets Alpine.

### Dépendances installées

Installées via `apk add --no-cache`.

| Dépendance | Rôle | Pourquoi ce choix |
|---|---|---|
| `nginx` | Serveur web / reverse proxy | Référence pour ce rôle : léger, performant, et une techno différente des images Node, adaptée au besoin « serveur web ». |
| `gettext-envsubst` | Commande `envsubst` | Remplace les `${VARIABLES}` du modèle de config par les valeurs passées au run. On installe uniquement ce sous-paquet, et non `gettext` complet, pour garder une image légère. |
| `tzdata` | Base des fuseaux horaires | Heure de Paris dans les logs d'accès nginx. |

Pas de `tini` ici : nginx est conçu pour tourner en PID 1. Son processus maître gère lui-même les signaux et ses processus workers.

### Manipulations sur l'OS

| Instruction | Explication |
|---|---|
| `ENV TZ=Europe/Paris` | Fuseau horaire du conteneur. |
| `COPY nginx.conf.template /etc/nginx/` | Modèle de configuration nginx, avec des variables à remplacer au démarrage. |
| `COPY --chmod=755 entrypoint.sh /` | Script de démarrage, rendu exécutable directement à la copie (pas de `RUN chmod` en plus). |
| `USER nginx` | L'utilisateur `nginx` est créé par le paquet nginx : pas besoin d'en créer un. nginx tourne donc sans les droits root. |
| Fichiers d'exécution dans `/tmp` (config générée, PID, fichiers temporaires) | Un utilisateur non-root ne peut pas écrire dans `/etc/nginx` ni `/var/lib/nginx` : tout ce que nginx écrit au run va dans `/tmp`. |
| Logs vers `/dev/stdout` et `/dev/stderr` | Les logs ne sont pas écrits dans des fichiers dans le conteneur : ils sont visibles avec `docker logs`. |

### Ports exposés

| Port | Usage |
|---|---|
| `80` | Port HTTP du proxy, joint par le front sur le réseau interne (`PROXY_PORT`). Il n'est pas publié sur la machine hôte. |

### Arguments attendus au run

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `80` | Port d'écoute de nginx. |
| `WORKER_PROCESSES` | `1` | Nombre de processus workers nginx. À aligner sur le nombre de CPU alloués au conteneur (`cpus:` dans le compose). |
| `WORKER_CONNECTIONS` | `512` | Connexions simultanées max par worker. Plus la valeur est haute, plus nginx peut consommer de mémoire. |
| `BACK_HOST` / `BACK_PORT` | `back` / `3000` | Adresse du conteneur back (nom du service dans le compose). |
| `TZ` | `Europe/Paris` | Fuseau horaire. |

### Healthcheck

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1
```

La route `/health` est traitée directement par nginx, sans passer par le back : elle vérifie uniquement que le proxy est en vie.

On utilise `127.0.0.1` et non `localhost` : dans Alpine, `localhost` se résout d'abord en IPv6 (`::1`), alors que nginx n'écoute qu'en IPv4. Le healthcheck échouait avec `localhost`.

### Entrypoint et gestion des signaux

```dockerfile
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/entrypoint.sh"]
```

Le script `entrypoint.sh` fait deux choses :

1. **Génère la config** : `envsubst` remplace les variables du modèle et écrit `/tmp/nginx.conf`. La liste des variables est donnée explicitement à `envsubst` pour ne pas effacer les variables propres à nginx (`$host`, `$remote_addr`...).
2. **Lance nginx avec `exec`** : nginx remplace le shell et devient PID 1, il reçoit donc directement les signaux de Docker. `daemon off` le garde au premier plan, sinon le conteneur s'arrêterait aussitôt.

**Pourquoi `STOPSIGNAL SIGQUIT` ?** Pour nginx, SIGTERM provoque un arrêt *rapide* qui coupe les connexions en cours, alors que SIGQUIT provoque un arrêt *gracieux* qui termine les requêtes en cours avant de quitter. Avec `STOPSIGNAL`, `docker stop` envoie SIGQUIT au lieu de SIGTERM. Si un SIGTERM est quand même reçu, nginx le gère aussi et s'arrête.

Résultat testé : `docker stop` arrête le proxy en moins d'une seconde.

### Build et run

Le proxy a besoin du back sur le même réseau Docker : nginx refuse de démarrer s'il ne trouve pas l'hôte `back`. Le front se branche ensuite sur ce réseau et joint le proxy par son nom.

```bash
docker build -t proxy ./Proxy
docker network create tp-net
docker run -d --name back  --network tp-net back
docker run -d --name proxy --network tp-net \
  -e WORKER_PROCESSES=1 -e WORKER_CONNECTIONS=512 --memory=64m --cpus=0.5 proxy
docker run -d --name front --network tp-net -p 8080:80 front
```

Puis `http://localhost:8080/` affiche la page avec la phrase du back. Le compose remplace ces commandes et gère l'ordre de démarrage.

---

## Orchestration (docker-compose.yml)

### Lancement

```bash
docker compose up -d --build   # build des 3 images puis démarrage
docker compose ps              # état et santé des conteneurs
docker compose down            # arrêt propre (SIGTERM / SIGQUIT) et suppression
```

L'application est accessible sur **http://localhost:8080**.

### Arguments traduits dans le compose

Chaque argument attendu par les images (voir les sections ci-dessus) est passé dans le bloc `environment:` de son service :

| Service | Variables passées |
|---|---|
| `back` | `PORT=3000`, `NODE_MAX_MEMORY=128`, `PHRASE`, `TZ` |
| `proxy` | `PORT=80`, `WORKER_PROCESSES=1`, `WORKER_CONNECTIONS=512`, `BACK_HOST=back`, `BACK_PORT=3000`, `TZ` |
| `front` | `PORT=80`, `NODE_MAX_MEMORY=128`, `PROXY_HOST=proxy`, `PROXY_PORT=80`, `TZ` |

Les noms d'hôte `proxy` et `back` sont les noms des services : le DNS interne de Docker les résout automatiquement vers les bons conteneurs. Aucune adresse IP n'est écrite en dur.

### Limitation des ressources

Définie dans `deploy.resources` pour chaque service :
- **`limits`** : plafond que le conteneur ne peut pas dépasser. En mémoire, s'il le dépasse il est tué (OOM) puis relancé grâce à `restart`.
- **`reservations`** : mémoire minimale garantie au conteneur.

| Service | CPU max | Mémoire max | Mémoire réservée | Justification |
|---|---|---|---|---|
| `back` | 0,5 CPU | 192 Mo | 64 Mo | Node consomme environ 10 Mo au repos. `NODE_MAX_MEMORY=128` limite le tas JavaScript : Node libère sa mémoire avant d'atteindre la limite du conteneur. La marge de 64 Mo couvre la mémoire hors tas (runtime, buffers). |
| `front` | 0,5 CPU | 192 Mo | 64 Mo | Même logique que le back. |
| `proxy` | 0,5 CPU | 64 Mo | 16 Mo | nginx est très léger (environ 2 Mo au repos). Avec `WORKER_PROCESSES=1`, un seul worker suffit pour 0,5 CPU : plus de workers que de CPU n'apporterait rien. |

Consommation mesurée au repos avec `docker stats` : proxy environ 2 Mo, front environ 9 Mo, back environ 10 Mo.

### Ordre de démarrage

```yaml
proxy:
  depends_on:
    back:
      condition: service_healthy

front:
  depends_on:
    proxy:
      condition: service_healthy
```

- Le **proxy** attend que le back soit `healthy`. C'est nécessaire car nginx refuse de démarrer s'il ne peut pas résoudre `back`.
- Le **front** attend que le proxy soit `healthy` : la page n'est servie qu'une fois que toute la chaîne vers l'API est disponible.

Les healthchecks sont définis dans les Dockerfile de chaque image. L'ordre de démarrage obtenu est donc : `back` → `proxy` → `front`.

### Gestion de l'arrêt (SIGTERM)

- `docker compose down` envoie le signal d'arrêt à chaque conteneur : SIGTERM pour front et back, SIGQUIT pour le proxy (`STOPSIGNAL`).
- `stop_grace_period: 10s` : délai laissé à chaque conteneur pour s'arrêter proprement avant le kill forcé (SIGKILL).
- Tous les services s'arrêtent proprement bien avant ce délai : l'arrêt complet mesuré prend moins de 2 secondes.

`restart: unless-stopped` relance automatiquement un conteneur qui plante, sauf s'il a été arrêté volontairement.

### Réseaux

| Réseau | Services | Rôle |
|---|---|---|
| `public` | `front` | Réseau relié à la machine hôte, utilisé pour publier le port `8080:80`. |
| `interne` (`internal: true`) | `front`, `proxy`, `back` | Réseau privé sans accès vers l'extérieur. Le proxy et le back n'y sont joignables que par les autres conteneurs. |

Seul le front publie un port (`8080:80`). Le proxy et le back n'ont aucun `ports:` : leur port (`80` et `3000`) n'existe que sur le réseau interne et n'est pas joignable depuis la machine hôte (vérifié avec `docker compose ps`). Même en cas de faille dans le front, le back ne peut être atteint qu'à travers le proxy, qui ne laisse passer que `/api/`.

**Deux conteneurs sur le port 80 ?** Le front et le proxy écoutent tous les deux sur le port `80`, mais il n'y a pas de conflit : chaque conteneur a sa propre pile réseau et sa propre adresse IP. Un conflit n'apparaîtrait qu'en publiant deux fois le même port sur la machine hôte, et seul le front est publié (sur `8080`).
