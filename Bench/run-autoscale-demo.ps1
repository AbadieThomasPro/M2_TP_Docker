<#
  Démonstration de l'autoscaler (mode Swarm) : charge longue, puis repos, avec le nombre d'instances
  affiché toutes les 10 s. Équivalent Linux / macOS : run-autoscale-demo.sh

  Prérequis : stack déployée (swarm-deploy.ps1).
  Usage     : powershell -ExecutionPolicy Bypass -File Bench/run-autoscale-demo.ps1
              powershell -ExecutionPolicy Bypass -File Bench/run-autoscale-demo.ps1 -LoadSeconds 120 -Concurrency 100
#>
param(
  [int]$LoadSeconds = 180,
  [int]$Concurrency = 50,
  [int]$RestSeconds = 300,
  [string]$Log = "$env:TEMP\autoscale-demo.log"
)

Set-Location (Split-Path $PSScriptRoot -Parent)

if (-not (docker service ls -q --filter name=cloud_autoscaler)) {
  Write-Host "Stack Swarm introuvable : la déployer d'abord avec swarm-deploy.ps1"
  exit 1
}
# Image de l'outil construite à la demande : la stack Swarm ne la construit pas, ce n'est pas un service de l'application
docker image inspect docker-cloud/bench *> $null
if ($LASTEXITCODE -ne 0) { docker compose --profile bench build bench }

$start = Get-Date
"début $(Get-Date -Format 'HH:mm:ss') : charge $LoadSeconds s à $Concurrency en parallèle, puis repos $RestSeconds s" | Tee-Object -FilePath $Log

docker service rm bench 2>&1 | Out-Null
# ab en service Swarm ponctuel sur le réseau public de la stack : il attaque le front comme un vrai client.
# -n très grand : sinon ab s'arrête à 50 000 requêtes avant la fin de la durée demandée
docker service create --name bench --network cloud_public --restart-condition none --limit-cpu 1 --limit-memory 32M --detach docker-cloud/bench -t $LoadSeconds -n 10000000 -c $Concurrency http://front/api/files 2>&1 | Out-Null

# UNE boucle bornée, sans Start-Job : des relevés docker stats en tâche de fond, oubliés après une
# interruption, ont déjà saturé la machine de test (580 processus PowerShell)
$rounds = [math]::Ceiling(($LoadSeconds + $RestSeconds) / 10) + 3
for ($i = 0; $i -lt $rounds; $i++) {
  $t = [int]((Get-Date) - $start).TotalSeconds
  $r = @{}
  docker service ls --format "{{.Name}} {{.Replicas}}" | ForEach-Object {
    $p = $_ -split ' '; $r[$p[0] -replace '^cloud_', ''] = $p[1]
  }
  $phase = if ($t -lt $LoadSeconds + 5) { "charge" } else { "repos " }
  ("t={0,4}s {1} back={2,-4} gateway={3,-4} front={4,-4}" -f $t, $phase, $r['back'], $r['gateway'], $r['front']) | Tee-Object -FilePath $Log -Append
  Start-Sleep -Seconds 10
}

$ab = docker service logs bench --raw 2>&1 | Out-String
docker service rm bench 2>&1 | Out-Null
"--- résultat de ab" | Tee-Object -FilePath $Log -Append
($ab -split "`n" | Where-Object { $_ -match 'Complete requests|Failed requests|Non-2xx|Requests per second|^\s*(50|95|99)%' }) | Tee-Object -FilePath $Log -Append
"--- décisions de l'autoscaler" | Tee-Object -FilePath $Log -Append
# Durée relative ("530s") : une date absolue est mal interprétée selon le fuseau de la machine
$since = "$([int]((Get-Date) - $start).TotalSeconds + 5)s"
docker service logs --raw --since $since cloud_autoscaler 2>&1 | Where-Object { $_ -notmatch 'relev' } | Tee-Object -FilePath $Log -Append
"fin $(Get-Date -Format 'HH:mm:ss') ; journal complet : $Log" | Tee-Object -FilePath $Log -Append
