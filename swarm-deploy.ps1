<#
  Déploie la stack en mode Swarm (scalabilité). Équivalent Linux / macOS : swarm-deploy.sh

  Usage : powershell -ExecutionPolicy Bypass -File swarm-deploy.ps1
  Retrait : docker stack rm cloud

  1. Swarm doit être actif : un nœud unique suffit (docker swarm init).
  2. Les images sont construites par docker compose : Swarm ignore "build" et utilise des images existantes.
  3. Le .env est chargé dans l'environnement : docker stack deploy ne le lit pas lui-même.
#>
Set-Location $PSScriptRoot

if ((docker info --format '{{.Swarm.LocalNodeState}}') -ne 'active') {
  Write-Host "Swarm n'est pas actif. Activez-le une fois avec : docker swarm init"
  Write-Host "(réversible avec : docker swarm leave --force)"
  exit 1
}

docker compose build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Chaque ligne VARIABLE=valeur du .env devient une variable d'environnement (commentaires ignorés)
Get-Content .env | Where-Object { $_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$' } | ForEach-Object {
  Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
}

docker stack deploy -c docker-stack.yml cloud
docker stack services cloud
