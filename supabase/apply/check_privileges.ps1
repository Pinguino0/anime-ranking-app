param(
  [string]$ProjectRef = 'sjbstiexythmapxmrfyp',
  [string]$Pat        = $env:SUPABASE_PAT
)

# Verifica dei privilegi dopo l'applicazione delle migration.
#
# Uso (Windows PowerShell):
#   $env:SUPABASE_PAT = 'sbp_...'
#   .\check_privileges.ps1
#
# Perche' uno script e non le query incollate a mano: il SQL va eseguito dalla
# Management API, non dalla shell. Incollare una query in PowerShell la tratta
# come comando e dice "Il termine 'select' non e' riconosciuto come cmdlet",
# che e' un errore di destinazione e non di SQL.
#
# Cosa controlla, e perche' conta:
#   1. Nessuna funzione eseguibile da anon. Se una RPC di lettura resta aperta,
#      chiunque puo' leggere dati di gruppo senza essere membro.
#   2. Le RPC che il client usa devono restare eseguibili da authenticated, se no
#      l'app smette di funzionare con l'errore "permission denied".
#   3. RLS attiva su tutte le tabelle del progetto. Una tabella senza RLS e'
#      leggibile da chi ha la chiave pubblica anon.
#   4. SECURITY DEFINER con search_path fissato sulle due funzioni che leggono
#      fuori dalle RLS: senza search_path un utente potrebbe costruire un
#      oggetto shadowing e farsi eseguire codice con i privilegi di postgres.

$ErrorActionPreference = 'Stop'

if (-not $Pat) {
  throw 'PAT mancante: imposta $env:SUPABASE_PAT prima di eseguire lo script.'
}

