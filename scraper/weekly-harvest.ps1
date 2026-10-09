# ============================================================================
# weekly-harvest.ps1 - esegue il sitemap-diff di AnimeUnity (Task Scheduler)
# ============================================================================
#
# Pensato per il Task Scheduler di Windows: scarica la sitemap di AnimeUnity e
# importa in `provider_anime_index` solo i record nuovi. Lo script Node
# (seed/harvest_animeunity.js) e' gia' ripartibile, quindi eseguirlo una volta a
# settimana e' il "diff".
#
# La service role key NON e' nel repo: si legge da, in ordine,
#   1. la variabile d'ambiente SUPABASE_SERVICE_ROLE_KEY
#   2. il file %USERPROFILE%\.anime-ranking\service_role.key
#
# Log in %LOCALAPPDATA%\anime-ranking\logs\harvest-YYYYMMDD.log
# ============================================================================

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$seedDir = Join-Path $scriptDir 'seed'

if (-not $env:SUPABASE_SERVICE_ROLE_KEY) {
  $keyFile = Join-Path $env:USERPROFILE '.anime-ranking\service_role.key'
  if (Test-Path $keyFile) {
    $env:SUPABASE_SERVICE_ROLE_KEY = (Get-Content $keyFile -Raw).Trim()
  } else {
    Write-Error "SUPABASE_SERVICE_ROLE_KEY assente e file non trovato: $keyFile"
    exit 1
  }
}
if (-not $env:SUPABASE_URL) {
  $env:SUPABASE_URL = 'https://sjbstiexythmapxmrfyp.supabase.co'
}

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { $node = 'C:\Program Files\nodejs\node.exe' }
if (-not (Test-Path $node)) {
  Write-Error "node non trovato (PATH o $node)"
  exit 1
}

$logDir = Join-Path $env:LOCALAPPDATA 'anime-ranking\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ('harvest-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

Push-Location $seedDir
try {
  & $node 'harvest_animeunity.js' *>> $logFile
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
