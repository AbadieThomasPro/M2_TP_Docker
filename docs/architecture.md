# Architecture

[← Retour au README](../README.md) · [Documentation](README.md)



## Schéma d'architecture : services, réseaux, ports, volume

```mermaid
flowchart TB
  nav(["🌐 Navigateur"])

  subgraph hote["Machine hôte · Docker"]
    direction TB
    subgraph expose["Zone exposée · réseau public"]
      front["<b>front</b><br/>alpine + Node + tini<br/>écoute :80<br/>0,25 CPU · 128 Mo"]
    end
    subgraph interne["Zone interne · réseaux internal: true (sans Internet)"]
      gateway["<b>gateway</b><br/>alpine + nginx<br/>écoute :80<br/>0,10 CPU · 48 Mo"]
      back["<b>back</b><br/>alpine + Node + tini<br/>écoute :3000<br/>0,65 CPU · 128 Mo"]
      vol[("volume <b>stockage</b><br/>monté sur /data")]
    end
    subgraph isole["Aucun réseau · network_mode: none"]
      cleaner["<b>cleaner</b><br/>alpine + shell BusyBox<br/>aucun port<br/>0,10 CPU · 16 Mo"]
    end
  end

  nav <-- "HTTP :8080<br/>seul port publié (8080→80)" --> front
  front <-- "réseau interne-front<br/>/api/* → http://gateway:80" --> gateway
  gateway <-- "réseau interne-back<br/>/api/* → http://back:3000" --> back
  back <-- "lecture + écriture<br/>(groupe stockage)" --> vol
  cleaner <-- "lecture des noms + suppression<br/>(groupe stockage)" --> vol
  front -. "⛔ bloqué : aucun réseau commun" .- back

  classDef pub fill:#e6efff,stroke:#1d63ed,color:#1b2330
  classDef int fill:#efe8fd,stroke:#7a4fd6,color:#1b2330
  classDef data fill:#e3f6ec,stroke:#1f9d63,color:#1b2330
  classDef iso fill:#fdf0e2,stroke:#d9771a,color:#1b2330
  class front pub
  class gateway,back int
  class vol data
  class cleaner iso
```

