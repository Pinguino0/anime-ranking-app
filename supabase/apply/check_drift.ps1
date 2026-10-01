param(
  [string]$ProjectRef = 'sjbstiexythmapxmrfyp',
  [string]$Pat        = $env:SUPABASE_PAT
)

# Confronto fra i corpi di funzione scritti nelle migration e quelli presenti
# nel DB remoto. Serve a capire se il database e stato allineato ai file: dopo
# un'applicazione manuale tramite Management API e facile che una funzione
# resti indietro senza che nessuno se ne accorga.
#
# Uso (Windows PowerShell):
#   $env:SUPABASE_PAT = 'sbp_...'
#   & ".\supabase\apply\check_drift.ps1"
#
# Nota: il confronto e per NOME, non per firma. Le firme nei file usano la
# sintassi del DDL (uuid[]) mentre pg_get_function_identity_arguments usa il
# formato canonico (_group_id uuid): abbinarle richiederebbe un parser delle
# firme e produrrebbe falsi positivi. Un nome con piu' overload viene
# confrontato come insieme di corpi.

$ErrorActionPreference = 'Stop'

if (-not $Pat) {
  throw 'PAT mancante: imposta $env:SUPABASE_PAT prima di eseguire lo script.'
}

$migrationsDir = Join-Path $PSScriptRoot '..\migrations'
$files = Get-ChildItem -LiteralPath $migrationsDir -Filter '*.sql' | Sort-Object Name

# --- Normalizzazione ------------------------------------------------------
# Tolgo i commenti e collasso gli spazi: due corpi equivalenti scritti con
# indentazione diversa devono risultare identici.
function Normalize-Body([string]$body) {
  $b = [regex]::Replace($body, '--[^\n]*', ' ')
  $b = [regex]::Replace($b, '/\*.*?\*/', ' ', 'Singleline')
  $b = [regex]::Replace($b, '\s+', ' ')
  return $b.Trim()
}

# --- Estrazione dai file --------------------------------------------------
$fileBodies = @{}

foreach ($file in $files) {
  $text = [System.IO.File]::ReadAllText($file.FullName)

  $pattern = '(?s)create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)\s*\(.*?\)\s*returns\s+.*?\bas\s+(\$\$.*?\$\$|''(?:[^'']|'''')*'')'
  foreach ($m in [regex]::Matches($text, $pattern)) {
    $name = $m.Groups[1].Value
    $raw = $m.Groups[2].Value

    if ($raw.StartsWith('$$')) { $body = $raw.Substring(2, $raw.Length - 4) }
    else { $body = $raw.Trim("'") -replace "''", "'" }

    $norm = Normalize-Body $body
    if (-not $fileBodies.ContainsKey($name)) { $fileBodies[$name] = New-Object 'System.Collections.Generic.HashSet[string]' }
    [void]$fileBodies[$name].Add($norm)
  }
}

Write-Output ("funzioni trovate nei file: {0}" -f $fileBodies.Count)

# --- Lettura dal DB -------------------------------------------------------
$query = @"
select p.proname, p.prosrc
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f'
 order by p.proname;
"@

$headers = @{ Authorization = "Bearer $Pat"; 'Content-Type' = 'application/json' }
$body    = @{ query = $query } | ConvertTo-Json -Compress
$uri     = "https://api.supabase.com/v1/projects/$ProjectRef/database/query"

$response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers `
  -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 240

$dbBodies = @{}
foreach ($row in $response) {
  $name = [string]$row.proname
  if (-not $dbBodies.ContainsKey($name)) { $dbBodies[$name] = New-Object 'System.Collections.Generic.HashSet[string]' }
  [void]$dbBodies[$name].Add((Normalize-Body ([string]$row.prosrc)))
}

Write-Output ("funzioni trovate nel DB:  {0}" -f $dbBodies.Count)
Write-Output ''

# --- Confronto ------------------------------------------------------------
# Gli oggetti di piattaforma non sono definiti dal progetto: non sono drift.
$platform = @('rls_auto_enable')

$drift = @()
foreach ($name in ($fileBodies.Keys | Sort-Object)) {
  if ($platform -contains $name) { continue }
  if (-not $dbBodies.ContainsKey($name)) {
    $drift += [pscustomobject]@{ Funzione = $name; Problema = 'assente nel DB' }
    continue
  }
  $same = $false
  foreach ($candidate in $fileBodies[$name]) {
    if ($dbBodies[$name].Contains($candidate)) { $same = $true; break }
  }
  if (-not $same) {
    $drift += [pscustomobject]@{ Funzione = $name; Problema = 'corpo diverso' }
  }
}

if ($drift.Count -eq 0) {
  Write-Output 'DRIFT: nessuno. File e DB allineati.'
} else {
  Write-Output ('DRIFT: {0} funzioni non allineate' -f $drift.Count)
  $drift | Format-Table -AutoSize | Out-String | Write-Output
}

# --- Funzioni presenti solo nel DB ---------------------------------------
# Non sono per forza un errore: trigger di supporto creati fuori dalle
# migration, o helper di piattaforma. Si segnala per revisione.
$onlyDb = $dbBodies.Keys | Where-Object { -not $fileBodies.ContainsKey($_) -and $platform -notcontains $_ } | Sort-Object
if ($onlyDb.Count -gt 0) {
  Write-Output ''
  Write-Output 'presenti solo nel DB (verifica manuale):'
  $onlyDb | ForEach-Object { Write-Output "  $_" }
}