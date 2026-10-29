# Image Cleaner (worker de nettoyage)

[← Retour au README](../../README.md) · [Documentation](../README.md)

Le cœur de la spécificité « fichiers éphémères » : un **worker** qui tourne en boucle et, à chaque passe :
- supprime les fichiers **expirés**, en lisant leur date d'expiration directement dans leur nom (`<epoch>-<aléatoire>__<nom>`), sans jamais parler à l'API ;
- supprime les **envois abandonnés** dans `.incoming/` (fichiers `.part` plus vieux que `INCOMING_MAX_AGE_MIN`).

Ce n'est pas un serveur : pas de port, pas de réseau, et un healthcheck qui ne passe pas par HTTP. C'est ce qui le distingue des trois autres images.

## Image de base

| Choix | Justification |
|---|---|
| `alpine:3.22`, **sans aucun paquet ajouté** | Le BusyBox d'Alpine fournit déjà tout ce dont le script a besoin : `sh`, `ls`, `awk`, `xargs`, `rm`, `find`, `stat`, `setsid`. Ajouter Node ou Python pour une boucle de quelques lignes alourdirait l'image et la surface d'attaque sans rien apporter. |
| Script shell plutôt qu'application | Le travail consiste à lister, filtrer et supprimer des fichiers : exactement ce que font les outils Unix de base. |

## Dépendances installées

**Aucune** (pas de `apk add`). Les outils utilisés sont ceux de BusyBox, déjà présents dans Alpine. Pas de `tzdata` non plus : les logs sont écrits en UTC, et le format l'indique explicitement (`...Z`) plutôt que d'afficher une heure locale trompeuse.

## Manipulations sur l'OS

| Instruction | Explication |
|---|---|
| `RUN addgroup -g ${STORAGE_GID} stockage && adduser -D -H -u 1002 -G stockage cleaner` | Utilisateur dédié `cleaner`, non-root, membre du groupe `stockage` **avec le même GID que le back** (ARG fourni par le `.env`). Supprimer un fichier demande le droit d'écriture sur le **dossier** : le dossier de stockage est en `2775` groupe `stockage`, le cleaner peut donc supprimer sans être root ni être `back`. |
| UID fixé à `1002` (et `1001` pour le back) | **Problème constaté en test** : par défaut, `adduser` donne l'UID 1000 au premier utilisateur de chaque image, donc `back` et `cleaner` avaient le même UID. Pour le noyau, seuls les numéros comptent : le cleaner était vu comme le **propriétaire** du dossier, avec tous les droits, et le groupe partagé ne servait à rien (il supprimait même dans un dossier en `755`). Avec des UID distincts, ce sont bien les droits du groupe qui s'appliquent. |
| `RUN mkdir -p /data/files/.incoming && chown -R cleaner:stockage /data && chmod -R 2775 /data` | Le même dossier de stockage que dans l'image du back. En compose, `depends_on` fait démarrer le back en premier, et c'est son image qui initialise le volume. En **Swarm**, il n'y a pas d'ordre de démarrage : si le cleaner montait le volume vide en premier sans ce dossier, le volume serait initialisé avec un `/data` appartenant à root, et le back ne pourrait plus écrire. Avec ce dossier dans les deux images, l'ordre n'a plus d'importance (vérifié : volume initialisé par le cleaner, le back y écrit). |
| `COPY --chmod=755 cleanup.sh /usr/local/bin/` | Script exécutable dès la copie (pas de `RUN chmod`, donc une couche de moins), copié en dernier car c'est ce qui change le plus. |
| Pas de `VOLUME /data` | Lancé seul, le worker n'a rien à nettoyer : c'est le compose qui lui partage le volume du back. Un `VOLUME` créerait ici un volume anonyme vide et trompeur. |
| `USER cleaner` | Exécution sans root. |

## Ports et réseau

Aucun port : le worker n'écoute rien et ne contacte personne. Dans le compose, **`network_mode: none`** lui retire toute interface réseau (vérifié : seule l'interface `lo` existe). C'est le moindre privilège poussé au bout : même compromis, il ne peut rien joindre.

## Arguments de build (ARG)

| ARG | Défaut | Rôle |
|---|---|---|
| `ALPINE_VERSION` | `3.22` | Version de l'OS de base. |
| `STORAGE_GID` | `1500` | GID du groupe `stockage`. Doit être identique à celui du back : une seule valeur dans le `.env`, passée aux deux images. |

## Arguments attendus au run (ENV)

| Variable | Défaut | Rôle |
|---|---|---|
| `STORAGE_DIR` | `/data/files` | Dossier à nettoyer (le volume partagé avec le back). |
| `CLEANUP_INTERVAL_S` | `60` | Délai entre deux passes. L'API masque déjà les fichiers expirés : l'intervalle ne retarde que la libération de l'espace disque, une minute suffit. |
| `INCOMING_MAX_AGE_MIN` | `60` | Âge à partir duquel un envoi `.part` est considéré comme abandonné. Même un envoi de 50 Mo à 100 Ko/s dure moins de 9 min. |
| `HEARTBEAT_FILE` | `/tmp/heartbeat` | Fichier de preuve de vie lu par le healthcheck. |

