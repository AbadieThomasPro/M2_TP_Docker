# Image Backend

[← Retour au README](../../README.md) · [Documentation](../README.md)

API du cloud de fichiers éphémères, en **Express + multer**. Elle lit et écrit les fichiers directement dans `STORAGE_DIR` (le volume `stockage`), sans base de données : la **date d'expiration est inscrite dans le nom** de chaque fichier stocké. Le front l'appelle en passant par la gateway.

## Routes

| Route | Réponse |
|---|---|
| `GET /api/files` | `200` : liste `[{ name, originalName, size, date, expiresAt }]` des fichiers **non expirés**, du plus récent au plus ancien |
| `POST /api/files` | Envoi d'un fichier (multipart : champ `file`, champ `ttl` optionnel en heures) : `201` `{ name, originalName, size, expiresAt }` ; `400` sans fichier ou `ttl` invalide ; `413` au-delà de `MAX_UPLOAD_MB` ; `507` si le quota de stockage est atteint |
| `GET /api/files/:name` | `200` : téléchargement sous le nom d'origine ; `410 Gone` si le fichier a expiré ; `404` si absent |
| `DELETE /api/files/:name` | `204` ; `404` si absent |
| `GET /health` | `OK` : utilisée par le healthcheck |
| Toute autre route | `404` avec `{"error": "Not found"}` |

Chaque réponse porte un en-tête **`X-Served-By`** avec le nom du conteneur qui a répondu : il servira à montrer la répartition de charge quand le back sera lancé en plusieurs instances.

## Choix de l'API

| Choix | Justification |
|---|---|
| Express + multer | Express route les requêtes en quelques lignes ; multer gère le format multipart des envois, pénible à décoder à la main. Ce sont les deux seules dépendances. |
| Stockage sur disque (`multer.diskStorage`) | Le fichier est écrit **en flux** dans le volume : un fichier de 50 Mo ne passe jamais entièrement en mémoire. Cela compte avec une limite de 128 Mo par conteneur. |
| Nom stocké = `<expiration en secondes epoch>-<aléatoire>__<nom d'origine>` | **L'expiration est dans le nom** : pas de base de données ni de fichier annexe. Le back reste sans état (n'importe quelle instance sait si un fichier a expiré), et le worker de nettoyage la lit sans jamais parler à l'API. La partie aléatoire évite les écrasements entre deux envois du même nom ou entre instances. |
| Envoi dans `.incoming/`, puis **renommage atomique** | Le champ `ttl` peut arriver après le fichier dans le formulaire : l'expiration n'est connue qu'à la fin de l'envoi. Le fichier est donc écrit sous un nom temporaire `.part` dans `.incoming/`, puis renommé avec sa date d'expiration. Le renommage est atomique car `.incoming/` est **dans le même volume** : un fichier partiel n'apparaît jamais dans la liste. Un envoi refusé (`400`, `507`) est supprimé, un envoi interrompu reste dans `.incoming/` jusqu'au passage du worker (testé). |
| Pas de `tmpfs` pour les envois en cours | Un `tmpfs` est de la RAM **comptée dans la limite mémoire** du conteneur : 50 Mo par envoi simultané feraient dépasser les 128 Mo du back. Et un déplacement `tmpfs` → volume imposerait une copie complète, puisque ce sont deux systèmes de fichiers différents. |
| Fichier expiré : masqué et `410 Gone` | Le worker ne passe que toutes les N secondes : entre l'expiration et sa suppression, l'API ne doit déjà plus le lister ni le servir. `410` (« n'existe plus ») est plus juste que `404` (« n'a jamais existé »). |
| `ttl` entre 1 minute et `TTL_MAX_H` | En dessous d'une minute, le fichier expirerait avant d'avoir pu être partagé ; au-delà du maximum, ce n'est plus du stockage temporaire. |
| Quota `STORAGE_QUOTA_MB` (`507 Insufficient Storage`) | Protège le disque de l'hôte : même avec des durées de vie, des envois peuvent s'accumuler avant d'expirer. |
| Nom d'origine nettoyé | Seuls lettres (accents compris), chiffres, espaces et `. _ -` sont gardés : pas de chemin ni de caractère spécial dans le volume. |
| Contrôle du `:name` demandé | `path.basename` doit être identique au nom, et les noms cachés (`.xxx`) sont refusés : `../` ou `%2F` ne permettent pas de sortir du dossier de stockage (testé : `404`). |
| `MAX_UPLOAD_MB` aussi dans le back | Même limite que la gateway : une double sécurité si le back est appelé sans elle. Un envoi refusé ne laisse aucun fichier partiel (testé). |
| Erreurs : `413` pour un fichier trop gros, sinon `500` générique | Le détail technique reste dans les logs et n'est pas exposé au client. |

