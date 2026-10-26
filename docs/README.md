# Documentation

[← Retour au README](../README.md)

**Synthèse du rendu (PDF, 8 pages)** : [documentation-docker-cloud.pdf](documentation-docker-cloud.pdf), les choix en tableaux, organisés selon le barème, avec les schémas légendés.

Le détail, partie par partie :

| Partie | Contenu | Critère du barème |
|---|---|---|
| [Sujet](sujet.md) | Le cloud de fichiers éphémères, l'interface, les notions Docker montrées, l'avancement | – |
| [Architecture](architecture.md) | Schémas : architecture (compose et Swarm), communications, cycle de vie d'un fichier, ordre de démarrage | Schéma des communications |
| [Configuration](configuration.md) | ARG, ENV et `.env` : qui fixe quoi, et pourquoi | Arguments attendus |
| [Images : points communs](images/points-communs.md) | Règles appliquées à toutes les images | – |
| [Image Frontend](images/frontend.md) | Multi-stage Angular, relais `/api`, tini | Dépendances · OS · Arguments · Entrypoint |
| [Image Gateway](images/gateway.md) | nginx, config générée au run, `exec "$@"` | Dépendances · OS · Arguments · Entrypoint |
| [Image Backend](images/backend.md) | API Express, multi-stage, volume et droits | Dépendances · OS · Arguments · Entrypoint |
| [Image Cleaner](images/cleaner.md) | Worker sans réseau, arrêt propre en pleine passe | Dépendances · OS · Arguments · Entrypoint · SIGTERM |
| [Image Autoscaler](images/autoscaler.md) | Autoscaling Swarm, socket Docker | Dépendances · OS · Arguments · Entrypoint |
| [Orchestration](orchestration.md) | Compose : arguments, ressources, ordre de démarrage, SIGTERM, volume, réseaux | Compose · Ressources · SIGTERM · Dépendances |
| [Benchmark](benchmark.md) | Comment les limites CPU et mémoire ont été mesurées et choisies | Ressources expliquées |
| [Scalabilité](scalabilite.md) | Docker Swarm, autoscaling mesuré, Docker face aux VM | – |
| [Tests et vérifications](tests.md) | Récapitulatif des tests et des défauts corrigés | – |

Sources : la synthèse PDF est générée depuis [documentation/documentation.html](documentation/documentation.html) par [documentation/generer-pdf.ps1](documentation/generer-pdf.ps1).
