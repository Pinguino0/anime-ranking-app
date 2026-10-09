# ============================================================================
# register-weekly-harvest.ps1 - registra la task settimanale in Task Scheduler
# ============================================================================
#
# Crea (o aggiorna) la task "AnimeUnity sitemap-diff" che esegue
# weekly-harvest.ps1 ogni lunedi' alle 03:17, con avvio recuperato se l'orario
# e' stato saltato (-StartWhenAvailable). Non richiede privilegi di
# amministratore: la task gira nel contesto dell'utente corrente.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File register-weekly-harvest.ps1
#
# Per rimuoverla:
#   Unregister-ScheduledTask -TaskName 'AnimeUnity sitemap-diff' -Confirm:$false
# ============================================================================

$ErrorActionPreference = 'Stop'

$taskName = 'AnimeUnity sitemap-diff'
$runner = Join-Path $PSScriptRoot 'weekly-harvest.ps1'
if (-not (Test-Path $runner)) {
  throw "runner non trovato: $runner"
}

$action = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $runner)

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 3:17am

$settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -DontStopOnIdleEnd `
  -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
  -MultipleInstances IgnoreNew

Register-ScheduledTask `
  -TaskName $taskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Description 'Diff settimanale della sitemap AnimeUnity verso provider_anime_index.' `
  -Force | Out-Null

Write-Host "Task '$taskName' registrata."
Get-ScheduledTask -TaskName $taskName |
  Select-Object TaskName, State |
  Format-Table | Out-String |
  Write-Host
