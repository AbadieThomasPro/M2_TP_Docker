# Les images : points communs

[← Retour au README](../../README.md) · [Documentation](../README.md)

Quatre images, présentées dans l'ordre du trajet d'une requête (front → gateway → back), puis le worker. Chaque section suit le même plan : rôle, image de base, dépendances, manipulations sur l'OS, ports, arguments de build (ARG), arguments au run (ENV), healthcheck, entrypoint et signaux, build et run.

| Image | Base | Rôle | Taille |
|---|---|---|---|
| [Frontend](frontend.md#image-frontend) | alpine 3.22 + Node + tini, **multi-stage** (build Angular) | Point d'entrée : sert l'application, relaie `/api` | 114 Mo |
| [Gateway](gateway.md#image-gateway-serveur-web) | alpine 3.22 + nginx | Passerelle d'API : seul chemin vers le back | 18 Mo |
| [Backend](backend.md#image-backend) | alpine 3.22 + Node + tini, **multi-stage** (npm ci) | API Express des fichiers éphémères | 120 Mo |
| [Cleaner](cleaner.md#image-cleaner-worker-de-nettoyage) | alpine 3.22, **aucun paquet ajouté** | Worker : supprime les fichiers expirés | 13 Mo |

Règles communes à toutes les images : base Alpine en version fixée (ARG `ALPINE_VERSION`), aucune image applicative du Docker Hub, utilisateur non-root, `CMD` / `ENTRYPOINT` en forme exec, arrêt propre sur signal (code de sortie `0` mesuré), healthcheck, et système de fichiers en lecture seule au run.

| Fichier / instruction | Justification |
|---|---|
| `.dockerignore` | Le contexte de build ne contient que l'utile : build plus rapide, et pas de `node_modules` Windows, de `.git` ni de logs dans l'image (bonne pratique du cours). Les motifs sont écrits **`**/node_modules`** : un motif simple ne vise que la racine du contexte, et le `Frontend/app/node_modules` local (plusieurs centaines de Mo) aurait été envoyé à Docker à chaque build. |
| `LABEL org.opencontainers.image.*` | Métadonnées au format standard OCI (titre, description, auteur, dépôt), lisibles avec `docker inspect` : l'image se décrit elle-même. |
