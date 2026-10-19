# -EndTime back-dates the close (ISO 8601). logix.exe agent passes it when it
# hands a close to this script (the WSL bridge), for a session that predates
# the last boot or outlived the session cap.
param([string]$Reason = 'END', [string]$EndTime = '')
$ErrorActionPreference = 'Stop'
. 'C:\Program Files\Logix\logbook_common.ps1'
Ensure-LogbookDirs
try {
    if ($EndTime) {
        Close-ActiveLogbookSession -Reason $Reason -EndTime ([datetime]$EndTime) | Out-Null
    } else {
        Close-ActiveLogbookSession -Reason $Reason | Out-Null
    }
} catch {
    Write-LogbookError "End failed: $($_.Exception.Message)"
    Stop-LogbookTimers
}