**Lecture des flèches :** une flèche à double sens représente un **échange** : une requête dans un sens, la réponse dans l'autre (ou, pour le volume, des lectures et des écritures). Le libellé indique **qui ouvre la connexion** (« `/api/*` → `http://gateway:80` » : c'est le front qui appelle la gateway). La gateway ne fait que répondre au front, elle ne l'appelle jamais, et le back ne contacte personne. Le lien en pointillés front ⋯ back est **bloqué** : ces deux services n'ont aucun réseau en commun. Le détail de chaque aller-retour est dans le [schéma des communications](#schéma-des-communications--chemin-dune-requête).

| Élément | À retenir |
|---|---|
| Seul port publié | `8080` sur l'hôte → `80` du front. Aucun autre service n'a de `ports:`. |
| Réseaux | `public` (front), `interne-front` (front + gateway), `interne-back` (gateway + back), **aucun** pour le cleaner. La gateway est le seul pont : le lien direct front → back est bloqué. |
| Volume | `stockage`, monté sur `/data` du back (écriture) et du cleaner (suppression), avec un groupe Unix commun. |
| Ressources | Limites CPU / mémoire par service, issues du `.env` et dimensionnées par un benchmark. |

### Le même schéma en mode Swarm

![Architecture en mode Swarm : front, gateway et back en nombre variable, adresse virtuelle du back, cleaner isolé, autoscaler relié au socket Docker, volume cloud_stockage](architecture-swarm.png)

Mêmes services, mêmes réseaux et même volume : seuls le **nombre d'instances** et la façon de les joindre changent, et un 5e service, l'autoscaler, ajuste ce nombre. Source Mermaid et détail dans la partie [Scalabilité](scalabilite.md#architecture-en-mode-swarm).

| Élément | Ce que montre le schéma |
|---|---|
| Services | Nombre d'instances **variable**, piloté par l'[autoscaler](images/autoscaler.md#image-autoscaler-mode-swarm) : back **2 à 6**, gateway **1 à 3**, front **1 à 2**. Le cleaner reste **toujours à 1** : deux workers supprimeraient les mêmes fichiers. |
| Autoscaler | 1 instance sur le manager ; il agit **par le socket Docker** (en pointillés), jamais par le réseau : son réseau `isole-autoscaler` n'a aucun autre membre. |
| Port | `8080` publié par le **routing mesh** de Swarm : l'hôte reçoit la connexion et la transmet au front. |
| Réseaux | `interne-front` (front, gateway) et `interne-back` (gateway, back) comme dans le compose. Le cleaner est sur `isole` (`internal: true`) : Swarm n'accepte pas `network_mode: none`, ce réseau sans sortie le remplace. |
| Adresse virtuelle | La gateway appelle `back` comme avant ; Swarm lui donne une **adresse virtuelle** et répartit les connexions entre les instances. Aucune config nginx à changer pour ajouter une instance. |
| Volume | `cloud_stockage` (le volume `stockage` préfixé par le nom de la stack) est partagé par toutes les instances du back (lecture et écriture) et le cleaner (suppression). |
| Ressources | back 0,65 CPU chacun, front 0,75 et gateway 0,30 : ils relaient le trafic de plusieurs back, d'où plus de CPU que dans le compose (0,25 et 0,10). Gateway à 96 Mo (48 dans le compose) pour les envois en parallèle. |

## Schéma des communications : chemin d'une requête

```mermaid
sequenceDiagram
  autonumber
  actor N as Navigateur
  participant F as front (Node)
  participant G as gateway (nginx)
  participant B as back (Node)
  N->>F: GET / sur 127.0.0.1:8080
  F-->>N: application Angular (index.html, main-*.js, styles-*.css)
  N->>F: GET /api/files (même origine, pas de CORS)
  F->>G: relais vers http://gateway/api/files (interne-front)
  G->>B: proxy_pass vers http://back:3000/api/files (interne-back)
  B-->>G: 200 [liste des fichiers non expirés]
  G-->>F: 200
  F-->>N: 200, liste affichée dans le coffre
  Note over N,G: Envoi plus gros que MAX_UPLOAD_MB : la gateway répond 413 sans contacter le back
```

Le navigateur ne connaît que le front : il ne peut pas résoudre les noms de service Docker (`gateway`, `back`). C'est le `server.js` du front qui relaie `/api` vers la gateway, puis nginx qui transmet au back.

## Cycle de vie d'un fichier éphémère

```mermaid
sequenceDiagram
  autonumber
  actor N as Navigateur
  participant B as back (via front et gateway)
  participant V as volume stockage
  participant C as cleaner
  N->>B: POST /api/files (fichier + ttl=24)
  B->>V: écriture en flux dans .incoming/xxx.part
  B->>V: renommage atomique en expiration-aléatoire__nom
  B-->>N: 201, expiresAt
  Note over B,V: Avant l'expiration : listé et téléchargeable
  Note over B,V: Après l'expiration : masqué de la liste, téléchargement → 410
  C->>V: passe toutes les 60 s : lit l'expiration dans les noms
  C->>V: supprime les fichiers expirés et les .part abandonnés
  Note over B,C: Le back et le cleaner ne se parlent jamais : ils partagent seulement le volume
```

## Ordre de démarrage

```mermaid
flowchart LR
  B["<b>1 · back</b><br/>healthcheck GET /health"] -- "service_healthy" --> G["<b>2 · gateway</b><br/>healthcheck GET /health"] -- "service_healthy" --> F["<b>3 · front</b><br/>healthcheck GET /"]
  B -- "service_healthy" --> C["<b>2 · cleaner</b><br/>healthcheck : dernière passe récente"]
```

Chaque service attend que le précédent soit `healthy` (`depends_on: condition: service_healthy`) : la gateway ne reçoit du trafic qu'une fois le back prêt (sinon elle répondrait `502`), le front n'est ouvert qu'une fois toute la chaîne prête, et le cleaner attend que le back ait initialisé les droits du volume.
