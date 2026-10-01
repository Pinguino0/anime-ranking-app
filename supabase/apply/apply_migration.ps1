param(
  # Migration da applicare: nome del file in ../migrations, o percorso relativo
  # alla cartella apply.
  [Parameter(Mandatory = $true)]
  [string]$File,

  [string]$ProjectRef = 'sjbstiexythmapxmrfyp',
  [string]$Pat        = $env:SUPABASE_PAT
)

# Applica una singola migration al DB remoto tramite la Management API.
#
# Uso (Windows PowerShell):
#   $env:SUPABASE_PAT = 'sbp_...'
#   .\apply_migration.ps1 -File 018_transfer_group_ownership.sql
#
# Perche' uno script e non il comando in linea:
#   - Get-Content -Raw restituisce in PowerShell 5.1 un oggetto con una
#     proprieta' `value`, non una stringa. ConvertTo-Json lo serializza
#     come {"query":{"value":"..."}} e la Management API risponde
#     "expected string, received object". Il cast a [string] e' obbligatorio.
#   - [Text.Encoding]::UTF8.GetBytes serve perche' le migration hanno caratteri
#     non ASCII (virgolette curve, accenti nei commenti): senza, il corpo
#     viaggia in latin-1 e quei caratteri diventano spazzatura. Il corpo non
#     contiene dati utenti, quindi la codifica sbagliata romperebbe i soli
#     commenti: nessun errore, ma il file applicato non e' quello del repo.
#
# Le migration NON sono idempotenti (nessun "create table if not exists"):
# rieseguire una gia' applicata fallisce. Controllare prima con
# check_drift.ps1.

$ErrorActionPreference = 'Stop'

if (-not $Pat) {
  throw 'PAT mancante: imposta $env:SUPABASE_PAT prima di eseguire lo script.'
}

$path = Join-Path $PSScriptRoot "..\migrations\$File"
if (-not (Test-Path -LiteralPath $path)) {
  throw "Migration non trovata: $path"
}

# Il cast a [string] e' la parte importante, vedi nota in testa al file.
$sql = [string](Get-Content -LiteralPath $path -Raw)

# `-Depth 5` perche' ConvertTo-Json in 5.1 tronca a 2 livelli e segnalerebbe
# un avviso poco leggibile su una stringa lunga.
$body = @{ query = $sql } | ConvertTo-Json -Compress -Depth 5

Write-Host ("applico {0} ({1} caratteri)" -f $File, $sql.Length)

$response = Invoke-RestMethod -Method Post `
  -Uri "https://api.supabase.com/v1/projects/$ProjectRef/database/query" `
  -Headers @{ Authorization = "Bearer $Pat"; 'Content-Type' = 'application/json' } `
  -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 240

Write-Host 'applicata.'
$response | ConvertTo-Json -Depth 5