# CI/CD avec Docker

[← Retour au README](../README.md) · [Documentation](README.md)

Chaque modification passe par un **pipeline** qui vérifie le projet puis le déploie. Comme dans l'exemple du cours, **chaque étape est un conteneur** : elle réussit si son conteneur sort avec le code `0`. Au premier échec, le pipeline s'arrête : **rien n'est déployé**, et la version en service reste en place.

```bash
./ci/pipeline.sh                     # Windows : powershell -ExecutionPolicy Bypass -File ci/pipeline.ps1
./ci/pipeline.sh --sans-deploiement  # CI seule (Windows : -SansDeploiement)
```

## Le pipeline

```mermaid
flowchart LR
  code[["dépôt<br/>(monté en lecture seule)"]]
  build["<b>0 · build</b><br/>images de l'application<br/>et de la CI"]
  lint["<b>1 · lint</b><br/>shellcheck, node --check,<br/>règles des Dockerfile"]
  test["<b>1 · test</b><br/>11 tests de l'API"]
  sec["<b>2 · security</b><br/>npm audit"]
  pol["<b>2 · policy</b><br/>règles des images construites"]
  it["<b>3 · intégration</b><br/>vraie stack isolée,<br/>5 tests de bout en bout"]
  dep["<b>4 · déploiement</b><br/>Swarm, mise à jour<br/>progressive"]
  rep[("rapports<br/>ci/reports/")]

  code --> build
  build --> lint
  build --> test
  lint -- "code 0" --> sec
  test -- "code 0" --> sec
  lint -- "code 0" --> pol
  test -- "code 0" --> pol
  sec -- "code 0" --> it
  pol -- "code 0" --> it
  it -- "code 0" --> dep
  lint -.-> rep
  test -.-> rep
  sec -.-> rep
  pol -.-> rep
  it -.-> rep

  classDef ci fill:#efe8fd,stroke:#7a4fd6,color:#1b2330
  classDef cd fill:#e3f6ec,stroke:#1f9d63,color:#1b2330
  classDef src fill:#e6efff,stroke:#1d63ed,color:#1b2330
  class build,lint,test,sec,pol,it ci
  class dep cd
  class code,rep src
```

**Légende :**
- **Violet :** étapes de vérification (CI), chacune dans son conteneur.
- **Vert :** déploiement (CD).
- **Flèche pleine « code 0 » :** l'étape suivante ne démarre que si la précédente a réussi.
- **Deux flèches vers une même étape :** elle attend que **toutes** soient vertes (« fan-in »). `lint` et `test` tournent en parallèle, comme `security` et `policy`.
- **Pointillés :** rapports écrits dans un volume partagé, puis copiés dans `ci/reports/`.

## Les étapes

| Étape | Image (alpine) | Ce qu'elle vérifie | Réseau | Rapport |
|---|---|---|---|---|
| **build** | – | Les images de l'application (`docker compose build` + autoscaler) et celles de la CI se construisent ; `docker compose config` valide les fichiers compose | – | – |
| **lint** | `shellcheck` + `node` | Tous les scripts `.sh` (niveau warning), syntaxe de tout le JavaScript, et **règles du projet sur chaque Dockerfile** : base `alpine:${ALPINE_VERSION}`, `ARG` de version, `USER` non-root, forme exec, `apk add --no-cache`, et pour les images de l'application `HEALTHCHECK` + `LABEL` OCI | aucun | `lint.txt` |
| **test** | `node` + dépendances du back | Les 11 tests de l'API (`node:test`, aucune dépendance ajoutée) : cycle complet, refus 400 / 413 / 507, expiration 410, chemins piégés, en-tête de téléchargement, **SIGTERM → code 0** | aucun (boucle locale) | `junit-unit.xml` |
| **security** | `npm` | `npm audit` des dépendances **livrées** du back et du front ; échec à partir du niveau `high` (`CI_AUDIT_LEVEL`) | registre npm | `audit-*.json` |
| **policy** | `docker-cli` + socket | Les **images construites** (pas seulement leurs Dockerfile) : non-root, healthcheck présent, pas de `npm` dans le front et le back | aucun | `policy.txt` |
| **intégration** | image `test` | La vraie stack démarrée à part (projet `docker-cloud-it`, aucun port publié) : page servie, cycle complet par le front, 413 de la gateway, isolation réseau, suppression par le cleaner ; puis **arrêt avec le code 0** pour chaque service | réseau `public` seul | `junit-integration.xml` |
| **déploiement** | – | `ci/deploy.sh` : images retaguées avec le hash git, `docker stack deploy`, attente bornée de la mise à jour progressive ; un retour arrière de Swarm est un échec | – | – |

Pas de hadolint : il n'existe pas en paquet Alpine, et le sujet interdit les images toutes faites. Les règles des Dockerfile sont donc vérifiées par notre propre script (`ci/lint/lint.sh`, en `awk`).

Pas de tests Angular : c'est un cours Docker, pas un cours web. La compilation de l'application est vérifiée par le build de l'image du front.

## Les règles appliquées aux conteneurs de CI

Les mêmes que pour l'application :

