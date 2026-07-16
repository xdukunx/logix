# One-line installer for the Logix Windows agent on a lab PC: the core
# logging bridge (install/install.py) PLUS the sign-in popup / timer widget /
# monitor that reports to a central server (windows/install_logbook_tasks.ps1).
# One command, both pieces, on a totally fresh machine.
#
#   irm https://raw.githubusercontent.com/xdukunx/logix/main/windows/bootstrap-client.ps1 | iex
#
# Run this from an ELEVATED PowerShell (right-click PowerShell -> "Run as
# Administrator") -- it writes C:\Program Files\Logix and registers a
# scheduled task, both of which need admin rights. `irm | iex` can't take
# named parameters, so that invocation installs everything and then opens the
# interactive settings popup so you can type the server URL/API key by hand
# -- fine for a single machine. For unattended/mass deployment (imaging,
# scripted rollout to many lab PCs), download then run with flags instead:
#
#   iwr -useb <url> -OutFile bootstrap-client.ps1
#   .\bootstrap-client.ps1 -ServerUrl http://192.168.1.10:8000 -ServerApiKey <key> -DeviceName WS-07
#
# Like any pipe-to-shell installer, read it before you run it:
#   iwr -useb <url> -OutFile bootstrap-client.ps1; notepad bootstrap-client.ps1
#
# What it does: makes sure python + git are present (best-effort via winget),
# downloads this repo into $InstallSrcDir (git clone, or a zip download if git
# isn't available), runs install/install.py (the cross-platform core: logging
# bridge + report generator), then windows\install_logbook_tasks.ps1 (the
# Windows-only popup/timer/monitor agent), forwarding your -ServerUrl /
# -ServerApiKey / -DeviceName to both. Safe to re-run: git pull + reinstall in
# place, same as the server bootstrap.
#
# To wipe a broken/stale install first (e.g. it's pointed at a dead server),
# run uninstall_logbook.ps1 -- see installer/README.md.
[CmdletBinding()]
param(
    [string]$InstallSrcDir = "$env:TEMP\logix-src",
    [string]$RepoUrl = "https://github.com/xdukunx/logix.git",
    [string]$Branch = "main",
    [string]$ServerUrl = "",
    [string]$ServerApiKey = "",
    [string]$DeviceName = "",
    [switch]$UseWSL,
    [switch]$SkipAnyDesk,
    [switch]$NoRunNow
)
$ErrorActionPreference = "Stop"

function Say($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Warning $msg }
function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# --- 0. Must be elevated (writes Program Files + registers a scheduled task) -
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This installer needs Administrator rights. Right-click PowerShell -> 'Run as Administrator', then re-run the command."
}

# --- 1. Prerequisites: python, then git (best-effort via winget) ------------
Say "Checking prerequisites"
$py = if (Test-Cmd "py") { "py" } elseif (Test-Cmd "python") { "python" } else { $null }
if (-not $py) {
    if (Test-Cmd "winget") {
        Warn "Python not found; attempting 'winget install Python.Python.3.12'"
        winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
        $py = if (Test-Cmd "py") { "py" } elseif (Test-Cmd "python") { "python" } else { $null }
    }
    if (-not $py) { throw "Python 3 not found and could not auto-install it. Install Python 3.9+ from python.org, then re-run." }
}

if (-not (Test-Cmd "git")) {
    if (Test-Cmd "winget") {
        Warn "git not found; attempting 'winget install Git.Git'"
        winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
    }
    if (-not (Test-Cmd "git")) { Warn "git still not found; will fall back to downloading a zip archive." }
}

# --- 2. Get the code onto this machine ---------------------------------------
Say "Fetching Logix into $InstallSrcDir"
if (Test-Cmd "git") {
    if (Test-Path (Join-Path $InstallSrcDir ".git")) {
        git -C $InstallSrcDir fetch --depth 1 origin $Branch
        git -C $InstallSrcDir checkout $Branch
        git -C $InstallSrcDir reset --hard "origin/$Branch"
        Say "Updated existing checkout"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $InstallSrcDir -Parent) | Out-Null
        git clone --depth 1 --branch $Branch $RepoUrl $InstallSrcDir
    }
} else {
    $zipUrl = ($RepoUrl -replace '\.git$', '') + "/archive/refs/heads/$Branch.zip"
    $zipPath = Join-Path $env:TEMP "logix-$Branch.zip"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    $extractDir = Join-Path $env:TEMP "logix-extract-$(Get-Random)"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $inner = Get-ChildItem $extractDir | Select-Object -First 1
    Remove-Item $InstallSrcDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Split-Path $InstallSrcDir -Parent) | Out-Null
    Move-Item $inner.FullName $InstallSrcDir -Force
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}

Set-Location $InstallSrcDir

# --- 3. Core: logging bridge + report generator (install/install.py) --------
Say "Installing the core (install/install.py)"
$coreArgs = @("install/install.py")
if ($ServerUrl -or $ServerApiKey -or $DeviceName) {
    $coreArgs += "--non-interactive"
    if ($DeviceName)   { $coreArgs += @("--device-name", $DeviceName) }
    if ($ServerUrl)    { $coreArgs += @("--server-url", $ServerUrl) }
    if ($ServerApiKey) { $coreArgs += @("--server-api-key", $ServerApiKey) }
} else {
    Warn "No -ServerUrl/-DeviceName given -- install.py will prompt for them interactively."
}
& $py @coreArgs

# --- 4. Agent: sign-in popup, timer widget, monitor (windows\install_logbook_tasks.ps1) ---
Say "Installing the agent (windows\install_logbook_tasks.ps1)"
# Hashtable, NOT an array -- array-splatting a bare "-SwitchName" string does
# NOT bind it as a switch; PowerShell treats every array element as a plain
# positional value, so "-RunNow" ended up bound to install_logbook_tasks.ps1's
# first positional parameter ($TaskUser), which then failed inside
# Register-ScheduledTask with "No mapping between account names and security
# IDs was done" (0x80070534) -- a parameter-binding bug, not an account
# problem. Hashtable splatting binds each key to its named parameter
# correctly, switches included. Verified directly: array-splatting @("-RunNow")
# leaves the target script's switch False and its first string parameter set
# to the literal text "-RunNow"; hashtable splatting @{RunNow=$true} does not.
$taskArgs = @{}
if ($ServerUrl -and $ServerApiKey) {
    $taskArgs['NonInteractive'] = $true
    $taskArgs['ServerUrl'] = $ServerUrl
    $taskArgs['ServerApiKey'] = $ServerApiKey
    if ($DeviceName) { $taskArgs['DeviceName'] = $DeviceName }
} else {
    Warn "No -ServerUrl/-ServerApiKey given -- the interactive settings popup opens after install so you can type them in (or re-run install_logbook_tasks.ps1 -NonInteractive later)."
}
if ($UseWSL)         { $taskArgs['UseWSL'] = $true }
if ($SkipAnyDesk)    { $taskArgs['SkipAnyDesk'] = $true }
if (-not $NoRunNow)  { $taskArgs['RunNow'] = $true }

& (Join-Path $InstallSrcDir "windows\install_logbook_tasks.ps1") @taskArgs

Say "Done. Lock/unlock this machine (Win+L) to confirm the sign-in popup appears."