## Healthcheck

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=2 \
  CMD ["/usr/local/bin/cleanup.sh", "--healthcheck"]
```

Le worker n'a pas de réseau : impossible de l'interroger en HTTP. À la place, chaque passe met à jour `/tmp/heartbeat`, et le healthcheck vérifie que ce fichier a **moins de deux intervalles**. Si la boucle est bloquée (disque inaccessible, script figé), le conteneur passe `unhealthy`.

## Entrypoint et gestion de SIGTERM

```dockerfile
ENTRYPOINT ["/usr/local/bin/cleanup.sh"]
```

Le script est lancé directement en **PID 1**, sans `tini`. Il gère lui-même SIGTERM avec un `trap`, et ne laisse pas de processus enfant derrière lui.

Arrêter un worker qui supprime des fichiers est le cas typique où SIGTERM compte : il ne doit être ni tué à la fin du délai d'arrêt (`stop_grace_period: 10s`, code `137`), ni laisser un état incohérent. La mise au point a demandé plusieurs essais, tous mesurés sur 10 000 fichiers expirés :

| Version | Problème mesuré | Correction |
|---|---|---|
| 1. Un `rm` par fichier | 10 000 processus : la passe n'était pas finie au bout de 45 s avec 0,1 CPU | Suppression **par lots** avec `xargs` (des centaines de noms par appel à `rm`) : 6 s. |
| 2. `xargs` lancé au premier plan | Le shell n'exécute un `trap` qu'à la fin de la commande en cours : avec peu de CPU, la passe dépassait le délai d'arrêt de 10 s → **code `137`** | Suppression lancée **en arrière-plan** + `wait`, qui est interrompu immédiatement par le signal. |
| 3. `kill` du processus de suppression | Ses enfants (`awk`, `xargs`, `rm`) continuaient | Suppression lancée avec **`setsid`**, dans son propre groupe de processus : le trap arrête tout le groupe d'un coup (`kill -TERM -<pgid>`). |
| 4. Signal reçu pendant le comptage initial | La suppression était quand même lancée → `137` avec 0,05 CPU | Le drapeau d'arrêt est vérifié **avant** de lancer la suppression. |
| 5. `kill $!` en fin de script | Sans attente lancée, `$!` n'existe pas et `set -u` faisait sortir avec le code `2` | PID du `sleep` mémorisé dans une variable, testée avant le `kill`. |

**Pourquoi on peut interrompre une suppression en cours :** chaque suppression (`unlink`) est **atomique**. Un fichier est soit supprimé, soit intact, jamais à moitié. Interrompre la passe laisse donc un état cohérent, et les fichiers restants sont traités au démarrage suivant (vérifié : 9 408 restants après l'arrêt, 0 après le redémarrage).

Autres choix du script :
- **`sleep` en arrière-plan + `wait`** entre deux passes : un `sleep` au premier plan bloquerait le `trap` jusqu'à la fin de l'attente (60 s).
- **`set -u`** : une variable mal orthographiée fait échouer le script au lieu de viser un mauvais dossier.
- **Contrôle après suppression** : les fichiers expirés encore présents sont comptés et journalisés en `ERREUR`. Un refus de droits ne passe pas inaperçu (testé : dossier passé en `755` → `ERREUR : 1 fichier(s) expiré(s) non supprimé(s)`).

**Résultats mesurés** (arrêt pendant une passe sur 10 000 fichiers, signal envoyé 1, 3 ou 5 s après le début) :

| CPU | Arrêt | Code de sortie |
|---|---|---|
| 0,05 | 0,6 à 2,3 s | `0` dans les 3 cas |
| 0,10 (retenu) | 0,5 à 0,6 s | `0` dans les 3 cas |

## Ressources (mesurées)

| Mesure (10 000 fichiers expirés) | 0,05 CPU | **0,10 CPU** | 0,25 CPU |
|---|---|---|---|
| Durée de la passe | 13 s | **6 s** | 2 s |
| Pic mémoire | ~8 Mo | ~4 Mo | ~5 Mo |

Au repos : **0 % de CPU et environ 0,5 Mo de mémoire**. Valeurs retenues : **0,10 CPU** (une passe de 10 000 fichiers reste bien plus courte que l'intervalle de 60 s), **16 Mo** de mémoire (2 fois le pic le plus élevé), réservation de 6 Mo (le minimum accepté par Docker). C'est de loin le service le plus léger de la stack.

## Build et run

```bash
docker build -t cleaner ./Cleaner
# avec le volume du back (créé par lui en premier, pour les droits)
docker run -d --name cleaner --network none -v docker-cloud_stockage:/data \
  --read-only --tmpfs /tmp:size=1m -e CLEANUP_INTERVAL_S=60 --memory=16m --memory-swap=16m --cpus=0.1 cleaner
docker logs -f cleaner   # une ligne par passe : fichiers supprimés, envois abandonnés, refus
```
