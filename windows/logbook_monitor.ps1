param([switch]$Once)
$ErrorActionPreference = 'Stop'
. 'C:\lab\logbook_common.ps1'
Ensure-LogbookDirs

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\MindLabReportLogbookMonitor', [ref]$created)
if (-not $created) {
    Write-LogbookInfo 'Monitor already running; exiting duplicate instance.'
    exit 0
}

Write-LogbookInfo "Monitor started. User=$env:USERNAME PID=$PID"

function Invoke-InitialPopupOrTimer {
    if (Test-Path $Global:SessionFile) {
        $s = Get-ActiveLogbookSession
        if ($s -and $s.session_id) { Start-LogbookTimer -SessionId $s.session_id | Out-Null }
    } else {
        Start-LogbookPopup | Out-Null
    }
}

if ($Once) {
    Invoke-InitialPopupOrTimer
    exit 0
}

try {
    Add-Type -AssemblyName Microsoft.Win32.SystemEvents
} catch {}

# Initial session gate at logon.
Start-Sleep -Seconds 2
Invoke-InitialPopupOrTimer

# SessionSwitch action intentionally spawns helper scripts instead of calling WPF in this hidden monitor process.
$action = {
    $reason = $Event.SourceEventArgs.Reason.ToString()
    $stamp = (Get-Date).ToString('o')
    try { "$stamp INFO: SessionSwitch reason=$reason" | Out-File -FilePath 'C:\lab\logbook_error.log' -Append -Encoding UTF8 } catch {}
    if ($reason -in @('SessionLock','ConsoleDisconnect','RemoteDisconnect','SessionLogoff')) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_end.ps1','-Reason','END') | Out-Null
    } elseif ($reason -in @('SessionUnlock','ConsoleConnect','RemoteConnect','SessionLogon')) {
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_popup.ps1','-ForceNew') | Out-Null
    }
}

try {
    Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionSwitch -SourceIdentifier MindLabLogbookSessionSwitch -Action $action | Out-Null
} catch {
    Write-LogbookError "Register session switch failed: $($_.Exception.Message)"
}

try {
    if (Test-Path $Global:SessionFile) { Send-LogbookHeartbeat -Status 'ACTIVE' } else { Send-LogbookHeartbeat -Status 'LOCKED' }
} catch {}

while ($true) {
    Start-Sleep -Seconds 30
    try {
        if (Test-Path $Global:SessionFile) {
            Send-LogbookHeartbeat -Status 'ACTIVE'
            # Keep timer alive if session is active; do not open new popup from heartbeat.
            $timers = Get-ProcessByCommandPattern 'logbook_timer\.ps1'
            if (($timers | Measure-Object).Count -eq 0) {
                $s = Get-ActiveLogbookSession
                if ($s -and $s.session_id) { Start-LogbookTimer -SessionId $s.session_id | Out-Null }
            }
        } else {
            Send-LogbookHeartbeat -Status 'LOCKED'
        }
    } catch { Write-LogbookError "Monitor heartbeat failed: $($_.Exception.Message)" }
}
