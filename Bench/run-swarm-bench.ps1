<#
  Benchmark de la stack Swarm pour dimensionner l'autoscaling.

  Pour chaque nombre d'instances du back puis chaque niveau de concurrence, lance ab (service Swarm
  ponctuel sur cloud_public) et releve docker stats en parallele. Le CPU est exprime en % de la LIMITE
  du service (pas en % d'un coeur), pour le comparer au seuil de 80 %.

  Prerequis : la stack tourne (swarm-deploy.ps1).
  Usage     : powershell -ExecutionPolicy Bypass -File Bench/run-swarm-bench.ps1
              powershell -ExecutionPolicy Bypass -File Bench/run-swarm-bench.ps1 -BackReplicas 1,3 -Concurrencies 25,50
#>
param(
  [int[]]$BackReplicas = @(1, 2, 3, 5),
  [int[]]$Concurrencies = @(10, 25, 50, 100),
  [int]$Requests = 4000,
  [string]$Csv = "$env:TEMP\swarm-bench.csv"
)

# Pas d'ErrorActionPreference "Stop" : la progression docker sur stderr serait prise pour une erreur
Set-Location (Split-Path $PSScriptRoot -Parent)

# Limites du .env (CPU en coeurs, memoire en Mo) : base du calcul en % de la limite
$envVals = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$' } | ForEach-Object { $envVals[$matches[1]] = $matches[2] }
$limits = @{
  back    = @{ Cpu = [double]$envVals['BACK_CPUS'];          Mem = 128 }
  front   = @{ Cpu = [double]$envVals['SWARM_FRONT_CPUS'];   Mem = 128 }
  gateway = @{ Cpu = [double]$envVals['SWARM_GATEWAY_CPUS']; Mem = 48 }
}
$services = @("front", "gateway", "back")

function Convert-Mem([string]$usage) {
  $used = ($usage -split '/')[0].Trim()
  if ($used -match '([\d.]+)\s*([KMG])i?B') {
    $n = [double]$matches[1]
    switch ($matches[2]) { 'K' { return $n / 1024 } 'M' { return $n } 'G' { return $n * 1024 } }
  }
  return 0
}

# "cloud_back.2.abc123" -> "back"
function Get-ServiceName([string]$container) {
  foreach ($s in $services) { if ($container -like "cloud_$s.*") { return $s } }
  return $null
}

# Attend que toutes les instances soient pretes ET que l'API reponde
function Wait-Ready([int]$back) {
  for ($i = 0; $i -lt 60; $i++) {
    $svc = docker service ls --format "{{.Name}} {{.Replicas}}"
    # Le back affiche aussi "(max 6 per node)" apres le compte : on compare le debut de la ligne
    $ok = (@($svc -like "cloud_back $back/$back*").Count -eq 1) -and ($svc -contains "cloud_front 1/1") -and ($svc -contains "cloud_gateway 1/1")
    if ($ok) {
      $code = curl.exe -s -m 5 -o NUL -w "%{http_code}" http://127.0.0.1:8080/api/files
      if ($code -eq "200") { return $true }
    }
    Start-Sleep -Seconds 2
  }
  return $false
}

# Lance ab comme service ponctuel et renvoie sa sortie (comparable d'un test a l'autre)
function Invoke-Ab([int]$n, [int]$c) {
  docker service rm bench 2>&1 | Out-Null
  docker service create --name bench --network cloud_public --restart-condition none --limit-cpu 1 --limit-memory 32M --detach docker-cloud/bench -n $n -c $c http://front/api/files 2>&1 | Out-Null
  for ($i = 0; $i -lt 300; $i++) {
    $st = docker service ps bench --format "{{.CurrentState}}" 2>$null | Select-Object -First 1
    if ($st -match '^(Complete|Failed|Rejected|Shutdown)') { break }
    Start-Sleep -Seconds 1
  }
  $out = docker service logs bench --raw 2>&1 | Out-String
  docker service rm bench 2>&1 | Out-Null
  return $out
}

$fmt = "{{.Name}};{{.CPUPerc}};{{.MemUsage}}"
$results = @()

foreach ($b in $BackReplicas) {
  docker service scale cloud_back=$b --detach 2>&1 | Out-Null
  if (-not (Wait-Ready $b)) { Write-Host "Stack non prete avec $b back : arret"; break }
  Start-Sleep -Seconds 3

  foreach ($c in $Concurrencies) {
    # Releve docker stats en continu pendant la charge (processus separe)
    $job = Start-Job -ScriptBlock { param($f) while ($true) { docker stats --no-stream --format $f } } -ArgumentList $fmt
    Start-Sleep -Seconds 2
    $ab = Invoke-Ab $Requests $c
    Start-Sleep -Seconds 1
    Stop-Job $job
    $lines = Receive-Job $job
    Remove-Job $job -Force

    $rps    = if ($ab -match 'Requests per second:\s+([\d.]+)') { [double]$matches[1] } else { 0 }
    $p95    = if ($ab -match '(?m)^\s*95%\s+(\d+)') { [int]$matches[1] } else { 0 }
    $failed = if ($ab -match 'Failed requests:\s+(\d+)') { [int]$matches[1] } else { -1 }
    $non2xx = if ($ab -match 'Non-2xx responses:\s+(\d+)') { [int]$matches[1] } else { 0 }

    # Regroupe les lignes par echantillon (un docker stats = une serie de lignes) : CPU moyen des instances
    # du service par echantillon, puis pic de ces moyennes ; memoire = pic de la pire instance
    $perSvcCpu = @{}; $perSvcMem = @{}
    foreach ($s in $services) { $perSvcCpu[$s] = @(); $perSvcMem[$s] = 0.0 }
    $cur = @{}
    foreach ($line in $lines) {
      $p = "$line" -split ';'
      if ($p.Count -lt 3) { continue }
      $s = Get-ServiceName $p[0]
      if (-not $s) { continue }
      if ($cur.ContainsKey($p[0])) {
        # nouvel echantillon : on clot le precedent
        foreach ($k in $services) { if ($cur["_$k"]) { $perSvcCpu[$k] += ($cur["_$k"] | Measure-Object -Average).Average } }
        $cur = @{}
      }
      $cur[$p[0]] = 1
      $cpuPct = [double]($p[1].TrimEnd('%'))
      if (-not $cur["_$s"]) { $cur["_$s"] = @() }
      $cur["_$s"] += $cpuPct
      $mem = Convert-Mem $p[2]
      if ($mem -gt $perSvcMem[$s]) { $perSvcMem[$s] = $mem }
    }
    foreach ($k in $services) { if ($cur["_$k"]) { $perSvcCpu[$k] += ($cur["_$k"] | Measure-Object -Average).Average } }

    foreach ($s in $services) {
      $peak = if ($perSvcCpu[$s].Count) { ($perSvcCpu[$s] | Measure-Object -Maximum).Maximum } else { 0 }
      $results += [pscustomobject]@{
        Back = $b; Conc = $c; Service = $s
        'Req/s' = $rps; 'p95 ms' = $p95; Echecs = $failed + $non2xx
        'CPU pic % limite' = [math]::Round($peak / ($limits[$s].Cpu * 100) * 100, 0)
        'Mem pic Mo' = [math]::Round($perSvcMem[$s], 1)
        'Mem % limite' = [math]::Round($perSvcMem[$s] / $limits[$s].Mem * 100, 0)
      }
    }
    Write-Host ("back={0} conc={1} : {2} req/s, p95 {3} ms, echecs {4}" -f $b, $c, $rps, $p95, ($failed + $non2xx))
  }
}

# Retour a la configuration par defaut de la stack
docker service scale cloud_back=3 --detach 2>&1 | Out-Null
$results | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
$results | Format-Table -AutoSize
Write-Host "Resultats : $Csv"
