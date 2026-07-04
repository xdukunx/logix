param(
    [string]$TaskUser = "$env:USERDOMAIN\$env:USERNAME",
    [switch]$RunNow,
    [switch]$TestPopup,
    [switch]$UseWSL
)
$ErrorActionPreference = 'Stop'

$lab = 'C:\lab'
New-Item -ItemType Directory -Force -Path $lab | Out-Null

# Whether session events log through WSL (lab workstations that already have
# a distro set up for the SSH-side bridge) or the native Python core that
# install/install.py deploys to LOGIX_HOME on every OS. Loaned/rented laptops
# typically have no WSL distro at all, so native is the safer default -- see
# Invoke-WSLLogbook / Test-LogbookUseWSL in logbook_common.ps1.
function Set-LogixConfigValue {
    param([string]$Key, [string]$Value)
    $cfgDir = Join-Path $env:ProgramData 'Logix'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfgPath = Join-Path $cfgDir 'config.env'
    $lines = if (Test-Path $cfgPath) { @(Get-Content $cfgPath) } else { @() }
    $pattern = "^\s*#?\s*(?:export\s+)?$Key\s*="
    $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match $pattern) { $found = $true; "$Key=$Value" } else { $line }
    }
    if (-not $found) { $out += "$Key=$Value" }
    $out | Set-Content -Path $cfgPath -Encoding UTF8
}

$useWsl = $UseWSL.IsPresent
if (-not $PSBoundParameters.ContainsKey('UseWSL')) {
    Write-Host ''
    Write-Host 'Does this machine have WSL set up with a Linux distro for the logging bridge?' -ForegroundColor Cyan
    Write-Host '  Most lab workstations do; loaned/rented laptops usually do not.' -ForegroundColor DarkGray
    $ans = Read-Host 'Use WSL bridge instead of native Python? (y/N)'
    $useWsl = $ans -match '^(y|yes)$'
}
Set-LogixConfigValue -Key 'LOGIX_USE_WSL' -Value $(if ($useWsl) { '1' } else { '0' })
Write-Host "Logging bridge: $(if ($useWsl) { 'WSL' } else { 'native Python (requires install/install.py to have deployed the core to this machine already)' })" -ForegroundColor Green

# Copy scripts from installer source folder to C:\lab
$files = @(
    'logbook_common.ps1',
    'logbook_popup.ps1',
    'logbook_monitor.ps1',
    'logbook_timer.ps1',
    'logbook_end.ps1',
    'logbook_setup.ps1',
    'cleanup_logbook_state.ps1',
    'debug_logbook_detection.ps1'
)
foreach ($f in $files) {
    $src = Join-Path $PSScriptRoot $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $lab $f) -Force
    }
}

. 'C:\lab\logbook_common.ps1'
Ensure-LogbookDirs

Write-Host 'Logix Report Logbook installer' -ForegroundColor Cyan
Write-Host 'User:' $TaskUser

# One-time grant so the sign-in popup can gate Task Manager at runtime even
# on a standard (non-admin) account — this install step runs elevated, the
# scheduled task it registers below does not. See
# Grant-LogbookTaskMgrGateAccess in logbook_common.ps1 for why this is safe
# and narrowly scoped.
Grant-LogbookTaskMgrGateAccess

# Clean the old direct Start/End tasks that caused duplicate stacks.
foreach ($t in @('MindLab Report Logbook Start','MindLab Report Logbook End','Lab Logbook Start','Lab Logbook End')) {
    try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

# Kill old timer/monitor instances before installing the single monitor model.
try {
    Stop-LogbookTimers
    $monitors = Get-ProcessByCommandPattern 'logbook_monitor\.ps1'
    foreach ($p in $monitors) {
        if ([int]$p.ProcessId -ne [int]$PID) { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue }
    }
} catch {}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\lab\logbook_monitor.ps1"'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $TaskUser
$principal = New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 30)
try { Unregister-ScheduledTask -TaskName 'MindLab Report Logbook Monitor' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
Register-ScheduledTask -TaskName 'MindLab Report Logbook Monitor' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

# HKCU Run is a fallback if Task Scheduler policy does not fire.
try {
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $runPath -Force | Out-Null
    Set-ItemProperty -Path $runPath -Name 'MindLabReportLogbookMonitor' -Value 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\lab\logbook_monitor.ps1"'
} catch { Write-LogbookError "HKCU Run registration failed: $($_.Exception.Message)" }

Write-Host 'OK: single monitor installed. Old duplicate Start/End tasks removed.' -ForegroundColor Green
Get-ScheduledTask -TaskName 'MindLab Report Logbook Monitor' | Select-Object TaskName, State

Write-Host 'Launching settings popup to configure server credentials...' -ForegroundColor Cyan
Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_setup.ps1') -Wait | Out-Null

if ($RunNow) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_monitor.ps1') | Out-Null
    Write-Host 'Monitor launched.' -ForegroundColor Green
}
if ($TestPopup) {
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_popup.ps1','-TestMode') | Out-Null
}
