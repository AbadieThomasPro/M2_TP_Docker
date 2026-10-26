<#
  Mesure des ressources de chaque service sous charge.

  Pour chaque scénario "requêtes:concurrence", lance ab (service bench) sur le front
  et relève en parallèle docker stats, pour garder le pic CPU et mémoire de chaque service.

  Prérequis : la stack tourne (docker compose up -d --build --wait).
  Usage     : powershell -ExecutionPolicy Bypass -File Bench/run-bench.ps1
              powershell -ExecutionPolicy Bypass -File Bench/run-bench.ps1 -Scenarios "2000:20"
#>
param(
  # Scénarios par défaut : charge légère, forte, puis très forte concurrence
  [string[]]$Scenarios = @("1000:10", "5000:50", "5000:100"),
  # Le front, comme un vrai client : la mesure couvre toute la chaîne front -> gateway -> back
  [string]$Url = "http://front/api/files"
)

# Pas d'ErrorActionPreference "Stop" : en PowerShell 5.1, la progression que docker écrit sur stderr
# serait prise pour une erreur et arrêterait le script
# Lancé depuis n'importe où : on se place à la racine du projet pour que docker compose trouve ses fichiers
Set-Location (Split-Path $PSScriptRoot -Parent)

$services = @("front", "gateway", "back")

# "12.5MiB / 192MiB" -> 12.5 (en Mo), pour comparer des nombres et pas du texte
function Convert-Mem([string]$usage) {
  $used = ($usage -split '/')[0].Trim()
  if ($used -match '([\d.]+)\s*([KMG])i?B') {
    $n = [double]$matches[1]
    switch ($matches[2]) { 'K' { return $n / 1024 } 'M' { return $n } 'G' { return $n * 1024 } }
  }
  return 0
}

# Nom du conteneur ("docker-cloud-front-1") -> nom du service ("front")
function Get-ServiceName([string]$container) {
  foreach ($s in $services) { if ($container -match "-$s-\d+$") { return $s } }
  return $null
}

# Pics CPU / mémoire par service à partir des lignes "nom;cpu%;mem"
function Get-Peaks($lines) {
  $peaks = @{}
  foreach ($s in $services) { $peaks[$s] = @{ Cpu = 0.0; Mem = 0.0 } }
  foreach ($line in $lines) {
    $parts = "$line" -split ';'
    if ($parts.Count -lt 3) { continue }
    $svc = Get-ServiceName $parts[0]
    if (-not $svc) { continue }
    $cpu = [double]($parts[1].TrimEnd('%'))
    $mem = Convert-Mem $parts[2]
    if ($cpu -gt $peaks[$svc].Cpu) { $peaks[$svc].Cpu = $cpu }
    if ($mem -gt $peaks[$svc].Mem) { $peaks[$svc].Mem = $mem }
  }
  return $peaks
}

$format = "{{.Name}};{{.CPUPerc}};{{.MemUsage}}"
$results = @()

# --- Repos : 3 relevés sans charge, pour la consommation de base ---
$idle = 1..3 | ForEach-Object { docker stats --no-stream --format $format }
$peaks = Get-Peaks $idle
foreach ($s in $services) {
  $results += [pscustomobject]@{
    Scenario = "repos"; Service = $s
    'CPU max %' = [math]::Round($peaks[$s].Cpu, 1); 'Mem max Mo' = [math]::Round($peaks[$s].Mem, 1)
    'Req/s' = ""; 'p95 ms' = ""; Echecs = ""
  }
}

# Image de bench construite une fois, hors mesure
docker compose --profile bench build bench 2>&1 | Out-Null

foreach ($sc in $Scenarios) {
  $n, $c = $sc -split ':'

  # Relevé docker stats en continu pendant toute la charge (processus séparé)
  $job = Start-Job -ScriptBlock {
    param($fmt)
    while ($true) { docker stats --no-stream --format $fmt }
  } -ArgumentList $format

  Start-Sleep -Seconds 2   # laisse au relevé le temps de démarrer avant la charge
  $ab = docker compose --profile bench run --rm bench -n $n -c $c $Url 2>&1 | Out-String
  Start-Sleep -Seconds 2   # capte la fin de la charge

  Stop-Job $job
  $lines = Receive-Job $job
  Remove-Job $job -Force

  $rps    = if ($ab -match 'Requests per second:\s+([\d.]+)') { [double]$matches[1] } else { 0 }
  $p95    = if ($ab -match '(?m)^\s*95%\s+(\d+)') { [int]$matches[1] } else { 0 }
  $failed = if ($ab -match 'Failed requests:\s+(\d+)') { [int]$matches[1] } else { -1 }
  $non2xx = if ($ab -match 'Non-2xx responses:\s+(\d+)') { [int]$matches[1] } else { 0 }

  $peaks = Get-Peaks $lines
  foreach ($s in $services) {
    $results += [pscustomobject]@{
      Scenario = "$n req / $c //"; Service = $s
      'CPU max %' = [math]::Round($peaks[$s].Cpu, 1); 'Mem max Mo' = [math]::Round($peaks[$s].Mem, 1)
      'Req/s' = $rps; 'p95 ms' = $p95; Echecs = $failed + $non2xx
    }
  }
}

$results | Format-Table -AutoSize
