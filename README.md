# M2 TP Docker - Docker Cloud

Mise en place d'une architecture virtualisée basée sur Docker : images personnalisées (front, back, serveur web) orchestrées avec Docker Compose.

Aucune image applicative n'est récupérée telle quelle depuis Docker Hub : chaque image part d'un OS minimal (`alpine`) et tout le reste est installé et configuré par nos soins.

## Structure du projet

```
.
├── Frontend/
│   ├── Dockerfile
│   ├── server.js        # serveur HTTP Node (côté serveur, non servi au navigateur)
│   └── src/
│       ├── index.html   # page affichée
│       └── app.js       # JS client (appellera le proxy plus tard)
└── README.md
```

---

## Image Frontend

Sert une page HTML unique. Le JavaScript client interrogera plus tard le proxy pour récupérer la phrase à afficher depuis le back.

### Image de base

| Choix | Justification |
|---|---|
| `alpine:3.20` | OS minimal (~8 Mo) : surface d'attaque réduite et image légère. On n'utilise pas l'image officielle `node` : Node est installé nous-mêmes. |
| Version fixée (`3.20`) plutôt que `latest` | Build reproductible : la même version d'OS et de Node à chaque build, pas de changement surprise. |

### Dépendances installées

Installées via `apk add --no-cache` (`--no-cache` : on ne conserve pas l'index des paquets dans l'image, ce qui l'allège).

| Dépendance | Rôle | Pourquoi ce choix |
|---|---|---|
| `nodejs` | Exécute `server.js`, le serveur HTTP qui distribue la page | Seul le runtime est installé, sans `npm` : le serveur utilise uniquement le module natif `http`, donc aucune librairie externe n'est nécessaire. |
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
| `80` | Port HTTP du serveur front (valeur par défaut de `PORT`). |

`EXPOSE` documente les ports : leur publication réelle se fait au run (`-p` ou `ports:` dans le compose).

### Arguments attendus au run

Variables d'environnement surchargeables avec `-e` ou `environment:` dans le compose :

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `80` | Port d'écoute du serveur HTTP. |
| `NODE_MAX_MEMORY` | `128` | Mémoire max du tas Node en Mo (`--max-old-space-size`). À aligner sur la limite mémoire du conteneur pour que Node libère la mémoire avant d'être tué par Docker. |
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
docker run -d --name front -p 8080:80 -e NODE_MAX_MEMORY=128 --memory=192m --cpus=0.5 front
```
