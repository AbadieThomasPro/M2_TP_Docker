# AGENTS.md

Instructions pour les agents IA (Claude Code ou autres) qui travaillent sur ce dépôt.

## Projet

TP noté du cours **M2 Dev Docker** : « Docker Cloud ». Sujet choisi : **mini cloud de stockage de fichiers** (envoyer, lister, télécharger, supprimer).

C'est un **cours Docker, pas un cours web**. Le code applicatif reste minimal (Hello World aujourd'hui, Angular + Express simples plus tard). La note porte sur les images, l'orchestration et leur documentation.

- Dépôt : https://github.com/AbadieThomasPro/M2_TP_Docker. Le prof regarde le **dernier commit avant la date butoir**.
- Langue : **français** pour la documentation, les commentaires et les messages de commit.

## Architecture

```
Navigateur ──:8080──▶ front ──http://gateway/api──▶ gateway (nginx) ──▶ back:3000 ──▶ volume "stockage" (/data)
           (seul port publié)  réseau "interne-front"            réseau "interne-back"
                               (internal: true)                  (internal: true)
```

Le front ne peut **pas** joindre le back en direct : la gateway est le seul pont entre les deux réseaux internes.

| Dossier | Image | Rôle |
|---|---|---|
| `Frontend/` | multi-stage : `build` (alpine + nodejs + npm, `ng build`) puis alpine + nodejs + tini | Sert l'application Angular compilée (`public/`, depuis `app/`) et relaie `/api/*` vers la gateway (`server.js`, Node natif). **Seul service publié.** |
| `Gateway/` | alpine + nginx + gettext-envsubst | Passerelle d'API : seul chemin vers le back, n'accepte que `/api/` et `/health`. Config générée au run (`nginx.conf.template` + `entrypoint.sh`). |
| `Backend/` | multi-stage : `deps` (alpine + nodejs + npm, `npm ci`) puis alpine + nodejs + tini | API Express + multer : `GET/POST /api/files` (champ `ttl`), `GET/DELETE /api/files/:name` (`410` si expiré), `GET /health`. Fichiers dans `STORAGE_DIR` (volume), nommés `<expiration epoch s>-<aléatoire>__<nom>` ; envois en cours dans `.incoming/` puis renommage atomique. Groupe `stockage` (GID = ARG `STORAGE_GID`) partagé avec le futur cleaner. |
| `docker-stack.yml` + `swarm-deploy.ps1/.sh` | – | Déploiement Swarm : 3 back, 1 cleaner (réseau `isole`), réservations, plafond, mises à jour progressives. |
| `docker-compose.yml` | – | Orchestration : réseaux `public` / `interne-front` / `interne-back`, volume `stockage`, ressources, healthchecks, ordre back → gateway → front. |
| `Cleaner/` | alpine **sans paquet** (BusyBox) | Worker : supprime les fichiers expirés (expiration lue dans le nom) et les `.part` abandonnés. `network_mode: none`, `read_only` + `tmpfs /tmp`, volume partagé avec le back via le groupe `stockage`. Script PID 1 : SIGTERM arrête le groupe de suppression (`setsid`) puis sort en `0`. |
| `Bench/` | alpine + apache2-utils (`ab`) | Outil de charge, profil compose `bench` (ne démarre pas avec `up`). `run-bench.ps1` mesure les pics CPU / mémoire. |
| `.env` | – | Source unique des valeurs (versions, ports, CPU, mémoire, limites). Versionné : aucun secret. |
| `questui-DESIGN.md` | – | Design system de l'interface (voir « Interface (design) »). |

## Commandes

```bash
docker compose up -d --build --wait   # build + démarrage, attend que tout soit healthy
docker compose ps                     # état / santé / ports
docker compose logs -f <service>
docker compose down                   # arrêt propre ; -v supprime aussi les volumes
docker compose run --rm gateway nginx -t -c /tmp/nginx.conf   # tester la config nginx générée
powershell -ExecutionPolicy Bypass -File Bench/run-bench.ps1    # benchmark (stack démarrée)
docker compose --profile bench run --rm bench -n 5000 -c 50 http://front/api/files    # un scénario ab
```

Application : http://127.0.0.1:8080. Sur le poste de dev, `localhost:8080` peut être intercepté par `wslrelay` (WSL) : utiliser `127.0.0.1`.

