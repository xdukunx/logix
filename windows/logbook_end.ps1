param([string]$Reason = 'END')
$ErrorActionPreference = 'Stop'
. 'C:\Program Files\Logix\logbook_common.ps1'
Ensure-LogbookDirs
try {
    Close-ActiveLogbookSession -Reason $Reason | Out-Null
} catch {
    Write-LogbookError "End failed: $($_.Exception.Message)"
    Stop-LogbookTimers
}
