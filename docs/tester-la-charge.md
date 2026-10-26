# Tester la montée en charge et l'autoscaling

[← Retour au README](../README.md) · [Documentation](README.md)

Cette page permet de **rejouer nos mesures** : charger l'application, voir l'autoscaler ajouter puis retirer des instances, et vérifier les garde-fous. Tout passe par l'outil de charge du dossier [`Bench/`](../Bench), une image construite par nos soins comme les autres (alpine + `ab`).

## Les outils

| Outil | Rôle | Système |
|---|---|---|
| Image `docker-cloud/bench` ([Bench/Dockerfile](../Bench/Dockerfile)) | `ab` (Apache Bench) : envoie N requêtes, C en parallèle, et mesure débit, latence, échecs. Utilisable comme une commande (`ENTRYPOINT ["ab"]`) | Tous |
| Service `bench` du compose | Le même outil, dans le profil `bench` : il ne démarre **jamais** avec un simple `docker compose up` | Tous |
| [Bench/run-autoscale-demo.sh](../Bench/run-autoscale-demo.sh) / [.ps1](../Bench/run-autoscale-demo.ps1) | **Démonstration de l'autoscaling** : 3 min de charge puis 5 min de repos, nombre d'instances affiché toutes les 10 s, puis résultat d'`ab` et décisions de l'autoscaler | Linux, macOS / Windows |
| [Bench/run-bench.ps1](../Bench/run-bench.ps1) | Mesure du compose : pics CPU et mémoire de chaque service sous charge | Windows |
| [Bench/run-swarm-bench.ps1](../Bench/run-swarm-bench.ps1) | Benchmark de dimensionnement en Swarm (1, 2, 3, 5 back × 4 niveaux de charge), CPU en % de la limite | Windows |

> Toutes les mesures se font **depuis l'intérieur de Docker** (l'outil rejoint le réseau `public`, comme un vrai client du front) : elles ne dépendent ni du navigateur ni du réseau de la machine.

---

## Test 1 : charger la version compose

```bash
docker compose up -d --build --wait
docker compose --profile bench run --rm bench -n 5000 -c 50 http://front/api/files   # 5 000 requêtes, 50 en parallèle
docker stats                                                                          # dans un autre terminal : CPU et mémoire en direct
```

| À regarder dans la sortie d'`ab` | Attendu (mesuré) |
|---|---|
| `Requests per second` | ~166 req/s (1 seul back, limité à 0,65 CPU) |
| `Failed requests` | **0** |
| `docker stats` pendant la charge | Aucun service au-delà de sa limite (`cpus` du `.env`) : le CPU plafonne, la mémoire reste loin de la limite |

Le compose a un nombre d'instances **fixe** : c'est le mode Swarm qui ajoute des instances.

---

## Test 2 : voir l'autoscaling (mode Swarm)

### 1. Déployer la stack Swarm

```bash
docker compose down                     # le compose et Swarm publient tous deux le port 8080
docker swarm init                       # une seule fois
./swarm-deploy.sh                       # Windows : powershell -ExecutionPolicy Bypass -File swarm-deploy.ps1
docker stack services cloud             # attendre : back 2/2, gateway 1/1, front 1/1, cleaner 1/1, autoscaler 1/1
```

> **Sous Linux** (hors Docker Desktop), le socket Docker n'appartient pas au groupe 0 mais au groupe `docker`. Avant de déployer, mettre son GID dans le `.env` :
> `DOCKER_GID=$(stat -c %g /var/run/docker.sock)` (par exemple `DOCKER_GID=999`). Sinon l'autoscaler ne peut pas joindre Docker : il le signale dans son log (« moteur Docker inaccessible ») et Swarm le relance.

### 2. Lancer la démonstration

```bash
./Bench/run-autoscale-demo.sh            # Windows : powershell -ExecutionPolicy Bypass -File Bench/run-autoscale-demo.ps1
docker service logs -f cloud_autoscaler  # dans un autre terminal (facultatif) : chaque relevé, chaque décision
```

Paramètres : `./Bench/run-autoscale-demo.sh <charge en s> <requêtes en parallèle> <repos en s>` (défaut `180 50 300`).

### 3. Ce qui doit se passer (mesuré sur notre machine)

