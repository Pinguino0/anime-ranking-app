# ============================================================================
# deploy_pwa.ps1 — compila la PWA AnimeRank e prepara la cartella da pubblicare
# ============================================================================
#
# Uso:
#   .\deploy_pwa.ps1
#   .\deploy_pwa.ps1 -SupabaseUrl "https://xxx.supabase.co" -SupabaseKey "sb_publishable_..."
#
# Cosa fa:
#   1. compila Flutter per la Web con le credenziali pubbliche;
#   2. scrive la versione corrente nel service worker (cosi' le cache vecchie
#      spariscono e l'avviso "nuova versione" scatta);
#   3. stampa come provarla in locale.
#
# Per pubblicare NON serve lanciare questo script: c'e' il workflow GitHub
# Actions `.github/workflows/deploy-web-pwa.yml` che lo fa a ogni push.
# Questo script serve a compilare e provare in locale.
# ============================================================================

param(
    [string]$SupabaseUrl = "https://sjbstiexythmapxmrfyp.supabase.co",
    [string]$SupabaseKey = "sb_publishable_JqBGHeAUT068w6-Ex1L8OQ_f6OpCSMc",
    # Solo per l'app Android (bypass operatori mobili). Sul web non ha effetto,
    # ma tenerlo uguale evita build diverse fra le piattaforme.
    [string]$Relay = "https://animerank-relay.titanoeren171.workers.dev"
)

$ErrorActionPreference = "Stop"
$clientDir = Join-Path $PSScriptRoot "client"

Write-Host "=== AnimeRank PWA ===" -ForegroundColor Cyan

# 1. Compila
Write-Host "`n[1/3] Compilazione Flutter Web..." -ForegroundColor Yellow
Push-Location $clientDir
& flutter build web --release --no-tree-shake-icons --no-wasm-dry-run `
    --dart-define=SUPABASE_URL="$SupabaseUrl" `
    --dart-define=SUPABASE_ANON_KEY="$SupabaseKey" `
    --dart-define=ANIMERANK_RELAY="$Relay"

if ($LASTEXITCODE -ne 0) {
    Pop-Location
    Write-Host "ERRORE: compilazione fallita" -ForegroundColor Red
    exit 1
}
Pop-Location

# 2. Versione del service worker
Write-Host "`n[2/3] Versione del service worker..." -ForegroundColor Yellow
$swPath = Join-Path $clientDir "build\web\sw.js"
if (-not (Test-Path $swPath)) {
    Write-Host "ERRORE: sw.js non trovato nella build" -ForegroundColor Red
    exit 1
}
$buildNumber = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$content = Get-Content $swPath -Raw
$content = $content.Replace("__BUILD_NUMBER__", "$buildNumber")
Set-Content $swPath $content -NoNewline
Write-Host "  versione: $buildNumber"

# 3. Riepilogo
$webDir = Join-Path $clientDir "build\web"
Write-Host "`n[3/3] Pronta." -ForegroundColor Green
Write-Host "  Cartella: $webDir" -ForegroundColor White
Write-Host "  Per provarla in locale:" -ForegroundColor White
Write-Host "    cd `"$webDir`"; python -m http.server 8080" -ForegroundColor Gray
Write-Host "    poi apri http://localhost:8080" -ForegroundColor Gray
Write-Host "`n  Per pubblicarla: push su main (GitHub Pages la mette online da sola)." -ForegroundColor White
