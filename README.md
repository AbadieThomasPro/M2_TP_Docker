# M2 TP Docker - Docker Cloud

Mise en place d'une architecture virtualisée basée sur Docker : images personnalisées (front, back, serveur web) orchestrées avec Docker Compose.

Aucune image applicative n'est récupérée telle quelle depuis Docker Hub : chaque image part d'un OS minimal (`alpine`) et tout le reste est installé et configuré par nos soins.

## Sujet : mini cloud de stockage

Un service de stockage de fichiers simplifié, à la manière d'un Google Drive minimal, hébergé sur notre propre « cloud » Docker.

| Fonctionnalité | Description |
|---|---|
| Envoyer un fichier | Upload depuis la page web |
| Lister les fichiers | Nom, taille, date d'envoi |
| Télécharger un fichier | Lien de téléchargement |
| Supprimer un fichier | Bouton de suppression |

### Ce que le sujet permet de montrer avec Docker

| Notion Docker | Mise en œuvre dans le projet |
|---|---|
| Images personnalisées | 3 images construites depuis `alpine` : front (Node), back (Node), gateway (nginx). |
| Persistance | Les fichiers sont stockés dans un **volume Docker** : ils survivent à l'arrêt, à la suppression et à la reconstruction des conteneurs. |
| Isolation réseau | Seul le front est publié. La gateway, le back et le stockage restent sur un réseau interne. |
| Limitation des ressources | CPU et mémoire par conteneur, plus une taille max d'upload imposée par nginx (`client_max_body_size`). |
| Scalabilité | Plusieurs instances du back derrière la gateway nginx, qui répartit la charge (voir [Scalabilité](#scalabilité)). |

### Avancement

| Étape | Statut |
|---|---|
| 3 images (front, back, gateway), compose, réseaux, healthchecks, SIGTERM | ✅ Fait |
| Chaîne front → gateway → back fonctionnelle (`/api/phrase`) | ✅ Fait |
| Volume `stockage` monté sur le back (droits, persistance testés) | ✅ Fait |
| API de fichiers (upload, liste, téléchargement, suppression) | ⏳ À faire |
| Interface web du stockage | ⏳ À faire |
| Scalabilité du back (plusieurs instances, répartition par nginx) | ⏳ À faire |

## Architecture actuelle

```
                 machine hôte
                      │ :8080 (seul port publié)
  ┌───────────────────┼──────────────────────────────────────────┐
  │ réseau "public"   ▼                                          │
  │            ┌─────────────┐                                   │
  │            │    front    │  Node : page + relais /api        │
  │            └──────┬──────┘                                   │
  ├───────────────────┼──────────────────────────────────────────┤
  │ réseau "interne"  │ http://gateway/api/...  (internal: true) │
  │                   ▼                                          │
  │            ┌─────────────┐        ┌─────────────┐            │
  │            │   gateway   │ ─────▶ │    back     │            │
  │            │    nginx    │  :3000 │ Node : API  │            │
  │            └─────────────┘        └─────────────┘            │
  └──────────────────────────────────────────────────────────────┘
```

1. Le navigateur charge la page sur `http://localhost:8080` (front).
2. `app.js` appelle `/api/phrase` sur la même origine, donc le front.
3. Le `server.js` du front relaie l'appel vers `http://gateway/api/phrase` (nom du service Docker).
4. La gateway nginx transmet la requête au back (`back:3000`), qui renvoie la phrase en JSON.

Seul le front est accessible depuis l'extérieur. La gateway et le back ne sont joignables que sur le réseau interne.

## Architecture cible

```
  Navigateur
      │ :8080
      ▼
  ┌─────────┐  http://gateway/api  ┌─────────┐   répartition    ┌─────────┐
  │  front  │ ───────────────────▶ │ gateway │ ───────────────▶ │ back #1 │──┐
  └─────────┘                      │  nginx  │ ──────┐          └─────────┘  │
                                   └─────────┘       │          ┌─────────┐  │   ┌────────────────┐
                                                     ├────────▶ │ back #2 │──┼──▶│ volume Docker  │
                                                     │          └─────────┘  │   │ "stockage"     │
                                                     │          ┌─────────┐  │   │ /data/fichiers │
                                                     └────────▶ │ back #3 │──┘   └────────────────┘
                                                                └─────────┘
```

## Scalabilité

L'objectif est de pouvoir lancer **plusieurs instances du back** avec une seule commande, sans changer de configuration. La gateway nginx répartit les requêtes entre elles.

### Principe

| Élément | Rôle dans la scalabilité |
|---|---|
| `docker compose up --scale back=3` (ou `deploy.replicas: 3`) | Lance 3 conteneurs identiques à partir de la même image `back`. |
| DNS interne Docker | Le nom de service `back` renvoie les adresses IP de **toutes** les instances. |
| nginx (`upstream`) | Répartit les requêtes `/api` entre les instances (round-robin par défaut). |
| Volume partagé | Toutes les instances lisent et écrivent dans le **même** volume `stockage` : un fichier envoyé via `back #1` est téléchargeable via `back #3`. |

### Conditions pour que ça fonctionne

1. **Back sans état (stateless)** : aucune donnée n'est gardée en mémoire dans le conteneur. Les fichiers et leurs informations (nom, taille, date) sont lus directement depuis le volume. N'importe quelle instance peut donc répondre à n'importe quelle requête.
2. **Pas de port publié sur le back** : plusieurs instances ne pourraient pas publier le même port sur la machine hôte. C'est déjà le cas, puisque seul le front est publié. C'est la gateway qui rend le scaling possible.
3. **Pas de `container_name`** sur le back : Docker doit pouvoir nommer lui-même chaque instance (`back-1`, `back-2`...).
4. **nginx doit voir les nouvelles instances** : nginx résout `back` au démarrage. Il faut soit utiliser le DNS de Docker avec un `resolver 127.0.0.11` et une durée de validité courte, soit recharger nginx (`nginx -s reload`) après un changement du nombre d'instances.
5. **Noms de fichiers uniques** : deux instances qui écrivent en même temps ne doivent pas écraser le même fichier. On peut par exemple préfixer chaque nom par un identifiant unique.

### Ressources

Les limites de `deploy.resources` s'appliquent **à chaque instance**. Avec 3 instances du back à 0,5 CPU et 192 Mo, le back peut consommer au total 1,5 CPU et 576 Mo. Le nombre d'instances se choisit en fonction des ressources de la machine.

### Démonstration prévue

Chaque réponse du back contiendra un en-tête `X-Served-By` avec le nom du conteneur qui a répondu. En rafraîchissant la page, on voit les requêtes passer d'une instance à l'autre, alors que tous les fichiers restent visibles.

### Pourquoi c'est un avantage de Docker par rapport aux VM

| | Machines virtuelles | Conteneurs Docker |
|---|---|---|
| Ajouter une instance | Créer et démarrer une VM complète (OS invité) : plusieurs minutes, plusieurs Go | Une commande (`--scale`) : quelques secondes, quelques Mo de mémoire par instance |
| Configuration | À reproduire sur chaque VM | Identique pour toutes les instances, car elles viennent de la même image |
| Ressources | Réservées par VM, même au repos | Partagées avec le noyau de l'hôte, limitées par conteneur (`cpus`, `memory`) |

## Structure du projet

```
.
├── Frontend/
│   ├── Dockerfile
│   ├── server.js        # serveur HTTP Node : sert la page et relaie /api vers la gateway
│   └── src/
│       ├── index.html   # page affichée
│       └── app.js       # JS client : récupère et affiche la phrase
├── Backend/
│   ├── Dockerfile
│   └── src/
│       └── server.js    # API HTTP Node qui renvoie une phrase
├── Gateway/
│   ├── Dockerfile
│   ├── nginx.conf.template  # config nginx avec ${VARIABLES} remplacées au démarrage
│   └── entrypoint.sh        # génère la config puis lance nginx
├── docker-compose.yml       # orchestration des 3 conteneurs
├── .env                     # valeurs de configuration lues par le compose
├── .gitattributes           # force les .sh en fins de ligne LF
├── AGENTS.md                # règles du projet pour les agents IA (CLAUDE.md l'importe)
├── questui-DESIGN.md        # design system de l'interface (thème RPG médiéval)
└── README.md
```

---

## Variables : ARG, ENV et .env

La configuration se fait à trois niveaux, chacun avec un rôle précis :

| Niveau | Où | Quand | Rôle |
|---|---|---|---|
| `ARG` | Dockerfile | **Build** uniquement | Paramètre la construction de l'image (version d'Alpine, port documenté). N'existe plus dans le conteneur, sauf s'il est recopié dans un `ENV`. |
| `ENV` | Dockerfile | **Run** | Valeurs **par défaut** de l'application, présentes dans l'image. L'image fonctionne seule, même sans compose. |
| `.env` | Racine du projet | Lecture par **compose** | Source unique des valeurs : compose remplace chaque `${VARIABLE}` du `docker-compose.yml` par sa valeur. |

```
 .env ──▶ docker-compose.yml ─┬─ build.args:   ──▶ ARG  (build de l'image)
                              ├─ environment:  ──▶ ENV  (surcharge au run, sans rebuild)
                              └─ deploy / ports ──▶ ressources CPU/mémoire, port publié
```

### ARG communs aux 3 images

| ARG | Défaut | Utilisation |
|---|---|---|
| `ALPINE_VERSION` | `3.20` | Déclaré **avant** `FROM` pour être utilisable dans `FROM alpine:${ALPINE_VERSION}`. On change la version de l'OS de toutes les images depuis le `.env`, sans toucher aux Dockerfile. |
| `PORT` | `80` (front, gateway) / `3000` (back) | Sert à `EXPOSE ${PORT}` et de valeur par défaut à `ENV PORT=${PORT}`. Le port documenté par l'image et le port d'écoute restent ainsi cohérents. |

### Pourquoi un `.env` ?
- **Une seule source de vérité** : les ports, la mémoire, les CPU et la phrase sont regroupés dans un seul fichier. Le `docker-compose.yml` ne contient plus de valeurs en dur.
- **Cohérence entre services** : `BACK_PORT` est utilisé à la fois par le back (port d'écoute) et par la gateway (port à joindre). Une seule modification met les deux à jour.
- **Surcharge simple** : une variable d'environnement du shell est prioritaire sur le `.env`. Par exemple, `BACK_PHRASE="Autre phrase" docker compose up -d` change la phrase sans modifier de fichier ni reconstruire l'image (testé).
- Le `.env` est **versionné volontairement** : il ne contient aucun secret, seulement de la configuration.

---

## Image Frontend

**Point d'entrée** de l'architecture. Le `server.js` a deux rôles :

| Requête reçue | Traitement |
|---|---|
| `/`, `/index.html`, `/app.js` | Fichiers de `src/` servis au navigateur |
| `/api/...` | Relayée vers `http://${GATEWAY_HOST}:${GATEWAY_PORT}` (la gateway), puis la réponse est renvoyée au navigateur |
| autre | `404` |

Le relais est nécessaire car le navigateur ne peut pas résoudre le nom de service Docker `gateway` : seul un conteneur du réseau interne le peut. Le navigateur appelle donc `/api/phrase` sur le front (même origine, pas de CORS), et c'est le front qui contacte la gateway. Si la gateway est injoignable, le front répond `502`.

Le relais transmet le corps des requêtes en flux, ce qui convient aux uploads. Si la gateway répond avant la fin de l'envoi (par exemple `413` pour un fichier trop gros), le front lit le reste du corps sans le transmettre : sans ça, le client restait bloqué à attendre de finir son envoi (bug trouvé et corrigé en testant la limite d'upload).

### Fichiers communs aux 3 images

| Fichier / instruction | Justification |
|---|---|
| `.dockerignore` | Le contexte de build ne contient que l'utile : build plus rapide, et pas de `node_modules` Windows, de `.git` ni de logs dans l'image (bonne pratique du cours). |
| `LABEL org.opencontainers.image.*` | Métadonnées au format standard OCI (titre, description, auteur, dépôt), lisibles avec `docker inspect` : l'image se décrit elle-même. |

### Image de base

| Choix | Justification |
|---|---|
| `alpine:3.20` | OS minimal (~8 Mo) : surface d'attaque réduite et image légère. On n'utilise pas l'image officielle `node` : Node est installé nous-mêmes. |
| Version fixée (`3.20`) plutôt que `latest` | Build reproductible : la même version d'OS et de Node à chaque build, pas de changement surprise. La version est passée par l'ARG `ALPINE_VERSION`. |
| Ordre des instructions | Ce qui change rarement en haut (OS, paquets, utilisateur, variables), le code (`COPY`) en bas. Modifier le code ne reconstruit que les dernières couches : les couches au-dessus restent en cache. |

Pas de **multi-stage build** : il n'y a aucune étape de compilation (pas de TypeScript, pas de bundler, pas de `npm install`). Un stage de build n'apporterait rien.

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

### Arguments de build (ARG)

| ARG | Défaut | Rôle |
|---|---|---|
| `ALPINE_VERSION` | `3.20` | Version de l'OS de base. |
| `PORT` | `80` | Port documenté (`EXPOSE`) et valeur par défaut de `ENV PORT`. |

### Arguments attendus au run (ENV)

Variables d'environnement surchargeables avec `-e` ou `environment:` dans le compose :

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `80` (vient de l'ARG) | Port d'écoute du serveur HTTP. |
| `NODE_OPTIONS` | `--max-old-space-size=128` | Mémoire max du tas Node (Mo). Variable lue par Node lui-même : pas besoin de shell dans la `CMD`. À aligner sur la limite mémoire du conteneur pour que Node libère la mémoire avant d'être tué par Docker. Dans le compose, la valeur vient de `FRONT_NODE_MAX_MEMORY`. |
| `GATEWAY_HOST` | `gateway` | Hôte vers lequel relayer `/api` : le nom du service gateway dans le compose. |
| `GATEWAY_PORT` | `80` | Port de la gateway. |
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
CMD ["node", "server.js"]
```

- **`ENTRYPOINT` = `tini`** : toujours exécuté en PID 1, il relaie les signaux à Node et nettoie les processus zombies. Node lancé seul en PID 1 ignore SIGTERM par défaut.
- **`CMD` en forme exec, sans shell** : Node est lancé directement par `tini` (vérifié avec `ps` : PID 1 = `tini`, son enfant direct = `node`). La limite mémoire passe par `NODE_OPTIONS`, que Node lit tout seul : plus besoin de `sh -c` pour remplacer une variable.
- **`CMD` séparée de l'`ENTRYPOINT`** : on peut la remplacer au run (`docker run front node -v`) tout en gardant `tini`.
- **Dans `server.js`** : à la réception de SIGTERM, le serveur arrête d'accepter les connexions, termine celles en cours puis quitte avec le code 0.

Résultat testé : un `docker stop` arrête le conteneur en moins d'une seconde, au lieu d'attendre le kill forcé à 10 s.

### Build et run

```bash
docker build -t front ./Frontend
docker run -d --name front -p 8080:80 -e NODE_OPTIONS=--max-old-space-size=128 -e GATEWAY_HOST=gateway --memory=192m --cpus=0.5 front
```

Seul, le front sert la page, mais `/api/phrase` renvoie `502` tant qu'aucune gateway n'est joignable : voir la section Orchestration.

---

## Image Backend

Petite API HTTP qui renvoie une phrase en JSON. Le front la récupère en passant par la gateway.

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
| `RUN mkdir -p /data/files && chown -R back:back /data` | Crée le dossier de stockage et le donne à `back` **avant** l'instruction `VOLUME`. Quand Docker crée un volume neuf, il y recopie le contenu et les droits de ce dossier de l'image. Sans ce `chown`, le volume appartiendrait à root et l'API, non-root, ne pourrait pas écrire. Vérifié : `/data` et `/data/files` appartiennent à `back`. |
| `VOLUME /data` | Déclare `/data` comme dossier de données hors de la couche du conteneur. Même avec un simple `docker run`, sans compose, Docker crée un volume anonyme au lieu d'écrire dans le conteneur. Toute instruction placée après `VOLUME` qui modifierait `/data` serait ignorée : d'où le `chown` juste avant. |
| `WORKDIR /app` | Dossier de travail de l'application. |
| `COPY src/ ./src/` | Copie du code de l'API, qui appartient à root : `back` peut le lire mais pas le modifier. Tout le code est dans `src/`, car l'API ne sert aucun fichier statique à séparer du code serveur. |
| `USER back` | Bascule sur l'utilisateur non-root pour l'exécution. |

### Ports exposés

| Port | Usage |
|---|---|
| `3000` | Port de l'API (valeur par défaut de `PORT`). Il n'est pas publié sur la machine hôte : seule la gateway y accède, via le réseau interne du compose. |

### Arguments de build (ARG)

| ARG | Défaut | Rôle |
|---|---|---|
| `ALPINE_VERSION` | `3.20` | Version de l'OS de base. |
| `PORT` | `3000` | Port documenté (`EXPOSE`) et valeur par défaut de `ENV PORT`. |

### Arguments attendus au run (ENV)

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `3000` (vient de l'ARG) | Port d'écoute de l'API. |
| `NODE_OPTIONS` | `--max-old-space-size=128` | Mémoire max du tas Node (Mo), lue par Node lui-même, à aligner sur la limite mémoire du conteneur. Dans le compose, la valeur vient de `BACK_NODE_MAX_MEMORY`. |
| `PHRASE` | `Hello World depuis le back !` | Phrase renvoyée par `/api/phrase`. Elle peut être changée au lancement sans rebuild de l'image. |
| `STORAGE_DIR` | `/data/files` | Dossier où l'API stockera les fichiers. Le code lit ce chemin au lieu de l'écrire en dur. Il doit rester sous `/data`, le point de montage du volume, sinon les fichiers seraient écrits dans le conteneur et perdus à sa suppression. |
| `TZ` | `Europe/Paris` | Fuseau horaire. |

### Healthcheck

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/health || exit 1
```

Contrairement au front, on interroge une route dédiée `/health` : elle vérifie que l'API répond sans dépendre de la logique métier. Le conteneur passe en `healthy`, ce qui permet à la gateway de démarrer seulement quand le back est prêt (`depends_on: condition: service_healthy`).

### Entrypoint et gestion de SIGTERM

```dockerfile
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/server.js"]
```

Même mécanisme que le Frontend : `tini` en PID 1 relaie les signaux à Node, lancé en forme exec sans shell. La mémoire est fixée par `NODE_OPTIONS`. Dans `server.js`, SIGTERM ferme le serveur proprement puis le processus quitte avec le code 0.

Résultat testé : `docker stop` arrête le conteneur en moins d'une seconde.

### Build et run

```bash
docker build -t back ./Backend
docker run -d --name back -p 3000:3000 -e PHRASE="Bonjour depuis le back" -e NODE_OPTIONS=--max-old-space-size=128 --memory=192m --cpus=0.5 back
```

Le `-p 3000:3000` sert uniquement à tester l'API seule (`curl http://localhost:3000/api/phrase`). Dans le compose, le back n'est pas publié.

---

## Image Gateway (serveur web)

Passerelle d'API (API gateway) basée sur nginx, utilisé en reverse proxy : elle fait la **liaison entre le front et le back**. Elle n'est pas publiée sur la machine hôte : seul le front la contacte, par son nom de service `gateway`, sur le réseau interne.

**Pourquoi « gateway » et pas « proxy » ?** Techniquement, nginx reste un reverse proxy. Mais son rôle dans l'architecture est plus large : c'est le **seul chemin vers l'API**. Il bloque tout ce qui n'est pas `/api`, impose des limites (taille des uploads) et répartira la charge entre les instances du back. Le nom « gateway » décrit ce rôle, et il évite la confusion avec le relais `/api` du front, qui fait lui aussi office de proxy.

### Routage

| Requête reçue | Traitement | Rôle |
|---|---|---|
| `/api/...` | Redirigée vers `back:3000` | Appels à l'API (ex. `/api/phrase`) |
| `/health` | _Répond lui-même_ `OK` | Santé de la gateway (healthcheck) |
| tout le reste | `404` | La gateway ne sert qu'à joindre l'API : rien d'autre n'est accessible à travers elle. |

La gateway isole le back : le front ne connaît que l'adresse `gateway`, pas celle du back. On peut changer ou déplacer le back en modifiant seulement `BACK_HOST` et `BACK_PORT` de la gateway.

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
| `80` | Port HTTP de la gateway, joint par le front sur le réseau interne (`GATEWAY_PORT`). Il n'est pas publié sur la machine hôte. |

### Arguments de build (ARG)

| ARG | Défaut | Rôle |
|---|---|---|
| `ALPINE_VERSION` | `3.20` | Version de l'OS de base. |
| `PORT` | `80` | Port documenté (`EXPOSE`) et valeur par défaut de `ENV PORT`. |

### Arguments attendus au run (ENV)

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `80` (vient de l'ARG) | Port d'écoute de nginx. |
| `WORKER_PROCESSES` | `1` | Nombre de processus workers nginx. À aligner sur le nombre de CPU alloués au conteneur (`cpus:` dans le compose). |
| `WORKER_CONNECTIONS` | `512` | Connexions simultanées max par worker. Plus la valeur est haute, plus nginx peut consommer de mémoire. |
| `BACK_HOST` / `BACK_PORT` | `back` / `3000` | Adresse du conteneur back (nom du service dans le compose). |
| `MAX_UPLOAD_MB` | `10` (`50` dans le `.env`) | Taille max d'un upload (`client_max_body_size`). Un fichier plus gros est refusé par la gateway (`413`) avant d'atteindre le back, ce qui protège sa mémoire et le stockage. Testé : 2 Mo envoyés avec une limite à 1 Mo → `413`. |
| `TZ` | `Europe/Paris` | Fuseau horaire. |

### Healthcheck

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1
```

La route `/health` est traitée directement par nginx, sans passer par le back : elle vérifie uniquement que la gateway est en vie.

On utilise `127.0.0.1` et non `localhost` : dans Alpine, `localhost` se résout d'abord en IPv6 (`::1`), alors que nginx n'écoute qu'en IPv4. Le healthcheck échouait avec `localhost`.

### Entrypoint et gestion des signaux

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

### Build et run

La gateway a besoin du back sur le même réseau Docker : nginx refuse de démarrer s'il ne trouve pas l'hôte `back`. Le front se branche ensuite sur ce réseau et joint la gateway par son nom.

```bash
docker build -t gateway ./Gateway
docker network create tp-net
docker run -d --name back  --network tp-net back
docker run -d --name gateway --network tp-net \
  -e WORKER_PROCESSES=1 -e WORKER_CONNECTIONS=512 --memory=64m --cpus=0.5 gateway
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

Toutes les valeurs viennent du fichier `.env` (voir [Variables : ARG, ENV et .env](#variables--arg-env-et-env)). Pour chaque service :
- `build.args` transmet les **ARG** du Dockerfile ;
- `environment:` surcharge les **ENV** du Dockerfile au run ;
- `deploy.resources` et `ports` utilisent aussi des variables du `.env`.

| Service | `build.args` (ARG) | `environment:` (ENV) | Variables du `.env` utilisées |
|---|---|---|---|
| `back` | `ALPINE_VERSION`, `PORT` | `PORT`, `NODE_OPTIONS`, `PHRASE`, `STORAGE_DIR`, `TZ` | `BACK_PORT`, `BACK_NODE_MAX_MEMORY`, `BACK_PHRASE`, `STORAGE_DIR`, `BACK_CPUS`, `BACK_MEMORY`, `BACK_MEMORY_RESERVATION` |
| `gateway` | `ALPINE_VERSION`, `PORT` | `PORT`, `WORKER_PROCESSES`, `WORKER_CONNECTIONS`, `BACK_HOST`, `BACK_PORT`, `MAX_UPLOAD_MB`, `TZ` | `GATEWAY_PORT`, `GATEWAY_WORKER_PROCESSES`, `GATEWAY_WORKER_CONNECTIONS`, `GATEWAY_CPUS`, `GATEWAY_MEMORY`, `GATEWAY_MEMORY_RESERVATION`, `BACK_PORT`, `MAX_UPLOAD_MB` |
| `front` | `ALPINE_VERSION`, `PORT` | `PORT`, `NODE_OPTIONS`, `GATEWAY_HOST`, `GATEWAY_PORT`, `TZ` | `FRONT_PORT`, `FRONT_PUBLISHED_PORT`, `FRONT_NODE_MAX_MEMORY`, `FRONT_CPUS`, `FRONT_MEMORY`, `FRONT_MEMORY_RESERVATION`, `GATEWAY_PORT` |

`ALPINE_VERSION` et `TZ` sont communs à tous les services.

Les noms d'hôte `gateway` et `back` sont les noms des services : le DNS interne de Docker les résout automatiquement vers les bons conteneurs. Ils sont écrits directement dans le compose, et non dans le `.env`, car ils dépendent de la structure du compose et non de la configuration. Aucune adresse IP n'est écrite en dur.

### Limitation des ressources

Définie dans `deploy.resources` pour chaque service :
- **`limits`** : plafond que le conteneur ne peut pas dépasser. En mémoire, s'il le dépasse il est tué (OOM) puis relancé grâce à `restart`.
- **`reservations`** : mémoire minimale garantie au conteneur.

| Service | CPU max | Mémoire max | Mémoire réservée | Justification |
|---|---|---|---|---|
| `back` | 0,5 CPU | 192 Mo | 64 Mo | Node consomme environ 10 Mo au repos. `NODE_OPTIONS=--max-old-space-size=128` limite le tas JavaScript : Node libère sa mémoire avant d'atteindre la limite du conteneur. La marge de 64 Mo couvre la mémoire hors tas (runtime, buffers). |
| `front` | 0,5 CPU | 192 Mo | 64 Mo | Même logique que le back. |
| `gateway` | 0,5 CPU | 64 Mo | 16 Mo | nginx est très léger (environ 2 Mo au repos). Avec `WORKER_PROCESSES=1`, un seul worker suffit pour 0,5 CPU : plus de workers que de CPU n'apporterait rien. |

Consommation mesurée au repos avec `docker stats` : gateway environ 2 Mo, front environ 9 Mo, back environ 10 Mo.

### Ordre de démarrage

```yaml
gateway:
  depends_on:
    back:
      condition: service_healthy

front:
  depends_on:
    gateway:
      condition: service_healthy
```

- La **gateway** attend que le back soit `healthy`. C'est nécessaire car nginx refuse de démarrer s'il ne peut pas résoudre `back`.
- Le **front** attend que la gateway soit `healthy` : la page n'est servie qu'une fois que toute la chaîne vers l'API est disponible.

Les healthchecks sont définis dans les Dockerfile de chaque image. L'ordre de démarrage obtenu est donc : `back` → `gateway` → `front`.

### Gestion de l'arrêt (SIGTERM)

- `docker compose down` envoie le signal d'arrêt à chaque conteneur : SIGTERM pour front et back, SIGQUIT pour la gateway (`STOPSIGNAL`).
- `stop_grace_period: 10s` : délai laissé à chaque conteneur pour s'arrêter proprement avant le kill forcé (SIGKILL).
- Tous les services s'arrêtent proprement bien avant ce délai : l'arrêt complet mesuré prend moins de 2 secondes.
- **Code de sortie vérifié** (`docker inspect -f '{{.State.ExitCode}}'`) : `0` signifie que le signal a été traité et l'arrêt propre, `1` une erreur de l'application, `137` (128 + 9) un SIGKILL après les 10 s, donc un signal ignoré.

| Service | Temps d'arrêt mesuré | Code de sortie |
|---|---|---|
| `front` | 0,73 s | `0` ✅ |
| `gateway` | 0,53 s | `0` ✅ |
| `back` | 0,47 s | `0` ✅ |

`restart: unless-stopped` relance automatiquement un conteneur qui plante, sauf s'il a été arrêté volontairement.

### Volume

```yaml
back:
  volumes:
    - stockage:/data
volumes:
  stockage:
```

| Choix | Justification |
|---|---|
| Un volume, donc des données hors du conteneur | Les fichiers du cloud doivent survivre à l'arrêt, à la suppression et à la reconstruction du conteneur : la couche d'écriture d'un conteneur disparaît avec lui. |
| **Volume nommé** plutôt que bind mount | Recommandé par le cours : géré par Docker (`docker volume ls / inspect`), isolé de l'hôte et **portable**. Un bind mount dépend d'un chemin propre à la machine et casserait sur un autre poste, notamment sous Windows. |
| Nommé dans le compose, en plus du `VOLUME` du Dockerfile | Le `VOLUME` seul crée un volume **anonyme différent** à chaque `up` : on perdrait l'accès aux données. Le nom `stockage` garantit que c'est le même volume qui est remonté à chaque fois. |
| Monté uniquement dans le back | Seule l'API manipule les fichiers. Ni le front ni la gateway n'y ont accès (moindre privilège). |

**Cycle de vie** (vérifié) :

| Commande | Effet sur les fichiers |
|---|---|
| `docker compose down` puis `up` | ✅ Conservés : un fichier écrit par `back` est toujours là après le redémarrage. |
| `docker compose up --build` (rebuild) | ✅ Conservés : le volume est indépendant de l'image. |
| `docker compose down -v` | ❌ Supprimés : le volume `docker-cloud_stockage` est détruit. |

Commandes utiles : `docker volume inspect docker-cloud_stockage` (emplacement sur l'hôte Docker), `docker compose exec back ls -l /data/files`.

### Réseaux

| Réseau | Services | Rôle |
|---|---|---|
| `public` | `front` | Réseau relié à la machine hôte, utilisé pour publier le port `8080:80`. |
| `interne` (`internal: true`) | `front`, `gateway`, `back` | Réseau privé sans accès vers l'extérieur. La gateway et le back n'y sont joignables que par les autres conteneurs. |

Seul le front publie un port (`8080:80`). La gateway et le back n'ont aucun `ports:` : leur port (`80` et `3000`) n'existe que sur le réseau interne et n'est pas joignable depuis la machine hôte (vérifié avec `docker compose ps`). Même en cas de faille dans le front, le back ne peut être atteint qu'à travers la gateway, qui ne laisse passer que `/api/`.

**Deux conteneurs sur le port 80 ?** Le front et la gateway écoutent tous les deux sur le port `80`, mais il n'y a pas de conflit : chaque conteneur a sa propre pile réseau et sa propre adresse IP. Un conflit n'apparaîtrait qu'en publiant deux fois le même port sur la machine hôte, et seul le front est publié (sur `8080`).