## Contraintes du sujet (non négociables)

- **Aucune image toute faite de Docker Hub** : toutes les images partent de `alpine:${ALPINE_VERSION}` et installent elles-mêmes leurs outils (pas d'image `node`, `nginx`, `registry`...).
- Au moins 3 types d'images : front, back, « serveur web » (la gateway nginx).
- Chaque conteneur reçoit des **arguments au run** pour régler ses ressources.

**Barème** (une ligne de README doit couvrir chaque point) : mise en forme, dépendances installées, manipulations sur l'OS, arguments attendus, entrypoints, arguments traduits dans le compose, limites de ressources expliquées, gestion de SIGTERM, dépendances entre conteneurs, schéma des communications.

## Règles de travail

### Commentaires
- Dans les Dockerfile, le compose, le `.env`, la config nginx et les scripts : **les commentaires justifient** le choix (pourquoi, alternative écartée, contrainte). Ils ne **définissent pas** l'instruction.
  - ❌ `# Dossier de l'application`
  - ✅ `# Chemin fixe pour que les COPY et la CMD ne dépendent pas du répertoire courant`
- Commentaires courts, en français.

### Bonnes pratiques Docker (cours 1)
- Base `alpine` avec une **version fixée** (ARG `ALPINE_VERSION`, actuellement **3.22** : Node 22 requis par Angular 22, 3.20 en fin de support), jamais `latest`.
- `.dockerignore` : motifs en `**/` (un motif simple ne vise que la racine du contexte).
- `apk add --no-cache`, chaque paquet justifié. Pas de `npm` dans une image finale (multi-stage si un build est nécessaire).
- **Utilisateur non-root** (`USER`), fichiers du code laissés à root (lecture seule). **UID explicites** (`adduser -u`) dès que deux images partagent un volume : sinon chacune donne 1000 à son premier utilisateur, et le noyau les confond (back = 1001, cleaner = 1002, groupe `stockage` = `STORAGE_GID`).
- Ordre des couches : OS, paquets, utilisateur, ARG/ENV en haut ; `COPY` du code **en dernier**.
- `CMD` / `ENTRYPOINT` en **forme exec**. Images Node : `ENTRYPOINT ["/sbin/tini", "--"]` + `CMD ["node", ...]`, mémoire via `NODE_OPTIONS`. Scripts d'init : terminer par `exec "$@"`.
- Arrêt propre : l'application gère SIGTERM (nginx : `STOPSIGNAL SIGQUIT`). Objectif : `docker stop` en moins d'1 s.
- `HEALTHCHECK` sur chaque image (`127.0.0.1` pour nginx, qui n'écoute qu'en IPv4). Le compose utilise `depends_on: condition: service_healthy`.
- `.dockerignore` et `LABEL org.opencontainers.image.*` sur chaque image.
- **`read_only: true` sur tous les services.** Un service qui écrit reçoit le volume ou un `tmpfs` **limité en taille** (compté dans sa mémoire). nginx ne doit rien bufferiser sur disque (`proxy_request_buffering off`, `proxy_max_temp_file_size 0`).
- `EXPOSE` documente, seul `ports:` publie. Seul le front publie un port.

### Ressources
- Chaque service a `deploy.resources.limits` (cpus, memory), `reservations.memory` et **`memswap_limit` égal à la limite mémoire** : sans ça, Docker double la limite en swap (mesuré) et le service ralentit au lieu d'être arrêté.
- Les valeurs du `.env` sont **justifiées par le benchmark** (`Bench/run-bench.ps1`, section Benchmark du README) : CPU proportionnel au coût par requête de chaque service, mémoire selon le pic mesuré. nginx consomme bien moins que Node (environ 4 Mo contre 20 à 25 Mo) : ne pas lui donner autant.
- Tas Node (`*_NODE_MAX_MEMORY`) à la moitié de la limite mémoire du conteneur. Réservation minimale imposée par Docker : 6 Mo.
- Toute modification des services ou des limites : relancer le benchmark et mettre à jour les tableaux du README.

### ARG / ENV / .env
- **ARG** = build uniquement (`ALPINE_VERSION`, `PORT` → `EXPOSE` + défaut de `ENV PORT`).
- **ENV** = valeurs par défaut dans l'image : l'image doit fonctionner seule, sans compose.
- **`.env`** = valeurs du déploiement, injectées par le compose (`build.args` pour les ARG, `environment:` pour les ENV, `deploy.resources` / `ports`). Aucune valeur en dur dans le compose, sauf les noms de service (`back`, `gateway`).
- Toute nouvelle variable : défaut en ENV + entrée commentée dans `.env` + passage dans le compose + ligne dans le README.

### Interface (design)
- L'interface du front suit le design system **[questui-DESIGN.md](questui-DESIGN.md)** (« QuestUI », thème RPG médiéval) : couleurs, typographie (Cinzel / Spectral / Fira Code), espacements, rayons, ombres dorées, composants (boutons, cartes, inputs, listes, chips) et leurs règles « Do / Don't ».
- Valeurs définies **une seule fois** en variables CSS (`:root { --color-primary: #CA8A04; ... }`) dans le style global, puis réutilisées : aucune couleur ni taille en dur dans les composants.
- Rester simple (cours Docker, pas web) : CSS natif, sans librairie UI (pas de Material ni de Tailwind). Seuls les composants utiles à l'appli sont implémentés : bouton primaire / destructif, carte, input fichier, liste de fichiers, chip de statut.
- Points clés du système : fond `#1A0F0A` (jamais de noir pur), texte parchemin `#F5E6D3` (jamais de blanc pur), titres et libellés en Cinzel, corps en Spectral (pas de sans-serif), lueur dorée sur les éléments actifs, animations sobres (300 ms).
- Polices chargées depuis Google Fonts par le navigateur : aucune dépendance ajoutée dans les images Docker.

### Documentation
- **Ordre des parties du README** (à respecter pour tout ajout) : Sujet → Sommaire → Démarrage rapide → Architecture → Structure → Configuration (ARG / ENV / `.env`) → Les images : points communs → Image Frontend → Gateway → Backend → Cleaner → Orchestration → Benchmark → Scalabilité → Tests et vérifications. Les sections d'image gardent le même plan. Toute nouvelle partie de niveau 2 est ajoutée au sommaire ; les liens internes sont vérifiés (aucune ancre cassée).
- Chaque changement d'image ou du compose met à jour le **README.md** (tableaux ARG / ENV, dépendances, manipulations OS, entrypoints, ressources).
- Toute modification d'architecture (service, réseau, port, volume, `depends_on`, ressources) met à jour les **schémas Mermaid** du README (architecture, séquence, ordre de démarrage) et régénère `docs/architecture.png`. Vérifier le rendu avant de livrer (une erreur de syntaxe Mermaid casse l'affichage sur GitHub).
- Les résultats de test (temps d'arrêt, mesures `docker stats`, codes HTTP) sont notés dans le README quand ils justifient un choix.

### Git
- **L'agent ne commite pas et ne pousse pas.** À la fin de chaque lot, il propose un message de commit (style conventionnel, corps en français) ; l'utilisateur commite lui-même. Les commandes git en lecture (status, diff, log) sont autorisées.
- `main` = version **Hello World** toujours fonctionnelle (`docker compose up --build`), testable par le prof.
- L'application (plan 02) se développe sur la branche **`feature/app-cloud-stockage`**, à fusionner dans `main` avant la date de rendu (tag `hello-world` posé avant).

### Tests avant de rendre un lot
- `docker compose up -d --build --wait` : les 3 services sont `healthy`.
- `curl.exe -s -m 10 http://127.0.0.1:8080/api/files` répond (toujours un délai max `-m` : une requête bloquée ne doit pas bloquer le test).
- Arrêt de chaque service en moins d'1 s.
- **Code de sortie à l'arrêt = `0`** pour chaque conteneur (`docker compose stop`, puis `docker inspect -f '{{.State.ExitCode}}' <conteneur>`) :
  - `0` ✅ : le signal a été reçu et traité, arrêt propre ;
  - `1` ❌ : l'application s'est arrêtée sur une erreur ;
  - `137` ❌ (128 + 9 = SIGKILL) : le signal d'arrêt a été ignoré, Docker a tué le conteneur au bout des 10 s.
- Nettoyage : `docker compose down` + suppression des images de test.

## Fichiers hors dépôt

| Emplacement | Contenu |
|---|---|
| `../features/01-seance-2-docker.md` | Plan Docker de la séance 2, découpé en lots (sur `main`) |
| `../features/02-app-cloud-stockage.md` | Plan de l'application, découpé en lots (sur la branche dédiée) |
| `../features/Compte rendu/` | Comptes rendus de séance (`compte-rendu-seance-N.md`) |
| `../../Cours-1-Docker.html`, `../../Note_Docker.txt` | Cours de référence pour vérifier les bonnes pratiques |
| `../Activité 2 séances.pdf`, `TP - Docker Cloud (1).pdf` | Consignes de la séance et sujet du TP |

## Swarm

- `docker-compose.yml` reste le fichier principal ; `docker-stack.yml` est un fichier **autonome** pour Swarm (une surcharge est refusée par `docker stack deploy` : `depends_on` en forme longue et `memswap_limit` interdits). Seule la structure est répétée, **toutes les valeurs viennent du `.env`**.
- Déploiement : `docker swarm init` (une fois), puis `swarm-deploy.ps1` / `swarm-deploy.sh` (construit les images, **charge le `.env`**, que `docker stack deploy` ne lit pas, puis déploie). Retrait : `docker stack rm cloud`.
- **Toute modification d'un service (variable, ressource, réseau, volume) se fait dans les deux fichiers** et se vérifie dans les deux modes. La stack Swarm et le compose publient tous deux le port 8080 : jamais les deux en même temps.
- En Swarm, front et gateway ont plus de CPU (`SWARM_FRONT_CPUS`, `SWARM_GATEWAY_CPUS`) : ils relaient 3 back (rapport de coûts mesuré 7 / 3 / 1). Réservations CPU et plafond `BACK_MAX_REPLICAS_PER_NODE` = garde-fous contre une multiplication des instances.
- Un seul `cleaner`, toujours. L'image du cleaner initialise aussi le dossier du volume (pas d'ordre de démarrage en Swarm).
- Bench en Swarm : `ab` lancé comme service ponctuel sur `cloud_public` (pas via `host.docker.internal`, non comparable et instable sous forte charge).

