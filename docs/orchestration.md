# Orchestration (docker-compose.yml)

[← Retour au README](../README.md) · [Documentation](README.md)

## Lancement

```bash
docker compose up -d --build   # build des 3 images puis démarrage
docker compose ps              # état et santé des conteneurs
docker compose down            # arrêt propre (SIGTERM / SIGQUIT) et suppression
```

L'application est accessible sur **http://localhost:8080**.

## Arguments traduits dans le compose

Toutes les valeurs viennent du fichier `.env` (voir [Configuration : ARG, ENV et .env](configuration.md#configuration--arg-env-et-env)). Pour chaque service :
- `build.args` transmet les **ARG** du Dockerfile ;
- `environment:` surcharge les **ENV** du Dockerfile au run ;
- `deploy.resources` et `ports` utilisent aussi des variables du `.env`.

| Service | `build.args` (ARG) | `environment:` (ENV) | Variables du `.env` utilisées |
|---|---|---|---|
| `back` | `ALPINE_VERSION`, `PORT`, `STORAGE_GID` | `PORT`, `NODE_OPTIONS`, `STORAGE_DIR`, `MAX_UPLOAD_MB`, `TTL_DEFAULT_H`, `TTL_MAX_H`, `STORAGE_QUOTA_MB`, `TZ` | `BACK_PORT`, `BACK_NODE_MAX_MEMORY`, `STORAGE_DIR`, `STORAGE_GID`, `MAX_UPLOAD_MB`, `TTL_DEFAULT_H`, `TTL_MAX_H`, `STORAGE_QUOTA_MB`, `BACK_CPUS`, `BACK_MEMORY`, `BACK_MEMORY_RESERVATION` |
| `gateway` | `ALPINE_VERSION`, `PORT` | `PORT`, `WORKER_PROCESSES`, `WORKER_CONNECTIONS`, `BACK_HOST`, `BACK_PORT`, `MAX_UPLOAD_MB`, `TZ` | `GATEWAY_PORT`, `GATEWAY_WORKER_PROCESSES`, `GATEWAY_WORKER_CONNECTIONS`, `GATEWAY_CPUS`, `GATEWAY_MEMORY`, `GATEWAY_MEMORY_RESERVATION`, `BACK_PORT`, `MAX_UPLOAD_MB` |
| `front` | `ALPINE_VERSION`, `PORT` | `PORT`, `NODE_OPTIONS`, `GATEWAY_HOST`, `GATEWAY_PORT`, `TZ` | `FRONT_PORT`, `FRONT_PUBLISHED_PORT`, `FRONT_NODE_MAX_MEMORY`, `FRONT_CPUS`, `FRONT_MEMORY`, `FRONT_MEMORY_RESERVATION`, `GATEWAY_PORT` |
| `cleaner` | `ALPINE_VERSION`, `STORAGE_GID` | `STORAGE_DIR`, `CLEANUP_INTERVAL_S`, `INCOMING_MAX_AGE_MIN` | `STORAGE_DIR`, `STORAGE_GID`, `CLEANUP_INTERVAL_S`, `INCOMING_MAX_AGE_MIN`, `CLEANER_CPUS`, `CLEANER_MEMORY`, `CLEANER_MEMORY_RESERVATION` |

`ALPINE_VERSION` et `TZ` sont communs à tous les services.

Les noms d'hôte `gateway` et `back` sont les noms des services : le DNS interne de Docker les résout automatiquement vers les bons conteneurs. Ils sont écrits directement dans le compose, et non dans le `.env`, car ils dépendent de la structure du compose et non de la configuration. Aucune adresse IP n'est écrite en dur.

## Limitation des ressources

Définie pour chaque service dans le compose, avec des valeurs venant du `.env` :

| Réglage | Rôle |
|---|---|
| `deploy.resources.limits.cpus` | Plafond de CPU (`0.5` = la moitié d'un cœur). Au-delà, le conteneur est ralenti, pas tué. |
| `deploy.resources.limits.memory` | Plafond de mémoire. S'il est dépassé, le noyau tue le processus (OOM killer, code `137`), puis `restart: unless-stopped` le relance. |
| `memswap_limit` (égal à la limite mémoire) | **Désactive la swap.** Par défaut, Docker ajoute autant de swap que de RAM (mesuré : `MemorySwap` = 2 × la limite) : un conteneur « limité à 128 Mo » pouvait en réalité occuper 256 Mo, en ralentissant au lieu de s'arrêter. |
| `deploy.resources.reservations.memory` | Mémoire **garantie** (réservation souple) : si l'hôte manque de mémoire, Docker reprend d'abord la mémoire des conteneurs qui dépassent leur réservation. |

Valeurs retenues, justifiées par le [benchmark](benchmark.md) :

| Service | CPU | Mémoire max | Tas Node | Réservation | Pic mesuré |
|---|---|---|---|---|---|
| `front` | **0,25** | 128 Mo | 64 Mo | 32 Mo | ~25 % CPU · ~37 Mo (5 envois en parallèle) |
| `gateway` (nginx) | **0,10** | **48 Mo** | – | 8 Mo | ~10 % CPU · ~4 Mo en charge, ~26 Mo pendant 5 envois en parallèle |
| `back` | **0,65** | 128 Mo | 64 Mo | 32 Mo | ~65 % CPU · ~33 Mo |
| `cleaner` (worker) | **0,10** | **16 Mo** | – | 6 Mo | ~10 % CPU · ~4 Mo pendant une passe sur 10 000 fichiers ; 0 % · 0,5 Mo au repos |
| `bench` (outil) | 1 | 32 Mo | – | – | – |

## Ordre de démarrage

```yaml
gateway:
  depends_on:
    back:
      condition: service_healthy

front:
  depends_on:
    gateway:
      condition: service_healthy

cleaner:
  depends_on:
    back:
      condition: service_healthy
```

- La **gateway** attend que le back soit `healthy`. Depuis l'ajout du `resolver`, nginx démarrerait sans le back, mais il répondrait `502` à chaque appel d'API (testé) : on ne l'ouvre qu'une fois le back prêt.
- Le **front** attend que la gateway soit `healthy` : la page n'est servie qu'une fois que toute la chaîne vers l'API est disponible.
- Le **cleaner** attend que le back soit `healthy`, pour une raison de **droits** : le premier conteneur qui monte un volume neuf y recopie le contenu et les droits du dossier de **son** image. Le back crée `/data/files` en `2775`, groupe `stockage` ; l'image du cleaner n'a pas de `/data`. Si le cleaner passait en premier, le volume serait initialisé avec un dossier appartenant à root, et le back ne pourrait plus y écrire.

Les healthchecks sont définis dans les Dockerfile de chaque image. L'ordre de démarrage obtenu est donc : `back` → (`gateway` et `cleaner` en parallèle) → `front`.

## Gestion de l'arrêt (SIGTERM)

- `docker compose down` envoie le signal d'arrêt à chaque conteneur : SIGTERM pour front, back et cleaner, SIGQUIT pour la gateway (`STOPSIGNAL`).
- `stop_grace_period: 10s` : délai laissé à chaque conteneur pour s'arrêter proprement avant le kill forcé (SIGKILL).
- Tous les services s'arrêtent proprement bien avant ce délai : l'arrêt complet mesuré prend moins de 2 secondes.
- **Code de sortie vérifié** (`docker inspect -f '{{.State.ExitCode}}'`) : `0` signifie que le signal a été traité et l'arrêt propre, `1` une erreur de l'application, `137` (128 + 9) un SIGKILL après les 10 s, donc un signal ignoré.

| Service | Temps d'arrêt mesuré | Code de sortie |
|---|---|---|
| `front` | 0,73 s | `0` ✅ |
| `gateway` | 0,53 s | `0` ✅ |
| `back` | 0,47 s | `0` ✅ |
| `cleaner` (au repos) | 0,38 s | `0` ✅ |
| `cleaner` (pendant une passe sur 10 000 fichiers) | 0,5 à 0,6 s | `0` ✅ |

Le cas du cleaner est détaillé dans [sa section](conteneurs/cleaner.md#entrypoint-et-gestion-de-sigterm) : c'est le service pour lequel l'arrêt propre a demandé le plus de travail.

`restart: unless-stopped` relance automatiquement un conteneur qui plante, sauf s'il a été arrêté volontairement.

## Volume

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
| Monté dans le back et le cleaner seulement | Le back écrit, le cleaner supprime. Ni le front ni la gateway n'y ont accès (moindre privilège). |
| **Volume partagé** entre deux services | Les deux conteneurs voient les mêmes fichiers. Les droits passent par un **groupe Unix commun** (`stockage`, GID 1500 dans les deux images) et un dossier en `2775` avec le bit setgid. Les deux utilisateurs ont des **UID différents** (1001 et 1002) : le cleaner agit grâce au groupe, pas en se faisant passer pour le propriétaire. |

**Cycle de vie** (vérifié) :

| Commande | Effet sur les fichiers |
|---|---|
| `docker compose down` puis `up` | ✅ Conservés : un fichier écrit par `back` est toujours là après le redémarrage. |
| `docker compose up --build` (rebuild) | ✅ Conservés : le volume est indépendant de l'image. |
| `docker compose down -v` | ❌ Supprimés : le volume `docker-cloud_stockage` est détruit. |

**Attention :** Docker ne recopie le contenu et les droits du dossier de l'image que dans un volume **vide**. Après un changement des droits dans le Dockerfile (comme l'ajout du groupe `stockage`), un volume existant garde les anciens droits : il faut le recréer avec `docker compose down -v`.

Commandes utiles : `docker volume inspect docker-cloud_stockage` (emplacement sur l'hôte Docker), `docker compose exec back ls -l /data/files`.

## Durcissement : systèmes de fichiers en lecture seule

Tous les services tournent avec **`read_only: true`** : le système de fichiers de leur image ne peut pas être modifié pendant l'exécution. Même en cas de faille dans une application, un attaquant ne peut ni modifier le code, ni déposer un binaire ou un script, ni altérer la configuration.

Un service qui a besoin d'écrire reçoit seulement ce qu'il lui faut :

| Service | Où il peut écrire | Pourquoi |
|---|---|---|
| `front` | Nulle part | Il lit ses fichiers et relaie les requêtes, rien d'autre. |
| `back` | Le volume `/data` uniquement | Les envois arrivent directement dans le volume (`.incoming/`, puis renommage). |
| `gateway` | `tmpfs` **`/tmp`** de 8 Mo (`GATEWAY_TMPFS_SIZE`) | Config générée au démarrage, PID, dossiers temporaires de nginx. Contenu réel : quelques Ko. |
| `cleaner` | Le volume `/data` + `tmpfs` **`/tmp`** de 1 Mo | Suppressions dans le volume, fichier de heartbeat pour le healthcheck. |
| `bench` | Nulle part | `ab` n'écrit rien. |

**Pourquoi des `tmpfs` si petits ?** Un `tmpfs` est stocké en RAM et **compté dans la limite mémoire** du conteneur (48 Mo pour la gateway). Le limiter évite qu'un remplissage de `/tmp` consomme toute la mémoire du service. C'est aussi ce qui a imposé de ne laisser nginx bufferiser **ni les envois** (`proxy_request_buffering off`) **ni les téléchargements** (`proxy_max_temp_file_size 0`) sur disque : sans ce second réglage, un téléchargement de 40 Mo était coupé à 7 Mo (voir [Image Gateway](conteneurs/gateway.md#envois-de-fichiers-et-scaling)).

**Vérifications :**

| Test | Résultat |
|---|---|
| `touch` dans `/app` (front, back), `/etc/nginx` (gateway), `/` (cleaner) | `Read-only file system` pour les 4 |
| `HostConfig.ReadonlyRootfs` | `true` pour les 4 services |
| Config nginx générée dans `/tmp` | Présente (`nginx.conf`, `nginx.pid`...) |
| Envoi puis téléchargement lent de 40 Mo | Complet, `/tmp` reste vide |
| `docker compose run --rm gateway nginx -t` | Fonctionne toujours (le `tmpfs` est aussi monté pour un `run`) |
| Bench (500 requêtes) | 0 échec |
| Arrêt | Code `0` pour les 4 services |

## Réseaux

| Réseau | Services | Rôle |
|---|---|---|
| `public` | `front` | Réseau relié à la machine hôte, utilisé pour publier le port `8080:80`. |
| `interne-front` (`internal: true`) | `front`, `gateway` | Liaison front → gateway uniquement. Aucun accès extérieur. |
| `interne-back` (`internal: true`) | `gateway`, `back` | Liaison gateway → back uniquement. Aucun accès extérieur. |
| *aucun* (`network_mode: none`) | `cleaner` | Le worker ne parle à personne : il n'a que l'interface `lo` (vérifié). Il partage seulement le volume avec le back. |

**Pourquoi deux réseaux internes plutôt qu'un ?** Avec un seul réseau `interne` partagé par les 3 services, le test a montré que **le front pouvait joindre `back:3000` en direct** et contourner la gateway, donc son filtrage (`/api/` seulement) et sa limite d'upload. Avec deux réseaux, chaque service ne voit que ses voisins directs. La gateway, branchée sur les deux, est le **seul pont** entre le front et le back. C'est le même principe que l'exemple du cours, où nginx ne peut pas joindre la base de données.

Seul le front publie un port (`8080:80`). La gateway et le back n'ont aucun `ports:` : leur port (`80` et `3000`) n'existe que sur les réseaux internes.

**Vérifications** (`docker network inspect`, `docker compose ps`, `wget` depuis chaque conteneur) :

| Test | Résultat |
|---|---|
| Ports publiés sur l'hôte | Seulement `front` (`0.0.0.0:8080->80`) |
| `interne-front` / `interne-back` | `Internal: true`, avec respectivement `front` + `gateway` et `gateway` + `back` |
| Hôte → `127.0.0.1:8080` (front) | ✅ 200 |
| Hôte → `127.0.0.1:3000` (back) | ⛔ injoignable |
| front → gateway | ✅ joignable (chemin prévu) |
| **front → back:3000** | ⛔ **bloqué** (avant la séparation : joignable) |
| gateway → back:3000 | ✅ joignable (chemin prévu) |
| back → front | ⛔ bloqué |
| back → Internet / gateway → Internet | ⛔ bloqué (`internal: true`) |
| front → Internet | ✅ joignable : c'est la contrepartie du réseau `public`, nécessaire pour publier son port |

Les liaisons restantes (gateway → front, back → gateway) existent parce que ces services partagent un réseau, mais elles ne présentent pas de risque : la gateway n'expose que `/health` et `/api/`, et le front ne sert que la page.

**Deux conteneurs sur le port 80 ?** Le front et la gateway écoutent tous les deux sur le port `80`, mais il n'y a pas de conflit : chaque conteneur a sa propre pile réseau et sa propre adresse IP. Un conflit n'apparaîtrait qu'en publiant deux fois le même port sur la machine hôte, et seul le front est publié (sur `8080`).
