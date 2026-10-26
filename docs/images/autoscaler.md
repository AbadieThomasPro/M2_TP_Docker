# Image Autoscaler (mode Swarm)

[← Retour au README](../../README.md) · [Documentation](../README.md)

Swarm sait faire tourner plusieurs instances d'un service, mais **pas en changer le nombre seul** : sans outil, il reste celui de `replicas` ou d'un `docker service scale` tapé à la main. Les autoscalers existants sont des images du Docker Hub, interdites par le sujet. Cette 5e image est donc la nôtre : une boucle qui mesure le CPU et la mémoire des services, et appelle `docker service scale` quand un seuil est franchi.

Elle n'existe qu'en **mode Swarm** (`docker-stack.yml`) : le compose n'a pas d'instances à piloter.

| Ce qu'elle fait | Comment |
|---|---|
| Choisit les services à piloter | Ceux qui portent le label `autoscale.enabled=true`, entre leurs labels `autoscale.min` et `autoscale.max`. Aucun nom en dur ; le cleaner, sans label, n'est **jamais** multiplié. |
| Mesure | Un seul `docker stats` par boucle pour tous les services. CPU = **moyenne** des instances, en % de la **limite** du service (lue dans le service) ; mémoire = **pire** instance. |
| Décide | +1 instance au-dessus de 70 % de CPU ou 80 % de mémoire sur 3 relevés de suite ; −1 sous 25 % de CPU et 50 % de mémoire sur 6 relevés. Pause après chaque action. Détail et justification des seuils dans [Autoscaling](../scalabilite.md#autoscaling--le-nombre-dinstances-suit-la-charge). |
| Protège la machine | Refuse toute instance qui ferait dépasser **80 %** du CPU ou de la mémoire de l'hôte à la somme des limites de la stack. Ramène dans ses bornes un service modifié à la main. |

Point de départ : l'exemple fourni en cours (alpine + `docker-cli`, socket monté, placement sur un manager). Ses défauts sont corrigés, voir [la comparaison](../scalabilite.md#ce-qui-change-par-rapport-à-lexemple-fourni).

## Image de base

| Choix | Justification |
|---|---|
| `alpine:3.22` + `docker-cli` | Le **client** Docker suffit : il envoie les commandes au moteur de l'hôte par le socket. Le moteur n'est pas dans l'image. |
| Script shell BusyBox plutôt qu'application | Même raisonnement que le cleaner : lire des chiffres, comparer à des seuils et lancer une commande, c'est ce que font `sh` et `awk`. Ni `bash` ni `curl`, contrairement à l'exemple : ils ne servaient à rien. |

## Dépendances installées

| Paquet | Rôle |
|---|---|
| `docker-cli` | `docker stats`, `docker service ls / inspect / scale`, `docker info`. |

Image finale : **57 Mo**, presque entièrement le client Docker.

## Manipulations sur l'OS

| Instruction | Explication |
|---|---|
| `adduser -D -H -u 1003 autoscaler` | Utilisateur dédié, non-root, UID distinct du back (1001) et du cleaner (1002). |
| Ajout au groupe du socket (ARG `DOCKER_GID`) | Parler au moteur Docker demande le droit d'écrire sur `/var/run/docker.sock`. Mesuré sur Docker Desktop : le socket appartient au **groupe 0, droits `660`**. L'utilisateur reste non-root (UID 1003) mais rejoint ce groupe en **groupe secondaire** (son groupe principal reste le sien). Sur un Linux classique, `DOCKER_GID` prend le GID du groupe `docker` de l'hôte : l'image crée alors ce groupe. |
| `ENV DOCKER_CONFIG=/tmp/.docker` | Le client Docker veut écrire sa configuration ; le système de fichiers est en lecture seule, sauf `/tmp`. |
| `COPY --chmod=755 autoscale.sh` | Copié en dernier, sans couche `RUN chmod`. |

## Ports et réseau

Aucun port, et **aucun besoin de réseau** : le socket est un fichier, pas une connexion réseau. Swarm n'accepte pas `network_mode: none` : l'autoscaler est donc branché sur son propre réseau overlay **`isole-autoscaler`** (`internal: true`), dont il est le seul membre, distinct du réseau `isole` du cleaner. Vérifié : il ne résout ni `front` ni `example.com`.

## Arguments de build (ARG)

| ARG | Défaut | Rôle |
|---|---|---|
| `ALPINE_VERSION` | `3.22` | Version de l'OS de base. |
| `DOCKER_GID` | `0` | GID du groupe propriétaire du socket Docker (0 sur Docker Desktop, mesuré). |

## Arguments attendus au run (ENV)

| Variable | Défaut | Rôle |
|---|---|---|
| `AUTOSCALE_INTERVAL_S` | `10` | Pause entre deux boucles. Une boucle prend ~14 s en tout : `docker stats` met ~4 s avec 0,10 CPU. |
| `AUTOSCALE_CPU_UP` / `AUTOSCALE_CPU_DOWN` | `70` / `25` | Seuils CPU (% de la limite du service), pour monter / descendre. |
| `AUTOSCALE_MEM_UP` / `AUTOSCALE_MEM_DOWN` | `80` / `50` | Seuils mémoire (% de la limite, pire instance). |
| `AUTOSCALE_UP_SAMPLES` / `AUTOSCALE_DOWN_SAMPLES` | `3` / `6` | Relevés consécutifs nécessaires avant d'agir. |
| `AUTOSCALE_COOLDOWN_UP_S` / `AUTOSCALE_COOLDOWN_DOWN_S` | `30` / `60` | Pause minimale après une action, avant une montée / une descente. |
| `AUTOSCALE_HOST_BUDGET_PCT` | `80` | Part maximale du CPU et de la mémoire de la machine que la stack peut réserver en limites. |
| `HEARTBEAT_FILE` | `/tmp/heartbeat` | Preuve de vie lue par le healthcheck. |

Les bornes de chaque service ne sont pas des variables de l'autoscaler mais des **labels des services** (`deploy.labels` dans `docker-stack.yml`, valeurs `*_AUTOSCALE_MIN` / `*_AUTOSCALE_MAX` du `.env`) : chaque service déclare lui-même s'il peut être multiplié, et jusqu'où.

## Healthcheck

Comme le cleaner (pas de port à interroger) : chaque boucle met à jour `/tmp/heartbeat`, le healthcheck vérifie qu'il a **moins de 3 intervalles** (3 et non 2 : un relevé `docker stats` peut prendre plusieurs secondes).

## Entrypoint et gestion de SIGTERM

```dockerfile
ENTRYPOINT ["/usr/local/bin/autoscale.sh"]
```

Script en PID 1, sans `tini`, avec la même structure que le cleaner : `trap` sur SIGTERM, relevé `docker stats` lancé **en arrière-plan + `wait`** (le signal est traité tout de suite au lieu d'attendre la fin du relevé), `sleep & wait` entre deux boucles. Aucune décision n'est prise à moitié : la commande `docker service scale --detach` rend la main immédiatement.

Au démarrage, le script vérifie qu'il peut joindre le moteur et qu'il tourne sur un **manager** ; sinon il sort en erreur avec un message clair (et Swarm le relance 10 s plus tard), plutôt que de tourner sans rien pouvoir faire.

| Mesure | Résultat |
|---|---|
| `docker stop` | **0,6 s, code `0`** (« arrêt propre ») |
| Mise à jour du service (`docker service update`) | ancienne tâche : code `0` |

## Ressources (mesurées)

**0,10 CPU et 64 Mo**, réservation 0,05 CPU / 8 Mo. Au repos : **0,6 Mo** de mémoire. 64 Mo couvrent le client Docker pendant un relevé ; plus de CPU raccourcirait seulement le relevé, ce qui n'apporte rien avec une boucle toutes les 10 s.

## Sécurité : le socket Docker

Monter `/var/run/docker.sock`, c'est donner **l'équivalent d'un accès root** à la machine : qui parle au moteur peut lancer n'importe quel conteneur. C'est pourtant le seul moyen de changer le nombre d'instances depuis un conteneur. Le risque est **assumé et réduit** :

| Mesure | Vérifié |
|---|---|
| Le socket est le **seul** montage (avec un `tmpfs` de 1 Mo) | `docker inspect` : `bind:/var/run/docker.sock`, `tmpfs:/tmp` |
| Utilisateur non-root | `uid=1003(autoscaler)` |
| Système de fichiers en lecture seule | `touch /etc/test` → `Read-only file system` |
| Aucun réseau joignable | ni les autres services, ni Internet |
| Image construite par nous, sans outil superflu | ni `bash` ni `curl` |
| Une seule instance, sur un manager | `replicas: 1`, `node.role == manager` |

Un `:ro` sur le montage du socket serait **trompeur** : il empêche de modifier le fichier, pas d'envoyer des commandes au moteur. Il n'est donc pas utilisé.

## Build et run

```bash
docker build -t docker-cloud/autoscaler --build-arg DOCKER_GID=0 ./Autoscaler   # fait par swarm-deploy
# test hors stack, sur un Swarm actif (services portant les labels autoscale.*)
docker run -d --name autoscaler --network none --read-only --tmpfs /tmp:size=1m \
  --cpus 0.10 --memory 64m --memory-swap 64m -v /var/run/docker.sock:/var/run/docker.sock docker-cloud/autoscaler
docker logs -f autoscaler   # une ligne par relevé, une ligne par décision
```
