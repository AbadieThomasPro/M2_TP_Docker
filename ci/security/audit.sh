#!/bin/sh
# Étape security de la CI : npm audit sur les dépendances de PRODUCTION du back et du front.
# --omit=dev : seules les dépendances livrées dans les images comptent (le compilateur Angular, par
# exemple, ne tourne jamais en production). Échec si une faille atteint le niveau AUDIT_LEVEL.

set -u
LEVEL=${AUDIT_LEVEL:-high}
rc=0

for dir in Backend Frontend/app; do
  name=$(echo "$dir" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
  json="/reports/audit-$name.json"
  echo "== npm audit : $dir (échec à partir du niveau $LEVEL) =="
  if ! cd "/workspace/$dir"; then echo "ERREUR : dossier $dir introuvable"; rc=1; continue; fi
  # Rapport complet en JSON pour l'archive ; le code de sortie de npm audit donne le verdict
  npm audit --omit=dev --audit-level="$LEVEL" --json > "$json"
  code=$?
  # Résumé lisible : nombre de failles par gravité
  node -e '
    const r = require(process.argv[1]);
    const v = (r.metadata && r.metadata.vulnerabilities) || {};
    console.log("failles :", ["critical", "high", "moderate", "low", "info"].map((k) => k + "=" + (v[k] || 0)).join(" "));
  ' "$json"
  if [ "$code" -eq 0 ]; then echo "OK"; else echo "ÉCHEC : faille de niveau $LEVEL ou plus (détail : $json)"; rc=1; fi
done

exit "$rc"
