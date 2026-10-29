<#
  Déploiement continu (CD) : publie sur la stack Swarm les images que la CI vient de valider, puis
  attend que Swarm ait fini la mise à jour progressive. Équivalent Linux / macOS : ci/deploy.sh

  Usage : powershell -ExecutionPolicy Bypass -File ci/deploy.ps1 [-Tag <version>]
    Tag : par défaut le hash git court du commit testé (suffixé "-modifie" si le dossier contient des
          changements non commités : l'image ne correspond alors à aucun commit)
  Code de sortie : 0 si toutes les instances tournent la nouvelle version, 1 sinon (retour arrière de
  Swarm, délai dépassé) : l'ancienne version reste alors en service.
#>
param(
  [string]$Tag = "",
  # 5 min : une mise à jour complète (5 services, monitor de 30 s, une instance à la fois) en prend 2 à 3
  [int]$TimeoutSeconds = 300
)

Set-Location (Split-Path $PSScriptRoot -Parent)
$stack = "cloud"
$services = @("back", "gateway", "front", "cleaner", "autoscaler")

# Le .env n'est pas versionné : sans lui, la stack serait déployée avec des réglages vides
if (-not (Test-Path .env)) { Write-Host ".env absent : le créer avec  cp .env.example .env"; exit 1 }

if ((docker info --format '{{.Swarm.LocalNodeState}}') -ne 'active') {
  Write-Host "Swarm inactif : déploiement impossible (l'activer une fois avec docker swarm init)"
  exit 1
}

if (-not $Tag) {
  $Tag = git rev-parse --short HEAD
  if ($LASTEXITCODE -ne 0) { exit 1 }
  if (git status --porcelain) { $Tag = "$Tag-modifie" }
}

# Les images validées par la CI portent le tag "latest" : on leur donne le tag de version, sans les
# reconstruire, pour déployer exactement ce qui a été testé
foreach ($s in $services) {
  docker image inspect "docker-cloud/${s}:$Tag" *> $null
  if ($LASTEXITCODE -ne 0) {
    docker tag "docker-cloud/${s}:latest" "docker-cloud/${s}:$Tag"
    if ($LASTEXITCODE -ne 0) { Write-Host "Image docker-cloud/$s introuvable : lancer d'abord le build"; exit 1 }
  }
}

# docker stack deploy ne lit pas le .env : on le charge dans l'environnement, comme swarm-deploy.ps1
Get-Content .env | Where-Object { $_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$' } | ForEach-Object {
  Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
}
$env:IMAGE_TAG = $Tag

$start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Write-Host "Déploiement de la version $Tag sur la stack $stack"
docker stack deploy -c docker-stack.yml $stack *> $null
if ($LASTEXITCODE -ne 0) { exit 1 }

# Attente bornée de la convergence : chaque service doit tourner la nouvelle image, avec toutes ses
# instances, et sans mise à jour en cours. Un retour arrière de Swarm est un échec du déploiement
while ($true) {
  $pending = @(); $failed = @()
  foreach ($s in $services) {
    $svc = "${stack}_$s"
    $img = docker service inspect -f '{{.Spec.TaskTemplate.ContainerSpec.Image}}' $svc
    $raw = docker service inspect -f '{{if .UpdateStatus}}{{if .UpdateStatus.StartedAt}}{{.UpdateStatus.StartedAt.Unix}} {{.UpdateStatus.State}}{{end}}{{end}}' $svc
    $state = ""
    # Statut ignoré s'il date d'un déploiement précédent (avant celui-ci)
    if ($raw) { $p = "$raw".Split(' '); if ([long]$p[0] -ge $start - 2) { $state = $p[1] } }
    $reps = (docker service ls --filter "name=$svc" --format '{{.Replicas}}' | Select-Object -First 1)
    $running = ($reps -split '/')[0]; $wanted = (($reps -split '/')[1] -split ' ')[0]
    if ($state -in @('rollback_completed', 'paused')) { $failed += "$s($state)" }
    if ($img -notmatch ":$([regex]::Escape($Tag))(@|$)") { $pending += $s; continue }
    if ($state -in @('updating', 'rollback_started') -or $running -ne $wanted) { $pending += $s }
  }
  $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $start
  if ($failed) {
    Write-Host "ÉCHEC du déploiement après $elapsed s : retour arrière de Swarm pour $($failed -join ', ')"
    Write-Host "La version précédente est restée en service."
    exit 1
  }
  if (-not $pending) {
    Write-Host "Version $Tag en service sur les 5 services ($elapsed s)"
    docker stack services $stack --format '{{.Name}}  {{.Replicas}}  {{.Image}}'
    exit 0
  }
  if ($elapsed -ge $TimeoutSeconds) {
    Write-Host "ÉCHEC : déploiement non terminé après $TimeoutSeconds s (en attente : $($pending -join ', '))"
    exit 1
  }
  Write-Host "  $elapsed s : mise à jour en cours pour $($pending -join ', ')"
  Start-Sleep -Seconds 5
}
