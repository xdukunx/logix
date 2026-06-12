param([string]$Reason = 'END')
$ErrorActionPreference = 'Stop'
. 'C:\lab\logbook_common.ps1'
Ensure-LogbookDirs
try {
    Close-ActiveLogbookSession -Reason $Reason | Out-Null
} catch {
    Write-LogbookError "End failed: $($_.Exception.Message)"
    Stop-LogbookTimers
}