function Invoke-Query([string]$Sql) {
  $body = @{ query = $Sql } | ConvertTo-Json -Compress -Depth 5
  Invoke-RestMethod -Method Post `
    -Uri "https://api.supabase.com/v1/projects/$ProjectRef/database/query" `
    -Headers @{ Authorization = "Bearer $Pat"; 'Content-Type' = 'application/json' } `
    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 240
}

$problems = 0

function Report([bool]$Ok, [string]$Message) {
  if ($Ok) {
    Write-Host "  OK    $Message"
  } else {
    Write-Host "  PROBLEMA  $Message" -ForegroundColor Red
    $script:problems++
  }
}

# --- 1 e 2: privilegi sulle RPC ---------------------------------------------
Write-Host "`nPrivilegi sulle funzioni" -ForegroundColor Cyan

$functions = Invoke-Query @"
select p.proname as name,
       pg_get_function_identity_arguments(p.oid) as args,
       has_function_privilege('anon', p.oid, 'execute') as anon_can_execute,
       has_function_privilege('authenticated', p.oid, 'execute') as auth_can_execute
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
 order by p.proname, args;
"@

$anonOpen = @($functions | Where-Object { $_.anon_can_execute -eq $true })
Report ($anonOpen.Count -eq 0) "nessuna funzione eseguibile da anon (trovate $($anonOpen.Count))"
foreach ($f in $anonOpen) {
  Write-Host "          $($f.name)($($f.args))" -ForegroundColor Red
}

# Le funzioni che il client chiama. Elenco esplicito e non "tutte": cosi' una
# funzione nuova senza grant si vede qui invece di fallire a runtime.
#
# take_ranking_snapshot NON e' in elenco di proposito: scrive in
# ranking_snapshots e la esegue il servizio schedulato, non l'app. Il client
# non deve poterla chiamare, quindi la sua assenza di execute per authenticated
# e' il comportamento voluto. Va elencata in $closedRpcs.
$clientRpcs = @(
  'group_members_list', 'transfer_group_ownership', 'create_group', 'join_group',
  'leave_group', 'kick_member', 'set_member_role', 'regenerate_invite_code',
  'create_group_invite', 'list_group_invites', 'revoke_group_invite',
  'group_ranking', 'group_stats', 'my_ranking', 'special_rankings',
  'rating_distribution', 'personal_stats', 'compare_users', 'compare_summary',
  'next_duel_pair', 'duel_elo', 'create_tournament',
  'delete_tournament', 'cast_tournament_vote', 'resolve_tournament_match',
  'tournament_standings', 'delete_own_account',
  # Blocco episodi (migrazioni 026 e 027).
  'episodes_for_anime', 'episode_sources_list', 'episode_rate'
)

# Funzioni che il client NON deve poter chiamare. La lista serve al contrario
# della precedente: se qualcuno le rendisse eseguibili, e' un buco.
$closedRpcs = @(
  'take_ranking_snapshot'
)

$denied = @($functions | Where-Object { $clientRpcs -contains $_.name -and $_.auth_can_execute -ne $true })
Report ($denied.Count -eq 0) "tutte le RPC del client eseguibili da authenticated (negate: $($denied.Count))"
foreach ($f in $denied) {
  Write-Host "          $($f.name)($($f.args))" -ForegroundColor Red
}

$leaked = @($functions | Where-Object { $closedRpcs -contains $_.name -and $_.auth_can_execute -eq $true })
Report ($leaked.Count -eq 0) "nessuna RPC chiusa e' tornata aperta (aperte: $($leaked.Count))"
foreach ($f in $leaked) {
  Write-Host "          $($f.name)($($f.args))" -ForegroundColor Red
}

# --- 3: RLS -----------------------------------------------------------------
Write-Host "`nRow Level Security" -ForegroundColor Cyan

$noRls = Invoke-Query @"
select c.relname as name
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind = 'r'
   and not c.relrowsecurity
 order by c.relname;
"@

Report (@($noRls).Count -eq 0) "ogni tabella ha RLS attiva (scoperte: $(@($noRls).Count))"
foreach ($t in $noRls) {
  Write-Host "          $($t.name)" -ForegroundColor Red
}

# --- 4: SECURITY DEFINER con search_path fissato ---------------------------
Write-Host "`nFunzioni SECURITY DEFINER" -ForegroundColor Cyan

$definer = Invoke-Query @"
select p.proname as name,
       p.prosecdef as is_definer,
       array_to_string(p.proconfig, ', ') as config
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prosecdef
 order by p.proname;
"@

$loose = @($definer | Where-Object { $_.config -notmatch 'search_path' })
Report ($loose.Count -eq 0) "ogni funzione SECURITY DEFINER fissa il search_path (senza: $($loose.Count))"
foreach ($f in $loose) {
  Write-Host "          $($f.name)" -ForegroundColor Red
}

# --- 5: funzioni presenti solo nel DB --------------------------------------
# check_drift.ps1 segnala gia' i corpi diversi, ma con un conteggio: qui si
# vuole il nome. Una funzione in piu' nel DB che non in un file e' quasi sempre
# un oggetto creato a mano durante i collaudi e mai ripulito. Non e' un
# pericolo immediato, ma resta codice che gira senza che nessuno lo legga, e
# con permessi che non conosciamo.
Write-Host "`nFunzioni nel DB assenti dai file" -ForegroundColor Cyan

$dbOnly = Invoke-Query @"
select p.proname as name,
       pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind = 'f'
   and p.proname <> 'rls_auto_enable'
 order by p.proname, args;
"@

# Il nome si prende solo dopo "create function": agganciare un `function`
# qualsiasi prenderebbe anche le parole dei commenti e dei tipi di ritorno, e i
# falsi positivi nasconderebbero proprio le funzioni da segnalare.
$fileNames = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\migrations') -Filter '*.sql' |
  ForEach-Object {
    [regex]::Matches(
      [IO.File]::ReadAllText($_.FullName),
      'create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)')
  } |
  ForEach-Object { $_.Groups[1].Value } |
  Sort-Object -Unique

$extra = @($dbOnly | Where-Object { $fileNames -notcontains $_.name })
if ($extra.Count -eq 0) {
  Write-Host "  OK    nessuna ($( $dbOnly.Count ) funzioni nel DB, tutte nei file)"
} else {
  Write-Host "  da rivedere: $($extra.Count) funzioni non vengono da nessuna migration" -ForegroundColor Yellow
  foreach ($f in $extra) {
    Write-Host "          $($f.name)($($f.args))"
  }
}

# --- esito ------------------------------------------------------------------
Write-Host ''
if ($problems -eq 0) {
  Write-Host 'TUTTO OK.' -ForegroundColor Green
} else {
  Write-Host "$problems PROBLEMI da sistemare." -ForegroundColor Red
  exit 1
}