# Image Frontend

[← Retour au README](../../README.md) · [Documentation](../README.md)

**Point d'entrée** de l'architecture. L'image contient l'application **Angular compilée** (voir [L'interface](../sujet.md#linterface)) et un petit serveur Node, `server.js`, qui a deux rôles :

| Requête reçue | Traitement |
|---|---|
| `/api/...` | Relayée vers `http://${GATEWAY_HOST}:${GATEWAY_PORT}` (la gateway), puis la réponse est renvoyée au navigateur |
| Un fichier du build (`/`, `/main-XXXX.js`, `/styles-XXXX.css`, `/favicon.ico`...) | Servi depuis `public/` avec son type MIME |
| Un chemin sans extension inconnu (`/une/route`) | `index.html` : c'est l'application qui gère ses écrans |
| Une ressource absente (`/absent.js`) ou un chemin qui sort de `public/` (`/..%2Fserver.js`) | `404` |
| Autre méthode que `GET` / `HEAD` | `405` |

Le relais est nécessaire car le navigateur ne peut pas résoudre le nom de service Docker `gateway` : seul un conteneur du réseau interne le peut. Le navigateur appelle donc `/api/files` sur le front (même origine, pas de CORS), et c'est le front qui contacte la gateway. Si la gateway est injoignable, le front répond `502`.

**Pourquoi servir tout `public/` et non une liste de fichiers ?** Angular produit des noms avec **empreinte** (`main-AICTWSOV.js`), qui changent à chaque build : une liste blanche écrite à la main serait fausse au build suivant. Le serveur sert donc tout le dossier `public/`, en vérifiant que le chemin demandé, une fois décodé et normalisé, reste **dans** ce dossier (testé : `..%2Fserver.js` → `404`). `server.js` est rangé à côté de `public/`, jamais dedans : il ne peut pas être téléchargé.

**Cache :** les fichiers à empreinte sont envoyés avec `Cache-Control: max-age=31536000, immutable` (leur contenu ne changera jamais sous ce nom), et `index.html` avec `no-cache` (il doit toujours être revérifié pour pointer vers les bons fichiers après un nouveau build).

Le relais transmet le corps des requêtes en flux, ce qui convient aux uploads. Si la gateway répond avant la fin de l'envoi (par exemple `413` pour un fichier trop gros), le front lit le reste du corps sans le transmettre : sans ça, le client restait bloqué à attendre de finir son envoi (bug trouvé et corrigé en testant la limite d'upload).

## Image de base : build multi-stage

```
Stage "build" : alpine + nodejs + npm ──▶ npm ci ──▶ ng build ──▶ dist/cloud-front/browser
                                                                        │ COPY --from=build
Stage final   : alpine + nodejs + tini + tzdata + server.js ◀───────────┘   (ni npm, ni node_modules, ni sources)
```

| Choix | Justification |
|---|---|
| `alpine:3.22` | OS minimal (~8 Mo) : surface d'attaque réduite et image légère. On n'utilise pas l'image officielle `node` : Node est installé nous-mêmes. |
| **3.22** plutôt que 3.20 | Angular 22 exige Node **≥ 22.22**, et Alpine 3.20 ne fournit que Node 20.15 : impossible de compiler l'application. De plus, Alpine 3.20 et Node 20 sont **en fin de support** depuis avril 2026. Alpine 3.22 fournit Node 22 (LTS, maintenu) et est supporté jusqu'en 2027. Changement fait en une ligne, `ALPINE_VERSION` dans le `.env`, pour **toutes** les images. |
| Version fixée plutôt que `latest` | Build reproductible : la même version d'OS et de Node à chaque build, pas de changement surprise. |
| **Multi-stage** | Compiler Angular demande npm, la CLI Angular, TypeScript et ~300 Mo de dépendances, qui n'ont rien à faire dans l'image livrée : on ne sert que le résultat (HTML, JS, CSS). Le stage `build` est jeté à la fin. |
| `COPY package.json package-lock.json` **avant** les sources | La couche `npm ci` (la plus longue) reste en cache tant que les dépendances ne changent pas. Vérifié : après la modification d'un composant, `npm ci` est `CACHED`, seul `ng build` est relancé. |
| `npm ci` (avec les dépendances de dev) | Versions exactes du `package-lock.json`. Les dépendances de dev (CLI, compilateur) sont nécessaires pour compiler : c'est le stage jetable qui les porte. |
| `NG_CLI_ANALYTICS=false` (stage build) | Évite que la CLI Angular pose sa question sur la télémétrie pendant un build automatique. |
| Ordre des instructions | Ce qui change rarement en haut (OS, paquets, utilisateur, variables), le build de l'application en bas. |

**Tailles mesurées :**

| Image | Taille |
|---|---|
| Stage `build` (Node, npm, dépendances, sources) | 559 Mo |
| **Image finale du front** | **114 Mo** |

445 Mo ne partent jamais en production. Vérifié dans l'image finale : `npm absent`, `node_modules absent`, aucune source TypeScript ; `/app` ne contient que `server.js` et `public/` (`index.html`, `main-*.js`, `styles-*.css`, `favicon.ico`). Durée du build complet : 33 s (`npm ci` 14,5 s, `ng build` 5,5 s).

## Dépendances installées

| Où | Dépendance | Rôle | Pourquoi ce choix |
|---|---|---|---|
| Stage `build` (`apk`) | `nodejs`, `npm` | Installer les paquets et compiler Angular | Restent dans le stage jetable. |
| Stage `build` (npm) | Angular 22 (`@angular/core`, `common`, `compiler`, `platform-browser`, `build`, `cli`...), `rxjs`, `typescript` | Framework et outils de compilation | Projet allégé : sans `@angular/router` ni `@angular/forms` (une seule page, pas de formulaire complexe), sans outils de test. |
| Image finale (`apk`) | `nodejs` | Exécute `server.js`, qui sert le build et relaie `/api` | Seul le runtime est installé, sans `npm` : le serveur utilise uniquement les modules natifs `http`, `fs` et `path`, et l'application est déjà compilée. |
| `tini` | Init minimal lancé en PID 1 | Transmet correctement les signaux (SIGTERM lors d'un `docker stop`) à Node et nettoie les processus zombies. Sans lui, Node en PID 1 peut ignorer SIGTERM et le conteneur est tué brutalement après 10 s. |
| `tzdata` | Base des fuseaux horaires | Permet d'avoir l'heure de Paris (`TZ=Europe/Paris`) dans les logs au lieu de l'UTC. |

`wget`, utilisé par le healthcheck, est déjà fourni par BusyBox dans Alpine : rien à installer.

## Manipulations sur l'OS

| Instruction | Explication |
|---|---|
| `ENV TZ=Europe/Paris` | Fuseau horaire du conteneur (s'appuie sur `tzdata`). |
| `RUN adduser -D -H front` | Crée un utilisateur `front` sans mot de passe (`-D`) ni dossier personnel (`-H`). Le serveur tourne avec cet utilisateur et non en root : en cas de faille, l'attaquant n'a pas les droits root dans le conteneur. |
| `WORKDIR /app` | Dossier de travail de l'application. |
| `COPY server.js ./` | Le serveur, qui appartient à root : `front` peut le lire mais pas le modifier. |
| `COPY --from=build /build/dist/cloud-front/browser ./public/` | Récupère **seulement** le résultat du build Angular. `server.js` reste en dehors de `public/` pour ne jamais être servi au navigateur. Copié en dernier : c'est ce qui change le plus souvent. |
| `USER front` | Bascule sur l'utilisateur non-root pour l'exécution. |

## Ports exposés

| Port | Usage |
|---|---|
| `80` | Port HTTP du serveur front (valeur par défaut de `PORT`). C'est le seul port publié sur la machine hôte dans le compose (`8080:80`). |

`EXPOSE` documente les ports : leur publication réelle se fait au run (`-p` ou `ports:` dans le compose).

## Arguments de build (ARG)

| ARG | Défaut | Rôle |
|---|---|---|
| `ALPINE_VERSION` | `3.22` | Version de l'OS de base. |
| `PORT` | `80` | Port documenté (`EXPOSE`) et valeur par défaut de `ENV PORT`. |

## Arguments attendus au run (ENV)

Variables d'environnement surchargeables avec `-e` ou `environment:` dans le compose :

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `80` (vient de l'ARG) | Port d'écoute du serveur HTTP. |
| `NODE_OPTIONS` | `--max-old-space-size=64` | Mémoire max du tas Node (Mo). Variable lue par Node lui-même : pas besoin de shell dans la `CMD`. La moitié de la limite mémoire prévue (128 Mo), même valeur que le `.env` : Node libère la mémoire avant d'être tué par Docker. Dans le compose, elle vient de `FRONT_NODE_MAX_MEMORY`. |
| `GATEWAY_HOST` | `gateway` | Hôte vers lequel relayer `/api` : le nom du service gateway dans le compose. |
| `GATEWAY_PORT` | `80` | Port de la gateway. |
| `TZ` | `Europe/Paris` | Fuseau horaire. |

## Healthcheck

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/ || exit 1
```

Docker interroge la page toutes les 10 s. Le conteneur passe en `healthy` quand le serveur répond, ce qui permettra au compose d'ordonner le démarrage (`depends_on: condition: service_healthy`).

## Entrypoint et gestion de SIGTERM

```dockerfile
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
```

- **`ENTRYPOINT` = `tini`** : toujours exécuté en PID 1, il relaie les signaux à Node et nettoie les processus zombies. Node lancé seul en PID 1 ignore SIGTERM par défaut.
- **`CMD` en forme exec, sans shell** : Node est lancé directement par `tini` (vérifié avec `ps` : PID 1 = `tini`, son enfant direct = `node`). La limite mémoire passe par `NODE_OPTIONS`, que Node lit tout seul : plus besoin de `sh -c` pour remplacer une variable.
- **`CMD` séparée de l'`ENTRYPOINT`** : on peut la remplacer au run (`docker run front node -v`) tout en gardant `tini`.
- **Dans `server.js`** : à la réception de SIGTERM, le serveur arrête d'accepter les connexions, termine celles en cours puis quitte avec le code 0.

Résultat testé : un `docker stop` arrête le conteneur en moins d'une seconde, au lieu d'attendre le kill forcé à 10 s.

## Build et run

```bash
docker build -t front ./Frontend
docker run -d --name front -p 8080:80 -e NODE_OPTIONS=--max-old-space-size=64 -e GATEWAY_HOST=gateway --memory=128m --memory-swap=128m --cpus=0.25 front
```

Seul, le front sert la page, mais `/api/files` renvoie `502` tant qu'aucune gateway n'est joignable : voir la section Orchestration.
