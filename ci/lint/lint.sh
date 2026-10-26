#!/bin/sh
# Étape lint de la CI : scripts shell (shellcheck), syntaxe JavaScript (node --check), et règles du
# projet sur les Dockerfile. Le code est monté en lecture seule dans /workspace.
# Code de sortie : 0 si tout est conforme, 1 sinon (le pipeline s'arrête alors avant les tests suivants)

set -u
REPORT=/reports/lint.txt
LIST=/tmp/fichiers
cd /workspace || exit 1
rc=0
: > "$REPORT"

say() { echo "$*" | tee -a "$REPORT"; }

# Liste de fichiers dans un fichier temporaire, puis lue avec une redirection : un « find | while »
# exécuterait la boucle dans un sous-shell, et rc=1 y serait perdu
lister() { find . -path ./node_modules -prune -o -path '*/node_modules' -prune -o -path ./Frontend/app -prune -o "$@" -print | sort > "$LIST"; }

say "== shellcheck : scripts shell (niveau warning et au-dessus) =="
lister -name '*.sh'
while IFS= read -r f; do
  if out=$(shellcheck -S warning "$f" 2>&1); then say "OK      $f"; else say "ERREUR  $f"; say "$out"; rc=1; fi
done < "$LIST"

say ""
say "== node --check : syntaxe JavaScript (hors application Angular, compilée par son image) =="
lister \( -name '*.js' -o -name '*.mjs' \)
while IFS= read -r f; do
  if out=$(node --check "$f" 2>&1); then say "OK      $f"; else say "ERREUR  $f"; say "$out"; rc=1; fi
done < "$LIST"

say ""
say "== Dockerfile : règles du projet (AGENTS.md) =="
lister -name 'Dockerfile'
while IFS= read -r f; do
  # Images de l'application (services) : en plus, HEALTHCHECK et LABEL OCI obligatoires.
  # Les outils (CI, bench) s'arrêtent seuls : un healthcheck n'aurait pas de sens
  case "$f" in
    ./Frontend/*|./Gateway/*|./Backend/*|./Cleaner/*|./Autoscaler/*) app=1 ;;
    *) app=0 ;;
  esac
  # Programme awk entre apostrophes : aucune apostrophe dans ses commentaires (elle fermerait la chaîne).
  # Les lignes de suite d'un HEALTHCHECK sont ignorées : sa commande peut être en forme shell (${PORT})
  # Fins de ligne Windows (\r) retirées : un fichier édité sous Windows reste conforme. Commentaires ignorés
  errs=$(awk -v app="$app" '
    { sub(/\r$/, ""); u = toupper($1) }
    /^[ \t]*#/ { next }
    hc_cont { hc_cont = ($0 ~ /\\$/); next }
    u == "FROM" {
      img = $2; if (img ~ /^--platform/) img = $3
      if (!(img in stages) && img != "alpine:${ALPINE_VERSION}") print "FROM " img " : seule la base alpine:${ALPINE_VERSION} est admise"
      for (i = 1; i < NF; i++) if (toupper($i) == "AS") stages[$(i + 1)] = 1
    }
    u == "ARG" && $2 ~ /^ALPINE_VERSION/ { arg = 1; if ($2 ~ /latest/) print "ALPINE_VERSION ne doit jamais valoir latest" }
    u == "USER" { user = $2 }
    u == "HEALTHCHECK" { hc = 1; hc_cont = ($0 ~ /\\$/) }
    (u == "CMD" || u == "ENTRYPOINT") && $2 !~ /^\[/ { print u " en forme shell (ligne " NR ") : la forme exec [\"...\"] transmet les signaux" }
    /apk add/ && !/--no-cache/ { print "apk add sans --no-cache (ligne " NR ")" }
    /org\.opencontainers\.image\.title/ { label = 1 }
    END {
      if (!arg) print "ARG ALPINE_VERSION absent : la version d Alpine doit venir du .env"
      if (user == "" || user == "root" || user == "0") print "pas de USER non-root (dernier USER : " (user == "" ? "aucun" : user) ")"
      if (app && !hc) print "HEALTHCHECK manquant"
      if (app && !label) print "LABEL org.opencontainers.image.title manquant"
    }' "$f")
  if [ -z "$errs" ]; then say "OK      $f"; else say "ERREUR  $f"; say "$errs"; rc=1; fi
done < "$LIST"

say ""
say "== Secrets : aucun jeton Anthropic réel dans le dépôt =="
# Jetons d'abonnement (sk-ant-oat…), clés d'API et d'administration (sk-ant-api…, sk-ant-admin…) suivis
# d'au moins 20 caractères : la forme d'un vrai jeton, pas une simple mention du préfixe dans la doc.
# Exclus : ci/ia.env (le SEUL endroit prévu pour le jeton, ignoré par git), les rapports et .git.
# La fausse clé de l'exemple (FAUX-JETON) est admise. Seul le NOM du fichier est affiché, jamais le jeton
SECRET='sk-ant-(oat|api|admin)[0-9]{2}-[A-Za-z0-9_-]{20,}'
# find + grep -l plutôt que grep -r --exclude-dir : le grep de BusyBox ne connaît pas --exclude-dir, et
# la recherche échouait EN SILENCE (aucun fichier trouvé, contrôle toujours vert : constaté)
if ! find . \( -name .git -o -name node_modules -o -path ./ci/reports -o -path ./ci/ia.env \) -prune \
     -o -type f -exec grep -lE "$SECRET" {} + > "$LIST.brut" 2> /tmp/erreurs-secrets; then
  # grep -l rend 1 quand un lot de fichiers ne contient rien : seule une vraie erreur doit compter
  if [ -s /tmp/erreurs-secrets ]; then say "ERREUR  recherche de secrets impossible :"; say "$(cat /tmp/erreurs-secrets)"; rc=1; fi
fi
sort "$LIST.brut" > "$LIST"
found=0
while IFS= read -r f; do
  if grep -oE "$SECRET" "$f" | grep -qv 'FAUX-JETON'; then
    say "ERREUR  $f : jeton Anthropic réel détecté (le retirer, puis le révoquer : il est compromis)"
    found=1
    rc=1
  fi
done < "$LIST"
[ "$found" -eq 0 ] && say "OK      aucun jeton réel (ci/ia.env exclu : seul emplacement prévu, ignoré par git)"

say ""
if [ "$rc" -eq 0 ]; then say "Lint : tout est conforme"; else say "Lint : ÉCHEC (voir les ERREUR ci-dessus)"; fi
exit "$rc"