| Règle | Pourquoi |
|---|---|
| Base `alpine:${ALPINE_VERSION}`, une image par étape | Aucune image du Hub ; outils isolés, versions figées par celle d'Alpine : même résultat sur toutes les machines |
| Code monté en **lecture seule** (`..:/workspace:ro`) | Une étape ne peut pas modifier ce qu'elle vérifie ; caches et fichiers temporaires dans `/tmp` |
| `read_only: true` + `tmpfs /tmp` limité | Même durcissement que les services |
| Utilisateur non-root (`ci`, UID 2001) | `policy` rejoint en plus le groupe du socket Docker, comme l'autoscaler |
| `network_mode: none` pour lint, test et policy | Elles ne lisent que des fichiers locaux (ou le socket) ; seule `security` a besoin du registre npm |
| Limites : 1 CPU, 256 Mo par étape | Pics mesurés : lint 19 Mo, test 68 Mo, security 38 Mo, policy 9 Mo |
| `restart: "no"` | Une étape s'exécute une fois ; ce n'est pas un service |
| Volume de rapports en `1777` | Chaque étape, avec son propre utilisateur, peut y écrire |
| Projets séparés (`docker-cloud-ci`, `docker-cloud-it`) | La CI ne touche jamais la stack de l'utilisateur, son volume ni le port 8080 ; tout est supprimé à la fin, **même en cas d'échec** |

## Le déploiement continu (Swarm)

| Réglage | Rôle |
|---|---|
| `image: docker-cloud/<service>:${IMAGE_TAG:-latest}` | Version déployée = hash git court du commit testé (`-modifie` si des changements ne sont pas commités). Un tag qui change force la mise à jour, et la version en service se lit dans `docker service ls` |
| Images retaguées, pas reconstruites | On déploie exactement ce qui a été testé |
| `update_config: order: start-first` (back, gateway, front) | La nouvelle instance doit être healthy avant l'arrêt de l'ancienne : aucune coupure |
| `order: stop-first` (cleaner, autoscaler) | Jamais deux instances à la fois |
| `monitor: 30s` + `failure_action: rollback` | Swarm surveille chaque nouvelle instance 30 s (le temps qu'un healthcheck échoue) ; une version qui tombe est **annulée automatiquement** |

## Les exercices de l'exemple du cours

| Exercice / piste du README du prof | Ce qu'on a fait | Résultat mesuré |
|---|---|---|
| 1. Casser le lint | Script avec un `cd` sans repli | Lint en échec (SC2164), pipeline arrêté en 17 s, code 1, **version en service inchangée** |
| 2. Casser un test | Règle d'expiration désactivée dans le back | 10 tests sur 11, pipeline arrêté, rien de déployé, version en service inchangée |
| 3. Relancer une seule étape | `docker compose -f ci/compose.yml --env-file .env run --rm <étape>` | Utilisé pendant toute la mise au point |
| 4. Ajouter une étape de sécurité | `security` (npm audit) **et** `policy` (règles des images) | Image de la gateway passée en root : rejetée par `policy` (code 1) |
| 5. Étapes en parallèle, puis fan-in | `lint` ∥ `test`, puis `security` ∥ `policy` | Lint cassé : `security` et `policy` restent « Created », jamais démarrées |
| Bonus : déploiement Swarm progressif | `ci/deploy.*` + `update_config` | **86 332 requêtes, 0 échec** pendant la mise à jour ; version cassée annulée en **21 s** |

Différence importante avec l'exemple : ses images de CI partent de `python:3.12-alpine` ; les nôtres partent toutes d'`alpine`, comme le reste du projet.

## Résultats mesurés

| Mesure | Résultat |
|---|---|
| Pipeline complet (tout vert) | **153 s** : build 10 s, lint ∥ test puis security ∥ policy 11 s, intégration 47 s, déploiement 84 s |
| Mise à jour progressive sous charge | 85 s, 86 332 requêtes, **0 échec** |
| Version cassée (healthcheck toujours en échec) | Retour arrière automatique en **21 s**, API en `200` tout du long |
| Arrêt de la stack de test | 1,5 s, **code 0** pour les 4 services |
| Nettoyage | 0 conteneur, volume ou réseau de CI restant après chaque exécution (réussie ou non) |

## Ce que la CI a trouvé dans le projet

Mise en place sur un projet déjà testé à la main, elle a pourtant trouvé de vrais défauts, tous corrigés :

| Étape | Défaut | Correction |
|---|---|---|
| security | 2 failles `high` (déni de service) : `multer` 2.4.0, `body-parser` 2.3.0 | Dépendances mises à jour dans le `package-lock.json` (multer 2.5.0, body-parser 2.4.0) |
| intégration | **Le téléchargement d'un fichier au nom accentué faisait planter tout le front** : accent en octet brut dans `Content-Disposition`, en-tête refusé par le relais Node, exception non rattrapée | Back : en-tête ASCII (RFC 6266, nom exact dans `filename*`). Front : un en-tête non relayable donne un `502` pour cette seule requête |
| lint | `cd` sans repli dans un script ; découpage de mots voulu mais non documenté | Corrigé ; directive shellcheck justifiée |
| déploiement | `.env` extrait en CRLF sous Windows : valeurs terminées par `\r` dans les scripts `.sh` | `tr -d '\r'` au chargement (`deploy.sh`, `swarm-deploy.sh`) |

## Limites connues

- **Retour arrière par service** : Swarm annule la mise à jour du service qui échoue, pas celle des autres. Ici les autres images étaient identiques, donc sans effet.
- **Le tag `latest` est celui du dernier build, validé ou non** : le build précède les tests. La version **en service** est toujours un tag de version validé.
- **Git Bash sous Windows** convertit les valeurs qui ressemblent à des chemins avant d'appeler Docker : utiliser les `.ps1` sous Windows. `deploy.sh` a été validé sous Linux (dans un conteneur alpine + docker-cli).
- `pipeline.sh` a été vérifié par shellcheck et suit pas à pas `pipeline.ps1`, exécuté de bout en bout ; son exécution complète sous Linux est prévue avec GitHub Actions (version suivante).
