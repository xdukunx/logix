# Push the repo's client scripts onto THIS machine's existing install.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\update_installed_client.ps1
#
# For the edit-test-look loop on a box that already ran the installer. It does
# not enrol, does not touch the device key, does not create tasks, and does not
# touch session state -- it only replaces code and restarts the agent.
#
# Why this exists: the install on the developer's own machine had drifted into a
# MIXED VERSION -- logbook_popup.ps1 nearly three weeks older than the
# logbook_common.ps1 beside it -- which failed at runtime with a missing-function
# error that looked like a repo bug. Copying files by hand, one at a time, is
# what produces that. Copy the set or copy nothing.
#
# Self-elevates: C:\Program Files is not user-writable. The AGENT itself must
# keep running non-elevated (an elevated agent writes a session.json the user
# cannot delete), and it does -- the scheduled task's own principal is
# unchanged here.
param(
    [string]$InstallDir = 'C:\Program Files\Logix',
    [switch]$NoRestart,
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    if ($Elevated) { throw "re-launch did not gain administrator rights" }
    Write-Host "Needs administrator to write to $InstallDir -- prompting..." -ForegroundColor Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
           '-InstallDir', $InstallDir, '-Elevated')
    if ($NoRestart) { $a += '-NoRestart' }
    # Start-Process does not quote arguments containing spaces, so pass the
    # array form and let it quote each element.
    $p = Start-Process powershell.exe -ArgumentList $a -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
}

if (-not (Test-Path $InstallDir)) {
    throw "$InstallDir does not exist -- this updates an EXISTING install. Run install_logbook_tasks.ps1 first."
}

$repo = $PSScriptRoot
$scripts = @(
    'logbook_common.ps1', 'logbook_popup.ps1', 'logbook_timer.ps1', 'logbook_monitor.ps1',
    'logbook_end.ps1', 'logbook_screenshot.ps1', 'logbook_setup.ps1', 'install_logbook_tasks.ps1',
    'uninstall_logbook.ps1', 'cleanup_logbook_state.ps1', 'repair_logbook_permissions.ps1'
)

# ---- stop the agent so nothing is mid-read while files change ---------------
$taskName = 'MindLab Report Logbook Monitor'
$task = Get-ScheduledTask | Where-Object { $_.TaskName -eq $taskName }
if ($task -and -not $NoRestart) {
    Write-Host "stopping '$taskName'"
    try { Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath } catch { }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'logbook_(monitor|timer)\.ps1' } |
    ForEach-Object {
        Write-Host "  stopping agent pid $($_.ProcessId)"
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
    }

# ---- copy ---------------------------------------------------------------------
$copied = 0; $missing = @()
foreach ($s in $scripts) {
    $src = Join-Path $repo $s
    if (-not (Test-Path $src)) { $missing += $s; continue }
    Copy-Item $src (Join-Path $InstallDir $s) -Force
    $copied++
}
Write-Host "copied $copied script(s) to $InstallDir" -ForegroundColor Green
if ($missing) { Write-Host "  not in repo, left alone: $($missing -join ', ')" -ForegroundColor DarkGray }

$logo = Join-Path $repo 'logo.png'
if (Test-Path $logo) { Copy-Item $logo (Join-Path $InstallDir 'logo.png') -Force }

# ---- re-seed the cached palette ----------------------------------------------
# branding.colors normally arrives from the server via /api/config; the local
# file is a cache so the client still renders when the server is unreachable.
# A box installed before the v3 palette landed keeps serving itself the retired
# maroon until its first successful fetch, so refresh the cache directly.
$serverCfg = Join-Path (Split-Path $repo -Parent) 'server\server_config.json'
$localCfg = 'C:\ProgramData\MindLabLogbook\config.json'
if ((Test-Path $serverCfg) -and (Test-Path $localCfg)) {
    try {
        $want = (Get-Content -Raw $serverCfg | ConvertFrom-Json).branding.colors
        $have = Get-Content -Raw $localCfg | ConvertFrom-Json
        foreach ($p in $want.PSObject.Properties) {
            $have.branding.colors | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
        # UTF8 without BOM: a BOM here has broken JSON readers in this project before.
        [System.IO.File]::WriteAllText($localCfg,
            ($have | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
        Write-Host "refreshed cached branding.colors (accent $($want.accent))" -ForegroundColor Green
    } catch {
        Write-Host "could not refresh cached palette: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---- restart -------------------------------------------------------------------
if ($task -and -not $NoRestart) {
    Write-Host "starting '$taskName'"
    Start-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
    Start-Sleep -Seconds 2
    $state = (Get-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath).State
    Write-Host "task state: $state" -ForegroundColor Green
} elseif (-not $task) {
    Write-Host "scheduled task '$taskName' not found -- files updated, nothing restarted." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. The widget reappears on the next monitor cycle." -ForegroundColor Cyan