## Image de base : build multi-stage

Même base que le Frontend (`alpine:3.22`, version fixée, Node installé par nos soins), mais en **deux stages** :

```
Stage "deps"  : alpine + nodejs + npm ──▶ npm ci --omit=dev ──▶ node_modules
                                                                     │ COPY --from=deps
Stage final   : alpine + nodejs + tini + tzdata ◀───────────────────┘   (npm n'y entre jamais)
```

| Choix | Justification |
|---|---|
| Multi-stage | npm ne sert qu'à **installer** les dépendances, pas à faire tourner l'API. Le stage `deps` est jeté à la fin : npm, son cache et ses outils n'arrivent pas dans l'image livrée. L'image est plus petite et un attaquant dispose de moins d'outils (vérifié : `npm absent` dans l'image finale). |
| `COPY package.json package-lock.json` **avant** le code | La couche `npm ci` reste en cache tant que les dépendances ne changent pas. Vérifié : après une modification de `server.js`, le rebuild affiche `npm ci ... CACHED`, donc rien n'est réinstallé. |
| `npm ci` plutôt que `npm install` | Installe **exactement** les versions du `package-lock.json` : le build est reproductible. C'est la règle du cours. |
| `--omit=dev` | Aucune dépendance de développement en production. |

**Tailles mesurées :**

| Image | Taille | Commentaire |
|---|---|---|
| Image | Alpine 3.20 / Node 20 | **Alpine 3.22 / Node 22 (actuel)** | Commentaire |
|---|---|---|---|
| Version Hello World (Node natif, aucune dépendance) | 91,8 Mo | – | Référence : l'essentiel du poids vient de `nodejs` |
| Stage `deps` (avec npm) | 116 Mo | 139 Mo | Ce que serait l'image sans multi-stage |
| **Image finale multi-stage** | 97,9 Mo | **120 Mo** | 19 Mo de moins que sans multi-stage ; Express + multer n'ajoutent qu'environ 6 Mo. Node 22 pèse environ 22 Mo de plus que Node 20 : c'est le prix d'un runtime encore maintenu |

## Dépendances installées

| Où | Dépendance | Rôle | Pourquoi ce choix |
|---|---|---|---|
| Stage `deps` (`apk`) | `nodejs`, `npm` | Installer les paquets npm | npm reste dans ce stage jetable. |
| Image finale (`apk`) | `nodejs` | Exécute `src/server.js` | Runtime seul, sans npm : les dépendances arrivent déjà installées. |
| Image finale (`apk`) | `tini` | Init minimal en PID 1 | Relaie SIGTERM à Node et nettoie les processus zombies, pour un arrêt propre. |
| Image finale (`apk`) | `tzdata` | Fuseaux horaires | Heure de Paris dans les logs de l'API. |
| npm (`package.json`) | `express` | Routage HTTP | Routes de l'API en quelques lignes. |
| npm (`package.json`) | `multer` | Décodage des envois multipart | Écrit les fichiers en flux sur le disque, sans les garder en mémoire. |

`apk add --no-cache` dans les deux stages : l'index des paquets n'est pas conservé. `wget` (healthcheck) est fourni par BusyBox : rien à installer.

## Manipulations sur l'OS

| Instruction | Explication |
|---|---|
| `ENV TZ=Europe/Paris` | Fuseau horaire du conteneur. |
| `RUN addgroup -g ${STORAGE_GID} stockage && adduser -D -H -G stockage back` | Crée le groupe `stockage`, avec un **GID fixe** venant d'un ARG, et l'utilisateur `back` (sans mot de passe ni dossier personnel) dont c'est le groupe principal : tout ce qu'il crée appartient au groupe. L'API ne tourne pas en root. Le GID est fixé parce que le worker de nettoyage doit appartenir au **même** groupe : pour le noyau, seul le numéro compte, pas le nom. |
| `RUN mkdir -p /data/files/.incoming && chown -R back:stockage /data && chmod -R 2775 /data` | Crée le dossier de stockage (et `.incoming/` pour les envois en cours) **avant** l'instruction `VOLUME` : quand Docker crée un volume neuf, il y recopie le contenu et les droits de ce dossier de l'image. `2775` : le groupe peut écrire dans le dossier, ce qui permettra au worker de supprimer (supprimer un fichier = écrire dans le **dossier**, pas dans le fichier). Le bit **setgid** (`2`) fait hériter du groupe `stockage` tout ce qui est créé dedans. Vérifié : `drwxrwsr-x back stockage`, et un fichier envoyé appartient bien à `back:stockage`. |
| `VOLUME /data` | Déclare `/data` comme dossier de données hors de la couche du conteneur. Même avec un simple `docker run`, sans compose, Docker crée un volume anonyme au lieu d'écrire dans le conteneur. Toute instruction placée après `VOLUME` qui modifierait `/data` serait ignorée : d'où le `chown` juste avant. |
| `WORKDIR /app` | Dossier de travail de l'application. |
| `COPY --from=deps /app/node_modules ./node_modules` | Récupère seulement les dépendances déjà installées par le stage `deps`, pas npm. |
| `COPY src/ ./src/` | Copie du code de l'API, qui appartient à root : `back` peut le lire mais pas le modifier. Copié en dernier, car c'est ce qui change le plus souvent. |
| `USER back` | Bascule sur l'utilisateur non-root pour l'exécution. |

## Ports exposés

| Port | Usage |
|---|---|
| `3000` | Port de l'API (valeur par défaut de `PORT`). Il n'est pas publié sur la machine hôte : seule la gateway y accède, via le réseau `interne-back`. |

## Arguments de build (ARG)

| ARG | Défaut | Rôle |
|---|---|---|
| `ALPINE_VERSION` | `3.22` | Version de l'OS de base. |
| `PORT` | `3000` | Port documenté (`EXPOSE`) et valeur par défaut de `ENV PORT`. |
| `STORAGE_GID` | `1500` | GID du groupe `stockage`, partagé avec le worker de nettoyage. Fourni par le `.env` aux deux images : une seule valeur, donc toujours identique. |

## Arguments attendus au run (ENV)

| Variable | Défaut | Rôle |
|---|---|---|
| `PORT` | `3000` (vient de l'ARG) | Port d'écoute de l'API. |
| `NODE_OPTIONS` | `--max-old-space-size=128` | Mémoire max du tas Node (Mo), lue par Node lui-même, à aligner sur la limite mémoire du conteneur. Dans le compose, la valeur vient de `BACK_NODE_MAX_MEMORY`. |
| `STORAGE_DIR` | `/data/files` | Dossier où l'API stockera les fichiers. Le code lit ce chemin au lieu de l'écrire en dur. Il doit rester sous `/data`, le point de montage du volume, sinon les fichiers seraient écrits dans le conteneur et perdus à sa suppression. |
| `MAX_UPLOAD_MB` | `10` (`50` dans le `.env`) | Taille max d'un envoi, la même que pour la gateway. Double sécurité : le back refuse aussi (`413`) si on l'appelle sans passer par la gateway. |
| `TTL_DEFAULT_H` | `24` | Durée de vie (heures) d'un fichier envoyé sans `ttl`. |
| `TTL_MAX_H` | `168` | Durée de vie maximale acceptée (7 jours) ; au-delà → `400`. |
| `STORAGE_QUOTA_MB` | `0` (`1024` dans le `.env`) | Taille totale maximale des fichiers stockés ; `0` = pas de quota. Au-delà → `507`. |
| `TZ` | `Europe/Paris` | Fuseau horaire. |

## Healthcheck

```dockerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/health || exit 1
```

Contrairement au front, on interroge une route dédiée `/health` : elle vérifie que l'API répond sans dépendre de la logique métier. Le conteneur passe en `healthy`, ce qui permet à la gateway de démarrer seulement quand le back est prêt (`depends_on: condition: service_healthy`).

## Entrypoint et gestion de SIGTERM

```dockerfile
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/server.js"]
```

Même mécanisme que le Frontend : `tini` en PID 1 relaie les signaux à Node, lancé en forme exec sans shell. La mémoire est fixée par `NODE_OPTIONS`. Dans `server.js`, SIGTERM ferme le serveur proprement puis le processus quitte avec le code 0.

Résultat testé : `docker stop` arrête le conteneur en moins d'une seconde.

## Build et run

```bash
docker build -t back ./Backend
docker run -d --name back -p 3000:3000 -e TTL_DEFAULT_H=24 -e NODE_OPTIONS=--max-old-space-size=64 --memory=128m --memory-swap=128m --cpus=0.65 back
```

Le `-p 3000:3000` sert uniquement à tester l'API seule (`curl http://localhost:3000/api/files`). Dans le compose, le back n'est pas publié.
