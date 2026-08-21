# Fully remove the Logix agent from this machine -- the clean "wipe the old
# install" step before reinstalling (e.g. after the server endpoint changed).
# Removes: the scheduled task, the HKCU Run fallback, the program files, the
# runtime state, and (unless -KeepConfig) the server config. Re-enables Task
# Manager in case a popup left it gated. Idempotent: safe to run even if parts
# are already gone.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\uninstall_logbook.ps1
#
# Flags:
#   -KeepConfig   Preserve %ProgramData%\Logix\config.env (LOGIX_SERVER_URL, API
#                 key, device name) so a reinstall keeps the same server binding.
#
# Does NOT uninstall AnyDesk (a separate app). After this, reinstall + point at
# the new server with:
#   install_logbook_tasks.ps1 -NonInteractive -ServerUrl <url> -ServerApiKey <key> -DeviceName <name>
param([switch]$KeepConfig)
$ErrorActionPreference = 'Continue'

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'This uninstaller must run elevated (it removes C:\Program Files\Logix and a machine scheduled task).' -ForegroundColor Yellow
    Write-Host 'Open PowerShell as Administrator, then re-run this script.' -ForegroundColor Yellow
    exit 1
}

$installDir = 'C:\Program Files\Logix'
$legacyDir  = 'C:\lab'
$stateDir   = Join-Path $env:ProgramData 'Logix'
# Pre-rename location. Still removed so uninstalling a machine that was
# never upgraded (or whose migration could not move a locked file) does
# not leave state behind.
$oldStateDir = Join-Path $env:ProgramData 'MindLabLogbook'
$configDir  = Join-Path $env:ProgramData 'Logix'
$perUserCfg = Join-Path $env:APPDATA 'Logix'
$oldPerUserCfg = Join-Path $env:APPDATA 'MindLabLogbook'

Write-Host 'Uninstalling the Logix agent...' -ForegroundColor Cyan

# 1. Graceful shutdown via the installed common module while it still exists:
#    close any live session, stop timers, kill the monitor, and -- important --
#    re-enable Task Manager so a wiped machine is never left with it disabled.
$common = Join-Path $installDir 'logbook_common.ps1'
if (Test-Path $common) {
    try {
        . $common
        try { Close-ActiveLogbookSession -Reason 'AUTO_FINISH' | Out-Null } catch {}
        try { Stop-LogbookTimers } catch {}
        try { Set-TaskManagerDisabled -Disabled $false } catch {}
        try {
            foreach ($p in (Get-ProcessByCommandPattern 'logbook_monitor\.ps1')) {
                if ([int]$p.ProcessId -ne [int]$PID) { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue }
            }
        } catch {}
        Write-Host '  Stopped agent processes; Task Manager re-enabled.' -ForegroundColor Green
    } catch { Write-Host "  (graceful shutdown skipped: $($_.Exception.Message))" -ForegroundColor DarkGray }
}

# Belt-and-suspenders: clear the Task Manager policy directly too, in case the
# module wasn't present.
try {
    $tmKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
    if (Test-Path $tmKey) { Remove-ItemProperty -Path $tmKey -Name 'DisableTaskMgr' -ErrorAction SilentlyContinue }
} catch {}

# Kill any stray popup/timer hosts still holding a WPF window. No
# Name='powershell.exe' filter: since the conhost --headless launch wrapper,
# each agent process is a conhost.exe + powershell.exe pair and BOTH carry the
# script name on their command line -- filtering to powershell would leave the
# conhost wrappers invisible to this fallback (which must work even when
# logbook_common.ps1 is already gone).
try {
    foreach ($pat in @('logbook_popup\.ps1', 'logbook_timer\.ps1', 'logbook_monitor\.ps1')) {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $pat -and [int]$_.ProcessId -ne [int]$PID } |
            ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
    }
} catch {}

# 2. Scheduled tasks (current + legacy names).
foreach ($t in @(
    'Logix Agent Monitor',
    'MindLab Report Logbook Monitor',
    'MindLab Report Logbook Start', 'MindLab Report Logbook End',
    'Lab Logbook Start', 'Lab Logbook End')) {
    try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}
Write-Host '  Removed scheduled tasks.' -ForegroundColor Green

# 3. HKCU Run fallback.
foreach ($runValue in @('LogixAgentMonitor', 'MindLabReportLogbookMonitor')) {
    try {
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
            -Name $runValue -ErrorAction SilentlyContinue
    } catch {}
}

# 4. Files: program dir, legacy dir, runtime state, per-user config.
foreach ($d in @($installDir, $legacyDir, $stateDir, $oldStateDir, $perUserCfg, $oldPerUserCfg)) {
    if (Test-Path $d) {
        try { Remove-Item -Path $d -Recurse -Force -ErrorAction Stop; Write-Host "  Removed $d" -ForegroundColor Green }
        catch { Write-Host "  Could not fully remove $d ($($_.Exception.Message))" -ForegroundColor Yellow }
    }
}

# 5. Server config (%ProgramData%\Logix): kept with -KeepConfig so a reinstall
#    reuses the same LOGIX_SERVER_URL / API key / device name.
if ($KeepConfig) {
    Write-Host "  Kept server config at $configDir (-KeepConfig)." -ForegroundColor Cyan
} elseif (Test-Path $configDir) {
    try { Remove-Item -Path $configDir -Recurse -Force -ErrorAction Stop; Write-Host "  Removed $configDir" -ForegroundColor Green }
    catch { Write-Host "  Could not fully remove $configDir ($($_.Exception.Message))" -ForegroundColor Yellow }
}

Write-Host ''
Write-Host 'Logix agent uninstalled.' -ForegroundColor Green
Write-Host 'To reinstall and point at the new server, run (elevated):' -ForegroundColor Cyan
Write-Host '  install_logbook_tasks.ps1 -NonInteractive -ServerUrl <url> -ServerApiKey <key> -DeviceName <name>' -ForegroundColor DarkGray
