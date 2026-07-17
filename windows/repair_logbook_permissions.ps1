# One-time repair for machines where the logbook state files ended up owned by
# BUILTIN\Administrators (created by a monitor/popup that ran elevated -- an old
# scheduled task registered with -RunLevel Highest, or a manual elevated restart
# helper). While that ownership is in place, the normal non-elevated runtime
# cannot delete session.json, so ending a session (SELESAI / END) silently fails:
# the session "zombies", its timer keeps counting (even across days), and the
# next unlock shows no sign-in form because a session is still on disk.
#
# Run this ONCE from an elevated PowerShell, signed in as the normal lab user
# (it self-elevates via UAC if needed -- accept the prompt for the SAME account,
# do not switch to a different admin user, or the ACLs get granted to the wrong
# identity). It:
#   1. stops the monitor/timer/popup (elevated can stop admin-owned processes),
#   2. grants the interactive user Modify + ownership on the state dir + files,
#   3. clears the stuck session.json/timer.pid and stale markers,
#   4. re-registers the monitor scheduled task at RunLevel Limited (non-elevated),
#   5. relaunches the monitor via the task so it runs as the plain user again.
param([string]$TaskUser = "$env:USERDOMAIN\$env:USERNAME")
$ErrorActionPreference = 'Continue'
Set-ExecutionPolicy -Scope Process Bypass -Force -ErrorAction SilentlyContinue

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights required. Relaunching with UAC...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-TaskUser',$TaskUser)
    exit 0
}

. 'C:\Program Files\Logix\logbook_common.ps1'
Ensure-LogbookDirs
Write-Host "Repairing logbook permissions for $TaskUser..." -ForegroundColor Cyan

# 1. Stop the running monitor/timer/popup so nothing recreates or holds state.
foreach ($pattern in @('logbook_monitor\.ps1','logbook_timer\.ps1','logbook_popup\.ps1')) {
    foreach ($p in @(Get-ProcessByCommandPattern $pattern)) {
        if ([int]$p.ProcessId -ne [int]$PID) {
            Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
            Write-Host "  stopped PID $($p.ProcessId) ($pattern)"
        }
    }
}

# 2. Grant the interactive user Modify on the state dir + existing children, and
#    hand ownership back so this never recurs.
Grant-LogbookStateDirAccess
try {
    $acct = New-Object System.Security.Principal.NTAccount($TaskUser)
    foreach ($path in @($Global:StateDir) + @(Get-ChildItem -Path $Global:StateDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
        try {
            $acl = Get-Acl -Path $path
            $acl.SetOwner($acct)
            Set-Acl -Path $path -AclObject $acl
        } catch { Write-Host "  owner reset skipped for $path : $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
    Write-Host "  ownership set to $TaskUser" -ForegroundColor Green
} catch { Write-Host "  ownership reset failed: $($_.Exception.Message)" -ForegroundColor Red }

# 3. Clear the stuck session and stale runtime markers (now deletable).
foreach ($f in @('session.json','timer.pid','popup.lock','workstation_locked.flag','incoming_message.json','taskmgr_prev_value.txt')) {
    $full = Join-Path $Global:StateDir $f
    if (Test-Path $full) {
        Remove-Item $full -Force -ErrorAction SilentlyContinue
        if (Test-Path $full) { Write-Host "  COULD NOT remove $f" -ForegroundColor Red } else { Write-Host "  removed $f" }
    }
}
# Make sure the Task Manager gate isn't left disabled from a killed popup.
Set-TaskManagerDisabled -Disabled $false

# 4. Re-register the monitor task at RunLevel Limited (non-elevated) so future
#    runs stay user-owned. Mirrors install_logbook_tasks.ps1.
try {
    # SID, not the $TaskUser name string: on a Microsoft-Account-linked sign-in
    # (common on a personal laptop, vs. a domain-joined lab workstation),
    # "$env:USERDOMAIN\$env:USERNAME" often can't be resolved by Task
    # Scheduler's name lookup ("No mapping between account names and security
    # IDs was done", 0x80070534). A SID needs no name resolution. $TaskUser
    # itself stays name-based above, since NTAccount/ownership needs a name.
    $taskUserSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Program Files\Logix\logbook_monitor.ps1"'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUserSid
    # Mirrors install_logbook_tasks.ps1: 30-min self-heal trigger, no
    # execution time limit, auto-restart on failure -- see the comments there.
    $healTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $taskUserSid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'MindLab Report Logbook Monitor' -Action $action -Trigger @($trigger, $healTrigger) -Principal $taskPrincipal -Settings $settings -Force | Out-Null
    Write-Host '  monitor task re-registered at RunLevel Limited' -ForegroundColor Green
} catch { Write-Host "  task re-registration failed: $($_.Exception.Message)" -ForegroundColor Red }

# 5. Launch the monitor via the task so it runs NON-elevated (do NOT Start-Process
#    it from here -- this process is elevated and the child would inherit that).
try {
    Start-ScheduledTask -TaskName 'MindLab Report Logbook Monitor'
    Write-Host '  monitor started (non-elevated) via scheduled task' -ForegroundColor Green
} catch { Write-Host "  could not start monitor task: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host 'Repair complete. Lock/unlock the workstation to confirm the sign-in form appears.' -ForegroundColor Cyan
