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

# Chaque ligne VARIABLE=valeur du .env devient une variable d'environnement (commentaires ignorés).
# Chargé avant les builds : l'image de l'autoscaler en a besoin pour ses arguments
Get-Content .env | Where-Object { $_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$' } | ForEach-Object {
  Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
}

docker compose build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# L'autoscaler n'existe qu'en Swarm (le compose n'a pas d'instances à piloter) : docker compose build
# ne le connaît pas, on le construit à part, avec les mêmes valeurs du .env
docker build -t docker-cloud/autoscaler --build-arg ALPINE_VERSION=$env:ALPINE_VERSION --build-arg DOCKER_GID=$env:DOCKER_GID ./Autoscaler
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

docker stack deploy -c docker-stack.yml cloud
docker stack services cloud
