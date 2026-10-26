# Benchmark : comment les limites ont été choisies

[← Retour au README](../README.md) · [Documentation](README.md)

Les limites ne sont pas fixées au hasard : elles sont dimensionnées à partir de **mesures sous charge**, faites avec un outil construit pour l'occasion.

La démarche s'est faite en **deux temps** : un premier dimensionnement sur la version Hello World (étapes 1 à 5), puis un **redimensionnement sur l'application réelle** (étape 6), parce que l'API Express qui liste des fichiers ne coûte pas du tout la même chose que l'API Hello World. Les valeurs retenues sont celles de l'étape 6.

## Outil de mesure

> L'outil est livré dans le dépôt (`Bench/`) pour que les mesures soient rejouables : mode d'emploi pas à pas dans [tester-la-charge.md](tester-la-charge.md).

| Élément | Choix |
|---|---|
| Image `Bench/` | Alpine + `apache2-utils` (`ab`, outil de charge HTTP). Image faite par nous, comme les autres (pas d'image de bench du Hub), non-root, `ENTRYPOINT ["ab"]` : le conteneur s'utilise comme une commande. |
| Service `bench` dans le compose | Dans le profil `bench` : il ne démarre pas avec `docker compose up`, seulement à la demande. Branché sur le réseau `public` uniquement : il attaque le **front comme un vrai client**, donc la mesure couvre toute la chaîne front → gateway → back. Limité lui aussi (1 CPU) pour ne pas voler le CPU des services mesurés. |
| Script [Bench/run-bench.ps1](../Bench/run-bench.ps1) | Lance chaque scénario `ab` et relève `docker stats` en parallèle pendant toute la charge, pour garder le **pic** CPU et mémoire de chaque service. |

Pour rejouer les mesures :

```bash
docker compose up -d --build --wait
powershell -ExecutionPolicy Bypass -File Bench/run-bench.ps1                          # mesure complète (Windows)
docker compose --profile bench run --rm bench -n 5000 -c 50 http://front/api/files   # un scénario seul
docker stats                                                                          # suivi en direct, dans un autre terminal
```

Scénarios : au repos, 1 000 requêtes à 10 en parallèle, 5 000 requêtes à 50 en parallèle, 5 000 requêtes à 100 en parallèle. Machine de test : Docker Desktop, 12 CPU.

## Étape 1 : mesure de départ (0,5 CPU pour chaque service)

| Scénario | front CPU / Mo | gateway CPU / Mo | back CPU / Mo | Req/s | p95 |
|---|---|---|---|---|---|
| Repos | 1 % / 12 Mo | 4 % / 2 Mo | 3 % / 11 Mo | – | – |
| 5 000 req, 50 en parallèle | **50 %** / 23 Mo | 31 % / 2 Mo | 33 % / 19 Mo | 763 | 103 ms |
| 5 000 req, 100 en parallèle | **50 %** / 25 Mo | 31 % / 2 Mo | 30 % / 18 Mo | 875 | 174 ms |

Constat : le **front plafonne à sa limite** (50 %) et bride toute la chaîne, alors que la gateway et le back ont de la marge. Avec la même part de CPU pour tous, une partie du CPU de la gateway et du back est gaspillée.

## Étape 2 : coût de chaque service, en variant les CPU (5 000 req, 50 en parallèle)

| Config (front / gateway / back) | Req/s | p95 | Goulot observé |
|---|---|---|---|
| 0,25 / 0,5 / 0,5 | 294 | 306 ms | front, plafonné à 25 % |
| 0,5 / 0,5 / 0,5 | 763 | 103 ms | front, plafonné à 50 % |
| 1 / 0,5 / 0,5 | 1 225 | 80 ms | gateway, au maximum (52 %) |
| 1 / 0,25 / 0,5 | 781 | 97 ms | gateway, plafonnée à 25 % |
| 1 / 0,25 / 0,25 | 553 | 196 ms | gateway et back |
| 1 / 0,1 / 0,5 | 348 | 201 ms | gateway, plafonnée à 10 % |

Dans la config la plus rapide (1 225 req/s), on déduit le **coût CPU d'une requête** pour chaque service (CPU au pic ÷ débit) :

| Service | Coût CPU par requête | Pourquoi |
|---|---|---|
| front | ~0,74 ms | Le plus coûteux : il reçoit chaque requête **et** en ouvre une nouvelle vers la gateway (relais). |
| gateway (nginx) | ~0,42 ms | nginx est efficace, mais il relaie lui aussi chaque requête vers le back. |
| back | ~0,36 ms | Il ne fait que répondre. |

## Étape 3 : dimensionnement retenu

**CPU, dosé en proportion du coût par requête**, pour que les trois services saturent à peu près au même débit et qu'aucun CPU ne soit gaspillé :
- front **0,5** : 0,5 / 0,74 ms ≈ 675 req/s ;
- gateway **0,25** : 0,25 / 0,42 ms ≈ 600 req/s ;
- back **0,25** : 0,25 / 0,36 ms ≈ 690 req/s.

Le front reçoit le double des autres parce qu'il coûte deux fois plus par requête. **nginx reçoit autant que le back, mais pas plus** : malgré sa légèreté, il traite toutes les requêtes. Lui donner moins (0,1 CPU) divise le débit de la stack par 3,5 (348 req/s).

**Mémoire, dosée selon le pic mesuré.** C'est là que nginx se distingue nettement :
- **gateway : 32 Mo** pour un pic d'environ 4 Mo. nginx ne garde presque rien en mémoire. 32 Mo laissent 8 fois de marge, soit 4 fois moins que les services Node. *(Relevé à 48 Mo à l'étape 6, après une mesure pendant des envois parallèles.)*
- **front et back : 128 Mo** pour un pic d'environ 20 à 25 Mo. Node a un coût fixe plus élevé (moteur V8, environ 9 Mo au repos). La marge (plus de 5 fois) est prévue pour les uploads de l'application. Le tas JavaScript est plafonné à **64 Mo** (`NODE_OPTIONS`), la moitié de la limite : le reste couvre la mémoire hors tas (buffers des flux d'upload), pour que Node libère sa mémoire avant d'atteindre la limite du conteneur.
- **Réservations** légèrement au-dessus du pic mesuré (32 Mo pour Node, 8 Mo pour nginx) : même si l'hôte manque de mémoire, chaque service garde de quoi tourner normalement.

## Étape 4 : validation avec les valeurs retenues (sans swap)

| Scénario | front CPU / Mo | gateway CPU / Mo | back CPU / Mo | Req/s | p95 | Échecs |
|---|---|---|---|---|---|---|
| Repos | 0 % / 9 Mo | 0 % / 2 Mo | 0 % / 8 Mo | – | – | – |
| 1 000 req, 10 en parallèle | 42 % / 13 Mo | 13 % / 2 Mo | 26 % / 12 Mo | 335 | 88 ms | 0 |
| 5 000 req, 50 en parallèle | 45 % / 22 Mo | 25 % / 3 Mo | 25 % / 19 Mo | 634 | 182 ms | 0 |
| 5 000 req, 100 en parallèle | 50 % / 25 Mo | 27 % / 4 Mo | 22 % / 20 Mo | 803 | 200 ms | 0 |

Avec **1 CPU au total** (contre 1,5 au départ), la stack garde 80 à 90 % du débit initial, sans aucun échec. Les trois services arrivent ensemble près de leur limite, ce qui montre que le dosage est équilibré. Les pics mémoire restent loin des plafonds.

## Étape 5 : test de dépassement mémoire (OOM)

| Test | Résultat |
|---|---|
| Back limité à **6 Mo, sans swap** | Tué par le noyau (`OOMKilled=true`, code `137`), puis relancé en boucle par `restart: unless-stopped` (8 redémarrages en 20 s). C'est le comportement attendu d'une limite dépassée. |
| Back limité à 6 Mo **avec** la swap par défaut | Ne meurt pas : il déborde sur la swap (`MemorySwap` = 12 Mo). C'est ce constat qui a conduit à ajouter `memswap_limit`. |
| Processus qui alloue de la mémoire en boucle dans un conteneur à 48 Mo (swap par défaut) | Tué vers 80 Mo et non 48 : la limite réelle était doublée par la swap. |

## Étape 6 : redimensionnement sur l'application réelle (Express, Node 22, Alpine 3.22)

Mesures sur la route la plus appelée par l'interface, `GET /api/files`, avec 20 fichiers dans le coffre (5 000 requêtes, 50 en parallèle) :

| Config (front / gateway / back) | Req/s | p95 | CPU back | CPU front | CPU gateway |
|---|---|---|---|---|---|
| Valeurs de l'étape 3 : 0,5 / 0,25 / **0,25** | 91 | 708 ms | **27 %, à sa limite** | 14 % | 4 % |
| Idem, 2e mesure (variabilité) | 82 | 799 ms | **27 %, à sa limite** | 12 % | 4 % |
| 0,5 / 0,25 / **0,5** | 174 | 397 ms | **51 %, à sa limite** | 19 % | 10 % |
| Large : 1 / 0,5 / 1 (pour mesurer les coûts) | 361 | 201 ms | **101 %, à sa limite** | 44 % | 14 % |

Le dosage de l'étape 3 ne convient plus : **le back est devenu le seul goulot**. Lister le coffre lui demande de lire le dossier puis d'interroger chaque fichier, soit environ **2,8 ms de CPU par requête** (contre 0,36 ms pour l'API Hello World), alors que le front et la gateway attendent. Coûts mesurés dans la configuration large : back **~2,8 ms**, front **~1,2 ms**, gateway **~0,4 ms**, soit un rapport d'environ **7 / 3 / 1**.

**Nouveau dosage, pour le même budget d'1 CPU** : back **0,65**, front **0,25**, gateway **0,10**, chacun calibré pour tenir environ 210 à 250 req/s. Comme la liste ne dit rien des envois (que le front et la gateway relaient en flux), le dosage a été vérifié aussi sur des envois :

| Mesure | Étape 3 : 0,5 / 0,25 / 0,25 | **Retenu : 0,25 / 0,10 / 0,65** |
|---|---|---|
| 1 envoi de 49 Mo | 2,2 s (22 Mo/s) | **1,3 s (38 Mo/s)** |
| 5 envois de 20 Mo en parallèle | 5,4 s | **3,4 s** |
| Liste, 5 000 req à 50 en parallèle | 70 req/s, p95 902 ms | **166 req/s, p95 389 ms** |
| Pics mémoire pendant les envois | front 37 Mo, gateway **26 Mo**, back 33 Mo | front 31 Mo, gateway 4 Mo, back 26 Mo |

Avec le même budget CPU, la liste va **2,4 fois** plus vite et les envois **1,6 fois** plus vite.

**Mémoire de la gateway relevée à 48 Mo** : pendant 5 envois en parallèle, nginx a atteint 26 Mo. Or son `tmpfs` `/tmp` (8 Mo) est compté dans la même limite : 26 + 8 aurait dépassé les 32 Mo de l'étape 3, avec un risque d'arrêt par l'OOM killer. À 48 Mo, nginx reste 2,7 fois moins gourmand que les services Node (128 Mo).

Les limites mémoire des services Node ne changent pas : les pics mesurés (37 Mo au plus) restent loin des 128 Mo, et le tas plafonné à 64 Mo laisse la place à la mémoire hors tas utilisée par les envois en flux.

## Bug révélé par le benchmark

Le premier lancement d'`ab` restait **bloqué** après environ 500 requêtes. Le relais du front recopiait tels quels les en-têtes de nginx `transfer-encoding: chunked` et `connection: keep-alive`. Ce sont des en-têtes « hop-by-hop » (RFC 7230), propres à une connexion, qu'un proxy ne doit pas retransmettre. Un client HTTP/1.0 comme `ab` ne sait pas lire le format `chunked` et attendait une fermeture qui n'arrivait jamais ; les navigateurs, en HTTP/1.1, ne voyaient pas le problème. Le relais retire maintenant ces en-têtes (`withoutHopByHop` dans [Frontend/server.js](../Frontend/server.js)). Résultat : 0 échec sur tous les scénarios.
