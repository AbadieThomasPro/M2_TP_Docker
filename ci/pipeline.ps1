<#
  Pipeline CI/CD complet : joue le rôle d'un serveur de CI (Jenkins, GitLab Runner...), chaque étape
  étant un conteneur. Équivalent Linux / macOS : ci/pipeline.sh

    0. build        images de l'application + images des étapes de CI
    1. lint ∥ test  (en parallèle)               ┐ ci/compose.yml : une étape ne démarre que si
    2. security ∥ policy (après lint ET test)    ┘ les précédentes sont sorties avec le code 0
    3. intégration  vraie stack isolée (projet docker-cloud-it), tests de bout en bout, arrêt en code 0
    4. déploiement  ci/deploy.ps1 : mise à jour progressive sur Swarm (si Swarm est actif)

  Usage : powershell -ExecutionPolicy Bypass -File ci/pipeline.ps1 [-SansDeploiement] [-IA]
    -IA : ajoute l'étape ai-test (tests écrits par un agent Claude, jeton dans ci/ia.env)
  Code de sortie : 0 si tout est vert. Au premier échec, le pipeline s'arrête : rien n'est déployé,
  la version en service reste en place. Rapports : ci/reports/
#>
param(
  [switch]$SansDeploiement,
  # Étape IA sur demande seulement : elle consomme la limite de l'abonnement Claude de l'utilisateur
  [switch]$IA
)

# Pas d'ErrorActionPreference "Stop" : en PowerShell 5.1, la progression que docker écrit sur stderr
# serait prise pour une erreur. Chaque étape teste $LASTEXITCODE, le vrai contrat d'une commande
Set-Location (Split-Path $PSScriptRoot -Parent)
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$ci = @("compose", "-f", "ci/compose.yml", "--env-file", ".env")
if ($IA) {
  # Échec franc et immédiat sans jeton : demander l'IA et ne pas l'avoir n'est jamais un succès
  $tok = Get-Content ci/ia.env -ErrorAction SilentlyContinue | Where-Object { $_ -match '^CLAUDE_CODE_OAUTH_TOKEN=.*sk-ant-' -and $_ -notmatch 'FAUX-JETON' }
  if (-not $tok) {
    Write-Host "❌ -IA demandé sans jeton : copier ci/ia.env.example en ci/ia.env et y mettre le sien (claude setup-token)"
    exit 2
  }
  $ci += @("--profile", "ia")
}
$it = @("compose", "-p", "docker-cloud-it", "-f", "docker-compose.yml", "-f", "ci/compose.integration.yml", "--env-file", ".env")
$summary = New-Object System.Collections.Generic.List[string]
$t0 = Get-Date

Get-Content .env | Where-Object { $_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$' } | ForEach-Object {
  Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
}

function Start-Step($name) { $script:step = $name; $script:stepT = Get-Date; Write-Host ""; Write-Host "▶ $name" }
function Complete-Step { $summary.Add("  ✅ $script:step ($([int]((Get-Date) - $script:stepT).TotalSeconds) s)") }
# Échec : résumé, puis arrêt avec le code de l'étape (le bloc finally nettoie quand même)
function Stop-Pipeline([int]$code = 1) {
  $summary.Add("  ❌ $script:step ($([int]((Get-Date) - $script:stepT).TotalSeconds) s)")
  $summary | ForEach-Object { Write-Host $_ }
  Write-Host ""
  Write-Host "❌ Pipeline en ÉCHEC à l'étape « $script:step » : rien n'est déployé, la version en service ne change pas."
  Write-Host "   Rapports : ci/reports/"
  $script:exitCode = $code
  throw "arret"
}

$exitCode = 0
try {
  # Rapports de l'exécution précédente effacés : un vieux rapport ne doit pas passer pour le nouveau
  Remove-Item ci/reports -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force ci/reports | Out-Null

  Start-Step "build : images de l'application et de la CI"
  docker compose config --quiet; if ($LASTEXITCODE) { Stop-Pipeline }
  docker @ci config --quiet; if ($LASTEXITCODE) { Stop-Pipeline }
  docker compose build --quiet; if ($LASTEXITCODE) { Stop-Pipeline }
  docker build --quiet -t docker-cloud/autoscaler --build-arg ALPINE_VERSION=$env:ALPINE_VERSION --build-arg DOCKER_GID=$env:DOCKER_GID ./Autoscaler | Out-Null
  if ($LASTEXITCODE) { Stop-Pipeline }
  docker @ci build --quiet; if ($LASTEXITCODE) { Stop-Pipeline }
  Complete-Step

  Start-Step "lint ∥ test, puis security ∥ policy"
  # Conteneurs neufs à chaque exécution : un conteneur d'une exécution passée ne doit pas compter
  docker @ci down -v *> $null
  docker @ci up --abort-on-container-failure
  $rc = $LASTEXITCODE
  docker @ci cp lint:/reports/. ci/reports/ *> $null
  # Tests écrits par l'agent copiés pour relecture humaine, même (surtout) si l'étape a échoué
  if ($IA) { New-Item -ItemType Directory -Force ci/reports/ai-tests | Out-Null; docker @ci cp ai-test:/tests/. ci/reports/ai-tests/ *> $null }
  if ($rc) { Stop-Pipeline $rc }
  Complete-Step

  Start-Step "intégration : stack isolée, tests de bout en bout"
  docker @it up -d --wait; if ($LASTEXITCODE) { Stop-Pipeline }
  docker @it run --name docker-cloud-it-tests integration
  $rc = $LASTEXITCODE
  docker cp docker-cloud-it-tests:/reports/junit-integration.xml ci/reports/ *> $null
  docker rm docker-cloud-it-tests *> $null
  if ($rc) { Stop-Pipeline $rc }
  # Arrêt propre vérifié : chaque service de la stack doit sortir avec le code 0 (SIGTERM traité)
  $ids = docker @it ps -q
  docker @it stop *> $null
  $bad = foreach ($id in $ids) { $c = docker inspect -f '{{.State.ExitCode}}' $id; if ($c -ne '0') { "$(docker inspect -f '{{.Name}}' $id)=$c" } }
  if ($bad) { Write-Host "Arrêt non propre : $($bad -join ', ')"; Stop-Pipeline }
  Write-Host "Arrêt de la stack de test : code 0 pour chaque service"
  Complete-Step

  if (-not $SansDeploiement -and (docker info --format '{{.Swarm.LocalNodeState}}') -eq 'active') {
    Start-Step "déploiement : mise à jour progressive sur Swarm"
    powershell -ExecutionPolicy Bypass -File ci/deploy.ps1
    if ($LASTEXITCODE) { Stop-Pipeline }
    Complete-Step
  } else {
    $summary.Add("  ⏭  déploiement ignoré (option -SansDeploiement, ou Swarm inactif)")
  }

  $summary | ForEach-Object { Write-Host $_ }
  Write-Host ""
  Write-Host "✅ Pipeline vert en $([int]((Get-Date) - $t0).TotalSeconds) s. Rapports : ci/reports/"
}
catch {
  if ($exitCode -eq 0) { Write-Host "Erreur inattendue : $_"; $exitCode = 1 }
}
finally {
  # Toujours exécuté, même après un échec : aucune stack de test ni conteneur d'étape ne reste derrière
  docker @it --profile integration down -v --remove-orphans *> $null
  docker @ci down -v *> $null
}
exit $exitCode