| Moment | Affichage | Pourquoi |
|---|---|---|
| Départ | `back=2/2 gateway=1/1 front=1/1` | Les minimums (labels `autoscale.min`) |
| ~40 s | `back=2/3` puis `3/3` | Back au-dessus de 70 % de sa limite CPU sur **3 relevés de suite** |
| ~90 s | `gateway=1/2` puis `2/2` | Avec un back de plus, le goulot passe à la gateway |
| Fin de la charge + ~70 s | `back=2/2 gateway=1/1` | 6 relevés sous 25 % : retour aux minimums, sans oscillation |
| Résultat d'`ab` | `Failed requests: 0` | Les instances ajoutées ou retirées ne coupent aucune requête |

Extrait des décisions affichées à la fin :

```
cloud_back : 2 -> 3 instance(s) (cpu 103 %, mem 22 % au-dessus des seuils 70 % / 80 % sur 3 relevés ; machine après ajout : cpu 35 %, mem 9 %)
cloud_gateway : 1 -> 2 instance(s) (cpu 98 %, mem 6 % au-dessus des seuils 70 % / 80 % sur 3 relevés ; machine après ajout : cpu 37 %, mem 11 %)
cloud_back : 3 -> 2 instance(s) (cpu 0 %, mem 21 % sous les seuils 25 % / 50 % sur 6 relevés)
```

> **Garder la durée par défaut (3 min).** L'autoscaler attend 3 relevés hauts de suite (~40 s) avant d'agir, pour ne pas réagir à un pic isolé. Sur une charge d'1 minute, le goulot passe d'un service à l'autre avant que l'un d'eux ait cumulé 3 relevés : aucune instance n'est ajoutée (constaté). C'est voulu.

Les chiffres exacts (temps, débit) dépendent de la machine : sur une machine plus puissante, la charge par défaut peut ne pas suffire à dépasser 70 % ; augmenter alors la concurrence (`./Bench/run-autoscale-demo.sh 180 150 300`).

### 4. Sans script (n'importe quel système)

```bash
docker compose --profile bench build bench                                    # construit l'image de l'outil
docker service create --name bench --network cloud_public --restart-condition none \
  docker-cloud/bench -t 180 -n 10000000 -c 50 http://front/api/files          # 3 min de charge en arrière-plan
docker stack services cloud                                                   # à relancer : les REPLICAS augmentent
docker service logs bench                                                     # résultat d'ab à la fin
docker service rm bench                                                       # nettoyage
```

---

## Test 3 : les garde-fous

| Test | Commande | Attendu |
|---|---|---|
| **Plafond** | `docker service scale cloud_back=8` | Au relevé suivant, l'autoscaler ramène le back à **6** (`hors des bornes 2-6` dans son log) |
| **Plancher** | `docker service scale cloud_back=1` | Ramené à **2** |
| **Budget machine (80 %)** | `docker service update --env-add AUTOSCALE_HOST_BUDGET_PCT=30 cloud_autoscaler`, puis le test 2 | Montées **refusées** et journalisées (« la stack dépasserait 30 % de la machine »). Remettre ensuite `AUTOSCALE_HOST_BUDGET_PCT=80` |
| **Auto-réparation** | `docker kill <id d'une instance du back>` (voir `docker ps`) | Swarm recrée l'instance en ~13 s |
| **Arrêt propre de l'autoscaler** | `docker service update --force cloud_autoscaler` | L'ancienne tâche sort avec le code `0` (« arrêt propre » dans son log) |

Le budget est calculé sur la somme des **limites** de toutes les instances (outil `bench` compris, 1 CPU). Sur une petite machine (4 CPU, plafond à 3,2 CPU), il peut refuser une montée dès le test 2 : c'est le comportement attendu, et le log en donne la raison.

---

## Sécurité pendant les tests

- Surveiller `docker stats` pendant les charges.
- **Arrêt d'urgence** si la machine sature : `docker swarm leave --force` (arrête toutes les instances ; les fichiers stockés sont conservés). Plus doux : `docker service rm bench` puis `docker stack rm cloud`.
- Après un test interrompu : `docker service rm bench` (l'outil ne doit pas continuer à charger la stack).

## Pour aller plus loin

- Comment les limites CPU et mémoire ont été choisies : [benchmark.md](benchmark.md).
- Seuils de l'autoscaler, mesures complètes, limites constatées : [scalabilite.md](scalabilite.md#autoscaling--le-nombre-dinstances-suit-la-charge).
- Fonctionnement de l'image autoscaler (socket Docker, SIGTERM) : [conteneurs/autoscaler.md](conteneurs/autoscaler.md).
