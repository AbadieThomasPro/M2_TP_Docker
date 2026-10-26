# Sujet : cloud de fichiers éphémères

[← Retour au README](../README.md) · [Documentation](README.md)

Un service de partage de **fichiers temporaires**, sur le modèle de WeTransfer, hébergé sur notre propre « cloud » Docker. Chaque fichier envoyé a une **durée de vie** (1 h, 24 h, 7 jours...) : passé ce délai, il n'est plus téléchargeable, puis il est supprimé automatiquement par un service dédié.

| Fonctionnalité | Description |
|---|---|
| Envoyer un fichier | Avec une durée de vie choisie (défaut 24 h, maximum 7 jours) |
| Lister les fichiers | Nom, taille, date d'envoi, **date d'expiration** ; les fichiers expirés n'apparaissent plus |
| Télécharger un fichier | Sous son nom d'origine ; `410 Gone` si le fichier a expiré |
| Supprimer un fichier | Avant son expiration, à la demande |
| Nettoyage automatique | Un worker supprime les fichiers expirés et les envois abandonnés |

## L'interface

![Interface du cloud de fichiers éphémères](images/interface.png)

« **Parchemins éphémères** » : application **Angular 22** d'une seule page, au design **QuestUI** (thème RPG médiéval, voir [questui-DESIGN.md](../questui-DESIGN.md)) : les fichiers sont des parchemins qui se consument.

| Élément | Comportement |
|---|---|
| Zone de dépôt | Choix du fichier et de sa **durée de vie** (1 heure, 24 heures, 7 jours), envoi avec message de confirmation ou d'erreur (fichier trop gros, quota atteint...) |
| Coffre | Liste des fichiers : nom (lien de téléchargement), taille, **temps restant** ; total en tête de liste |
| Chips de durée de vie | Doré « Expire dans... », rouge « Se consume dans... » à moins d'une heure de l'expiration |
| Temps réel | Le temps restant est recalculé chaque minute dans le navigateur, sans rappeler l'API ; un fichier expiré disparaît de la liste |
| Destruction | Bouton « Détruire » sur chaque ligne |

L'application reste volontairement minimale (cours Docker, pas cours web) : un composant, un service d'accès à l'API, et du CSS natif bâti sur des variables (aucune librairie UI). Toutes les couleurs, polices, espacements et ombres sont définis **une seule fois** dans `styles.css`, d'après le design system. Les polices sont chargées par le navigateur depuis Google Fonts : rien n'est ajouté dans les images Docker. Le build de production pèse **150 Ko** (45 Ko compressés).

L'application est compilée **dans l'image Docker du front** (build multi-stage, voir [Image Frontend](conteneurs/frontend.md#image-frontend)) : `docker compose up --build` suffit, aucune installation de Node n'est nécessaire sur la machine. En développement uniquement : `npx ng serve` dans `Frontend/app/`, qui relaie `/api` vers la stack (`proxy.conf.json`).

## Ce que le sujet permet de montrer avec Docker

| Notion Docker | Mise en œuvre dans le projet |
|---|---|
| Images personnalisées | Images construites depuis `alpine` : front (Node), back (Node, multi-stage), gateway (nginx), puis le worker de nettoyage (shell BusyBox). |
| Persistance | Les fichiers sont stockés dans un **volume Docker** : ils survivent à l'arrêt, à la suppression et à la reconstruction des conteneurs. |
| Volume partagé | Le back écrit et le worker supprime dans le même volume, grâce à un **groupe Unix commun** (`stockage`, même GID dans les deux images). |
| Isolation réseau | Seul le front est publié. La gateway et le back restent sur deux réseaux internes séparés : le front ne peut joindre le back qu'à travers la gateway. |
| Arguments au run | Durée de vie par défaut et maximale, quota de stockage, taille max d'envoi : réglables dans le `.env`, sans rebuild. |
| Limitation des ressources | CPU et mémoire par conteneur, dimensionnés par un benchmark, plus une taille max d'envoi et un quota de stockage. |
| Scalabilité | **Docker Swarm** : plusieurs instances du back (sans état : l'expiration est inscrite dans le nom des fichiers), auto-réparation, mise à jour sans coupure, et **autoscaling** par notre propre image : le nombre d'instances du back, de la gateway et du front suit le CPU et la mémoire mesurés, sans jamais dépasser 80 % de la machine (voir [Scalabilité](scalabilite.md#scalabilité)). |

## Avancement

| Étape | Statut |
|---|---|
| 3 images (front, back, gateway), compose, réseaux, healthchecks, SIGTERM, benchmark | ✅ Fait |
| Volume `stockage` monté sur le back (droits, persistance testés) | ✅ Fait |
| API de fichiers en Express (envoi, liste, téléchargement, suppression), image multi-stage | ✅ Fait |
| Gateway : envois en flux, découverte des instances du back (`resolver`) | ✅ Fait |
| Durée de vie des fichiers, quota, envois atomiques | ✅ Fait |
| Worker de nettoyage (4e image) : aucun réseau, volume partagé, arrêt propre mesuré | ✅ Fait |
| Durcissement : systèmes de fichiers en lecture seule (`read_only` + `tmpfs`) | ✅ Fait |
| Interface web (Angular, design QuestUI) | ✅ Faite |
| Image front multi-stage servant l'application Angular, stack passée en Alpine 3.22 | ✅ Fait |
| Benchmark sur l'application réelle, CPU redosés (back 0,65 / front 0,25 / gateway 0,10) | ✅ Fait |
| Tests de bout en bout : cycle de vie complet d'un fichier, persistance, arrêt propre | ✅ Fait |
| Scalabilité avec Docker Swarm : 3 back, montée en charge, auto-réparation, mise à jour sans coupure, garde-fous de ressources | ✅ Fait |
| Autoscaling (5e image) : benchmark de dimensionnement, seuils CPU / mémoire, plafond de 80 % de la machine | ✅ Fait |
