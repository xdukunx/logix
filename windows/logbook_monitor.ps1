param([switch]$Once)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'logbook_common.ps1')
Ensure-LogbookDirs

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\MindLabReportLogbookMonitor', [ref]$created)
if (-not $created) {
    Write-LogbookInfo 'Monitor already running; exiting duplicate instance.'
    exit 0
}

Write-LogbookInfo "Monitor started. User=$env:USERNAME PID=$PID"

function Invoke-InitialPopupOrTimer {
    if (Close-StaleLogbookSessionIfAny) {
        Start-LogbookPopup | Out-Null
        return
    }
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
# NOTE: this scriptblock runs as a PSEventJob (Register-ObjectEvent), a
# different execution context than the rest of this script. Deliberately
# not calling functions from logbook_common.ps1 here (e.g.
# Test-LogbookPopupRunning) — only built-in cmdlets — so this doesn't
# depend on cross-scope function resolution that's awkward to verify for a
# background-thread-raised .NET event. A silent failure here would mean
# the sign-in prompt never appears at all on unlock, which is worse than
# the bug this guard exists to fix.
$action = {
    $reason = $Event.SourceEventArgs.Reason.ToString()
    $stamp = (Get-Date).ToString('o')
    try { "$stamp INFO: SessionSwitch reason=$reason" | Out-File -FilePath $Global:ErrorLog -Append -Encoding UTF8 } catch {}
    if ($reason -in @('SessionLock','ConsoleDisconnect','RemoteDisconnect','SessionLogoff')) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_end.ps1'),'-Reason','END') | Out-Null
    } elseif ($reason -in @('SessionUnlock','ConsoleConnect','RemoteConnect','SessionLogon')) {
        # Don't stack a second popup on top of one the user already left
        # open unanswered (e.g. opened it, then locked the screen with
        # Win+L without filling the form). The existing window is Topmost,
        # so it simply reappears once the desktop is visible again.
        $alreadyShowing = $false
        try {
            $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and $_.CommandLine -match 'logbook_popup\.ps1'
            }
            $alreadyShowing = (($procs | Measure-Object).Count -gt 0)
        } catch {}
        if (-not $alreadyShowing) {
            Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_popup.ps1'),'-ForceNew') | Out-Null
        } else {
            try { "$stamp INFO: skipped spawning popup, one is already open" | Out-File -FilePath $Global:ErrorLog -Append -Encoding UTF8 } catch {}
        }
    }
}

try {
    Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionSwitch -SourceIdentifier MindLabLogbookSessionSwitch -Action $action | Out-Null
} catch {
    Write-LogbookError "Register session switch failed: $($_.Exception.Message)"
}

# SessionSwitch's SessionLogoff reason covers an explicit interactive sign-out,
# but does not reliably fire for a plain power Shut Down/Restart while a user
# is logged in. SessionEnding is raised from the WM_QUERYENDSESSION broadcast
# Windows sends before tearing the session down, so it catches that case too.
# Best-effort only -- Close-StaleLogbookSessionIfAny above is the guaranteed
# backstop if this doesn't finish before Windows kills the process tree.
$endingAction = {
    $reason = $Event.SourceEventArgs.Reason.ToString()
    $stamp = (Get-Date).ToString('o')
    try { "$stamp INFO: SessionEnding reason=$reason" | Out-File -FilePath $Global:ErrorLog -Append -Encoding UTF8 } catch {}
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_end.ps1'),'-Reason','END') | Out-Null
}
try {
    Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionEnding -SourceIdentifier MindLabLogbookSessionEnding -Action $endingAction | Out-Null
} catch {
    Write-LogbookError "Register session ending failed: $($_.Exception.Message)"
}

# Sleep/hibernate (S3/S4) doesn't raise SessionSwitch's Lock/Unlock at all on
# machines where "require sign-in on wake" is off (common on personal
# laptops) -- the session file simply survives the whole suspend untouched,
# and since its elapsed time is wall-clock (now - start_time), the sleep
# duration silently counts as session time too. This was observed as an
# 8-hour-old timer on a laptop the user had just woken up, not rebooted --
# LastBootUpTime predated session start, so the reboot-based
# Close-StaleLogbookSessionIfAny correctly stayed quiet; this is a different
# gap. PowerModeChanged fires on the actual OS power transition regardless of
# lock policy, so treat Resume exactly like SessionSwitch's Unlock branch
# below: reuse -ForceNew, which already closes a stale session (AUTO_FINISH)
# before prompting fresh. Same deliberate no-cross-scope-function-call
# constraint as $action above -- built-in cmdlets only.
$powerAction = {
    $mode = $Event.SourceEventArgs.Mode
    $stamp = (Get-Date).ToString('o')
    try { "$stamp INFO: PowerModeChanged mode=$mode" | Out-File -FilePath $Global:ErrorLog -Append -Encoding UTF8 } catch {}
    if ($mode -eq [Microsoft.Win32.PowerModes]::Resume) {
        $alreadyShowing = $false
        try {
            $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and $_.CommandLine -match 'logbook_popup\.ps1'
            }
            $alreadyShowing = (($procs | Measure-Object).Count -gt 0)
        } catch {}
        if (-not $alreadyShowing) {
            Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_popup.ps1'),'-ForceNew') | Out-Null
        }
    }
}
try {
    Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName PowerModeChanged -SourceIdentifier MindLabLogbookPowerModeChanged -Action $powerAction | Out-Null
} catch {
    Write-LogbookError "Register power mode changed failed: $($_.Exception.Message)"
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

    # Safety net: logbook_popup.ps1 gates Task Manager while it's showing and
    # restores it in a `finally` block, but a `finally` doesn't run if the
    # popup process is force-killed (the exact scenario this gate exists
    # for). If that marker is still around with no popup actually running,
    # the user would otherwise be locked out of Task Manager indefinitely.
    try {
        $staleMarker = Join-Path $Global:StateDir 'taskmgr_prev_value.txt'
        if ((Test-Path $staleMarker) -and -not (Test-LogbookPopupRunning)) {
            Set-TaskManagerDisabled -Disabled $false
        }
    } catch { Write-LogbookError "Task Manager watchdog failed: $($_.Exception.Message)" }
}
