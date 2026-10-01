<#
    Rigenera i chunk da incollare nel SQL Editor di Supabase a partire dai
    file in ../migrations.

    I chunk erano prima copie manuali: dopo ogni correzione a una migration
    restavano indietro e si applicava codice vecchio. Generandoli qui, il
    contenuto segue sempre i file.

    I file in migrations/ NON sono idempotenti (nessun "create table if not
    exists"): rieseguire una parte gia' applicata fallisce. Serve un database
    pulito, oppure eseguire solo la singola funzione modificata.

    Unica eccezione: 018 e' rieseguibile perche' droppa con "if exists" le due
    funzioni che poi ricrea. Serve al DB remoto, dove esisteva gia' una versione
    di prova con i parametri chiamati diversamente e "create or replace" non
    poteva rinominarli (errore 42P13).

    Uso (da supabase/apply):  pwsh ./build_chunks.ps1
#>
$ErrorActionPreference = 'Stop'

$applyDir = $PSScriptRoot
$migDir   = Join-Path (Split-Path $applyDir -Parent) 'migrations'

if (-not (Test-Path -LiteralPath $migDir)) {
    throw "Cartella migrations non trovata: $migDir"
}

# Raggruppamenti per file interi: ogni parte corrisponde a un insieme di
# migration complete, quindi e' leggibile e verificabile. Le dimensioni sono
# tenute sotto ~30 KB per non far rallentare il SQL Editor.
$groups = @(
    @{ Name = 'parte1'; Files = @('001_foundations.sql', '002_profiles.sql', '003_groups.sql', '004_friendships.sql') }
    @{ Name = 'parte2'; Files = @('005_anime.sql', '006_ratings.sql', '007_watchlists.sql', '008_comments.sql') }
    @{ Name = 'parte3'; Files = @('009_activities.sql', '010_achievements.sql', '011_notifications.sql') }
    @{ Name = 'parte4'; Files = @('012_tournaments.sql', '013_duels.sql') }
    @{ Name = 'parte5'; Files = @('014_ranking_and_stats.sql') }
    @{ Name = 'parte6'; Files = @('015_account_admin_elo_storage.sql', '016_realtime_and_audit.sql', '017_privileges_hardening.sql') }
@{ Name = 'parte7'; Files = @('018_transfer_group_ownership.sql') }
)

$header = @"
-- ============================================================================
-- GENERATO AUTOMATICAMENTE da supabase/apply/build_chunks.ps1
-- Non editare questo file a mano: modifica ../migrations e rilancia lo script.
--
-- Applicare le parti in ordine (parte1 -> parte7) su un database vuoto.
-- 018 sta in parte7 e va applicata DOPO 017: la funzione che crea si fa
-- revocare gli execute a chi non deve chiamarla, quindi ricrearla prima
-- lascerebbe in piedi i privilegi sbagliati.
-- Ogni parte viene eseguita in una transazione dal SQL Editor: se una
-- dichiarazione fallisce, l'intera parte viene annullata.
-- ============================================================================

"@

foreach ($g in $groups) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append($header)

    foreach ($f in $g.Files) {
        $path = Join-Path $migDir $f
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Migration non trovata: $path"
        }
        [void]$sb.AppendLine("`n-- >>> $f <<<`n")
        [void]$sb.AppendLine([System.IO.File]::ReadAllText($path))
    }

    $out = Join-Path $applyDir "$($g.Name).sql"
    # UTF-8 senza BOM: il BOM all'inizio di uno script SQL viene interpretato
    # come carattere dal parser e blocca l'esecuzione.
    [System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
    "{0,-10} {1,7} KB  <- {2}" -f $g.Name, [math]::Round((Get-Item $out).Length / 1KB, 1), ($g.Files -join ', ')
}

# apply_all.sql: comodo per la CLI / psql, non per il SQL Editor (147 KB).
$all = [System.Text.StringBuilder]::new()
[void]$all.Append($header)
[void]$all.AppendLine("Apply with: supabase db push, or psql -f apply_all.sql")
[void]$all.AppendLine("Per il SQL Editor usare le singole parti: sono piu' piccole e tracciabili.")
foreach ($f in Get-ChildItem -LiteralPath $migDir -Filter '*.sql' | Sort-Object Name) {
    [void]$all.AppendLine("`n-- >>> $($f.Name) <<<`n")
    [void]$all.AppendLine([System.IO.File]::ReadAllText($f.FullName))
}
$outAll = Join-Path $applyDir 'apply_all.sql'
[System.IO.File]::WriteAllText($outAll, $all.ToString(), (New-Object System.Text.UTF8Encoding $false))
"{0,-10} {1,7} KB  <- tutte le migration in ordine" -f 'apply_all', [math]::Round((Get-Item $outAll).Length / 1KB, 1)