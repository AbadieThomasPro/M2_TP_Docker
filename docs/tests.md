# Tests et vérifications

[← Retour au README](../README.md) · [Documentation](README.md)

Récapitulatif des vérifications faites sur la stack finale (Alpine 3.22, limites de l'étape 6 du benchmark). Le détail de chaque test est dans la partie concernée.

| Domaine | Test | Résultat |
|---|---|---|
| Démarrage | `docker compose up -d --build --wait` | Les 4 services `healthy`, dans l'ordre back → gateway / cleaner → front |
| Application | Envoi, liste, téléchargement, destruction depuis l'interface | ✅ (navigateur) |
| Cycle de vie d'un fichier | Envoi avec une durée de vie d'1 minute | `200` → après expiration : masqué et `410` → après la passe du worker : supprimé du volume, `404` |
| Persistance | Envoi puis `docker compose down` / `up` | Fichier toujours présent, contenu intact |
| Limites d'envoi | 60 Mo pour une limite à 50 | `413` renvoyé par la gateway, sans atteindre le back |
| Quota | Quota à 1 Mo, envoi de 2 Mo | `507`, aucun fichier laissé |
| Sécurité de l'API | `../`, `%2F`, fichiers cachés, `ttl` invalides | `404` / `400` |
| Réseau | Qui peut joindre qui (`wget` depuis chaque conteneur) | Front → back **bloqué**, back / gateway sans Internet, cleaner sans aucune interface réseau |
| Ports | `docker compose ps` | Seul le front publie un port (`8080`) |
| Droits du volume | Fichier du back (1001:1500) supprimé par le cleaner (1002:1500) | ✅ ; dossier en `755` → `ERREUR` journalisée |
| Lecture seule | `touch` hors volume et hors `/tmp` | `Read-only file system` pour les 4 services |
| Téléchargements | 40 Mo téléchargés lentement (2 Mo/s) | Complets (avant correction : coupés à 7 Mo) |
| Images | Contenu des images finales | Ni `npm` ni `node_modules` ni sources dans le front ; ni `npm` dans le back |
| Cache de build | Modification du code seul | `npm ci` reste `CACHED` (front et back) |
| Ressources | `docker inspect` des limites | Conformes au `.env` ; swap désactivée (`MemorySwap` = `Memory`) |
| Dépassement mémoire | Back limité à 6 Mo sans swap | Tué (`OOMKilled`, code `137`) puis relancé par `restart: unless-stopped` |
| Arrêt propre | `docker compose stop` de chaque service | **Code de sortie `0`** pour les 4, en moins d'une seconde |
| Arrêt du worker en pleine passe | SIGTERM pendant la suppression de 10 000 fichiers | Code `0` dans 6 cas sur 6, reprise au redémarrage |
| Charge | 5 000 requêtes, 50 en parallèle sur la liste | Compose : 166 req/s, p95 389 ms ; Swarm (3 back) : 431 à 574 req/s, p95 197 à 278 ms ; **0 échec** |
| Swarm : montée en charge | `docker service scale cloud_back=5` | 5/5 en 17 s, 5 instances répondent |
| Swarm : auto-réparation | `docker kill` d'une instance | Recréée en 13 s, 0 erreur sur 179 requêtes |
| Swarm : mise à jour | `docker service update --force cloud_back` | 0 erreur sur 520 requêtes |
| Swarm : garde-fous | 9 instances demandées (plafond 6) ; 5 CPU réservés par instance | Instances en trop `Pending`, application toujours disponible |
| Swarm : ordre de démarrage | Volume neuf initialisé par le cleaner | Le back y écrit quand même (`201`) |
| Swarm : persistance | `docker stack rm` puis redéploiement | Fichiers intacts |
| Autoscaling : montée | 3 min de charge (`ab`, 50 puis 150 en parallèle) | back 2 → 3 en 41 s, gateway 1 → 2 en 92 s ; **0 échec** sur 94 000 requêtes |
| Autoscaling : descente | Fin de la charge | Retour aux minimums en 72 s, sans oscillation |
| Autoscaling : bornes | Scale manuel à 8 (max 6) | Ramené à 6 au relevé suivant |
| Autoscaling : budget machine | Budget abaissé à 30 % | Montées refusées et journalisées |
| Autoscaling : mémoire | 20 envois de 40 Mo en parallèle | Plus aucun `502` (gateway à 96 Mo) |
| Autoscaler : sécurité | `id`, `touch`, `wget` dans le conteneur | Non-root, lecture seule, aucun réseau joignable ; seuls montages : socket et `/tmp` |
| Autoscaler : arrêt | `docker stop`, mise à jour du service | **Code `0`**, en 0,6 s |

**Défauts trouvés par ces tests et corrigés** (détaillés dans leurs parties) : front qui contournait la gateway (réseaux séparés), client bloqué après un `413` (relais), clients HTTP/1.0 bloqués (en-têtes hop-by-hop), limites mémoire doublées par la swap (`memswap_limit`), UID identiques entre back et cleaner (UID explicites), worker tué en pleine passe (`setsid`), téléchargements tronqués avec un `tmpfs` (`proxy_max_temp_file_size 0`), back devenu goulot avec l'application réelle (CPU redosés), gateway proche de sa limite mémoire pendant des envois parallèles (96 Mo en Swarm, plus aucun `502`).

**Défaut identifié, non corrigé :** front à 99 % de sa mémoire lors d'une rafale de 20 envois de 40 Mo, trop rapide pour l'autoscaler (voir [Ce que l'autoscaler ne règle pas](scalabilite.md#ce-que-lautoscaler-ne-règle-pas-constaté)).
