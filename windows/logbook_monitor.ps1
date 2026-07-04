param([switch]$Once)
$ErrorActionPreference = 'Stop'
. 'C:\lab\logbook_common.ps1'
Ensure-LogbookDirs

# Assume unlocked at monitor start (Task Scheduler's AtLogOn trigger only
# fires into an interactive, unlocked session) -- a flag left over from
# before a reboot would otherwise wrongly suppress idle-timeout on a brand
# new, actively-used session.
$Global:LockedFlagPath = Join-Path $Global:StateDir 'workstation_locked.flag'
Remove-Item $Global:LockedFlagPath -Force -ErrorAction SilentlyContinue

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
    try { "$stamp INFO: SessionSwitch reason=$reason" | Out-File -FilePath 'C:\lab\logbook_error.log' -Append -Encoding UTF8 } catch {}
    $lockedFlag = 'C:\ProgramData\MindLabLogbook\workstation_locked.flag'
    if ($reason -in @('ConsoleDisconnect','RemoteDisconnect','SessionLogoff')) {
        # A real departure signal (user switch, RDP disconnect, sign-out) --
        # unlike a plain lock, ends the session outright.
        Remove-Item $lockedFlag -Force -ErrorAction SilentlyContinue
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_end.ps1','-Reason','END') | Out-Null
    } elseif ($reason -eq 'SessionLock') {
        # Locking is a pause, not a departure -- product decision: the
        # session stays open across any lock/sleep duration and just
        # resumes on unlock. Only gates idle-timeout below (see
        # logbook_common.ps1's Get-LogbookIdleSeconds) so a legitimately
        # locked-overnight session is never auto-closed by that check.
        try { '' | Out-File -FilePath $lockedFlag -Force -Encoding UTF8 } catch {}
    } elseif ($reason -in @('SessionUnlock','ConsoleConnect','RemoteConnect','SessionLogon')) {
        Remove-Item $lockedFlag -Force -ErrorAction SilentlyContinue
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
            # Deliberately no -ForceNew: if a session is still open (the
            # normal lock/unlock case) this just resumes its timer with no
            # re-prompt; a fresh popup only appears if no session is on
            # disk (already closed via sign-out/idle-timeout/SELESAI/reboot).
            Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_popup.ps1') | Out-Null
        } else {
            try { "$stamp INFO: skipped spawning popup, one is already open" | Out-File -FilePath 'C:\lab\logbook_error.log' -Append -Encoding UTF8 } catch {}
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
    try { "$stamp INFO: SessionEnding reason=$reason" | Out-File -FilePath 'C:\lab\logbook_error.log' -Append -Encoding UTF8 } catch {}
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_end.ps1','-Reason','END') | Out-Null
}
try {
    Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionEnding -SourceIdentifier MindLabLogbookSessionEnding -Action $endingAction | Out-Null
} catch {
    Write-LogbookError "Register session ending failed: $($_.Exception.Message)"
}

# Sleep/hibernate (S3/S4) doesn't raise SessionSwitch's Lock/Unlock at all on
# machines where "require sign-in on wake" is off (common on personal
# laptops) -- the session file simply survives the whole suspend untouched.
# PowerModeChanged fires on the actual OS power transition regardless of
# lock policy, so it's the only reliable signal on such a machine. Per the
# same "lock/sleep is a pause, not a departure" product decision as
# SessionLock above: Suspend just sets the same locked-flag (gates
# idle-timeout), and Resume behaves exactly like Unlock -- resume the
# existing session's timer with no re-prompt, only showing a fresh popup if
# no session is on disk. Same deliberate no-cross-scope-function-call
# constraint as $action above -- built-in cmdlets only.
$powerAction = {
    $mode = $Event.SourceEventArgs.Mode
    $stamp = (Get-Date).ToString('o')
    try { "$stamp INFO: PowerModeChanged mode=$mode" | Out-File -FilePath 'C:\lab\logbook_error.log' -Append -Encoding UTF8 } catch {}
    $lockedFlag = 'C:\ProgramData\MindLabLogbook\workstation_locked.flag'
    if ($mode -eq [Microsoft.Win32.PowerModes]::Suspend) {
        try { '' | Out-File -FilePath $lockedFlag -Force -Encoding UTF8 } catch {}
    } elseif ($mode -eq [Microsoft.Win32.PowerModes]::Resume) {
        Remove-Item $lockedFlag -Force -ErrorAction SilentlyContinue
        $alreadyShowing = $false
        try {
            $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and $_.CommandLine -match 'logbook_popup\.ps1'
            }
            $alreadyShowing = (($procs | Measure-Object).Count -gt 0)
        } catch {}
        if (-not $alreadyShowing) {
            Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_popup.ps1') | Out-Null
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

    # The only auto-close path left for a session that's neither locked nor
    # slept: genuinely idle with the screen unlocked (forgot to lock, walked
    # away). Gated on workstation_locked.flag -- while locked, duration is
    # irrelevant by product decision (see Close-LogbookSessionAndLock), and
    # GetLastInputInfo would otherwise happily report a locked screen as
    # "idle" too.
    try {
        if ((Test-Path $Global:SessionFile) -and -not (Test-Path $Global:LockedFlagPath)) {
            $idleSec = Get-LogbookIdleSeconds
            $limitSec = Get-LogbookIdleTimeoutSeconds
            if ($null -ne $idleSec -and $idleSec -ge $limitSec) {
                Write-LogbookInfo "Idle timeout reached (${idleSec}s >= ${limitSec}s); auto-closing session."
                Close-ActiveLogbookSession -Reason 'AUTO_CLOSE' | Out-Null
            }
        }
    } catch { Write-LogbookError "Idle timeout check failed: $($_.Exception.Message)" }

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
