# Configuration : ARG, ENV et .env

[← Retour au README](../README.md) · [Documentation](README.md)

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

## ARG communs aux 3 images

| ARG | Défaut | Utilisation |
|---|---|---|
| `ALPINE_VERSION` | `3.22` | Déclaré **avant** `FROM` pour être utilisable dans `FROM alpine:${ALPINE_VERSION}`. On change la version de l'OS de toutes les images depuis le `.env`, sans toucher aux Dockerfile. |
| `PORT` | `80` (front, gateway) / `3000` (back) | Sert à `EXPOSE ${PORT}` et de valeur par défaut à `ENV PORT=${PORT}`. Le port documenté par l'image et le port d'écoute restent ainsi cohérents. |

## Pourquoi un `.env` ?
- **Une seule source de vérité** : les ports, la mémoire, les CPU et les durées de vie sont regroupés dans un seul fichier. Le `docker-compose.yml` ne contient plus de valeurs en dur.
- **Cohérence entre services** : `BACK_PORT` est utilisé à la fois par le back (port d'écoute) et par la gateway (port à joindre). Une seule modification met les deux à jour.
- **Surcharge simple** : une variable d'environnement du shell est prioritaire sur le `.env`. Par exemple, `TTL_DEFAULT_H=1 docker compose up -d` change la durée de vie par défaut sans modifier de fichier ni reconstruire l'image. C'est le mécanisme utilisé dans nos tests (par exemple `CLEANUP_INTERVAL_S=10` pour accélérer les passes du worker).
- Le `.env` est **versionné volontairement** : il ne contient aucun secret, seulement de la configuration.