### Arrêt d'urgence

Si la stack Swarm commence à trop consommer de RAM ou de CPU (machine qui rame, ventilateurs à fond, `docker stats` qui s'emballe), **arrêter immédiatement** :

```bash
docker swarm leave --force   # quitte le mode Swarm : tous les services et toutes les instances sont arrêtés
```

- C'est le plus radical : tous les services Swarm disparaissent d'un coup. Les **volumes sont conservés** (les fichiers stockés ne sont pas perdus). Réactiver ensuite avec `docker swarm init`.
- Plus doux, si la machine répond encore : `docker stack rm cloud` (retire la stack, garde le mode Swarm) ou `docker service scale cloud_back=1`.
- Pendant les démonstrations de montée en charge, surveiller `docker stats` et garder la main sur ces commandes. Ne jamais dépasser les plafonds du `.env` (`BACK_MAX_REPLICAS_PER_NODE`).

## Pièges connus (poste Windows)
- PowerShell 5.1 lit les scripts `.ps1` en ANSI : éviter les remplacements de texte accentué par script. Pour modifier des fichiers, utiliser l'outil d'édition, ou Node.
- En PowerShell, `@(@("a","b"))` est aplati en `@("a","b")` : attention aux tableaux de paires.
- `sed` et `git` ne sont pas disponibles dans le Bash de l'agent : utiliser PowerShell pour git.
- **Disque C: plein** sur le poste : npm échoue (`ENOSPC`) car son cache et ses fichiers temporaires sont sur C:. Lancer npm via `cmd` avec le cache et `TEMP` sur D: : `cmd /c "set TEMP=D:\DOCUMENT\COURS\M2\Dev Docker\TP\.npm-cache\tmp&& set TMP=...&& cd Frontend\app && npm install --cache D:\DOCUMENT\COURS\M2\Dev Docker\TP\.npm-cache"`.
- Application Angular : `Frontend/app/` (Angular 22). Dev : `npx ng serve` (proxy `/api` → `127.0.0.1:8080`, la stack doit tourner).
- Les `.sh` doivent rester en fins de ligne LF (`.gitattributes`), sinon ils ne s'exécutent pas dans le conteneur.
