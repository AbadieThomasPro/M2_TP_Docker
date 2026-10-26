<#
  Régénère docs/documentation-docker-cloud.pdf à partir de documentation.html.

  Usage : powershell -ExecutionPolicy Bypass -File docs/documentation/generer-pdf.ps1
#>
param(
  # Edge plutôt qu'un outil à installer : présent sur tout poste Windows, et c'est un vrai navigateur,
  # donc les schémas Mermaid sont rendus exactement comme dans le README
  [string]$Browser = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  [int]$Port = 5602,
  # Autre destination possible : utile pour un essai pendant que le PDF du rendu est ouvert dans un lecteur
  [string]$Pdf = (Join-Path (Split-Path $PSScriptRoot -Parent) "documentation-docker-cloud.pdf")
)

$pdf = $Pdf

if (-not (Test-Path $Browser)) { Write-Host "Navigateur introuvable : $Browser (passer -Browser <chemin de chrome.exe ou msedge.exe>)"; exit 1 }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Write-Host "Python est nécessaire pour le serveur local temporaire"; exit 1 }

# Ancien PDF supprimé d'abord : sinon un échec d'Edge passerait inaperçu (l'ancien fichier serait encore là)
Remove-Item $pdf -Force -ErrorAction SilentlyContinue
if (Test-Path $pdf) { Write-Host "Impossible de remplacer $pdf (ouvert dans un lecteur PDF ?)"; exit 1 }

# Page servie en http et non ouverte en file:// : imprimée depuis un fichier local, Edge headless
# casse le rendu du schéma de séquence ("Syntax error", constaté), alors qu'il est correct en http
$server = Start-Process python -ArgumentList @("-m", "http.server", "$Port", "--bind", "127.0.0.1", "--directory", "`"$PSScriptRoot`"") -PassThru -WindowStyle Hidden
# Profil temporaire : un Edge déjà ouvert sur le poste n'interfère pas avec l'impression
$profileDir = Join-Path $env:TEMP "edge-pdf-docker-cloud"
try {
  Start-Sleep -Seconds 2   # laisse au serveur le temps d'écouter avant que le navigateur l'appelle
  # --virtual-time-budget : laisse le temps de charger Mermaid (CDN) et de dessiner les schémas avant d'imprimer.
  # --no-pdf-header-footer : pas de date ni d'URL ajoutées par le navigateur en haut et en bas des pages
  $arguments = @(
    "--headless", "--disable-gpu", "--no-pdf-header-footer", "--virtual-time-budget=20000",
    "--user-data-dir=`"$profileDir`"", "--print-to-pdf=`"$pdf`"", "http://127.0.0.1:$Port/documentation.html"
  )
  $p = Start-Process -FilePath $Browser -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
}
finally {
  # Toujours arrêter le serveur, même en cas d'erreur : aucun processus ne doit rester derrière le script
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (Test-Path $pdf) { Write-Host "PDF généré : $pdf" } else { Write-Host "Échec de la génération (code $($p.ExitCode))"; exit 1 }
