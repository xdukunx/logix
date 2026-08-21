# One-line installer for the Logix central admin server (Windows).
#
#   irm https://raw.githubusercontent.com/xdukunx/logix/main/install/bootstrap-server.ps1 | iex
#
# `irm | iex` can't take named parameters (PowerShell limitation, not a bug
# here) -- that invocation runs fully interactive, which is fine since
# setup_server.py prompts for everything it needs (including the admin login
# password). To pass flags (admin emails, -Service, etc.) instead, download
# then run it:
#   iwr -useb <url> -OutFile bootstrap-server.ps1
#   .\bootstrap-server.ps1 -AdminEmails "you@example.org" -AdminPassword "strong-pass" -Service
#
# Like any pipe-to-shell installer, read it before you run it. Run this from
# an elevated PowerShell if you pass -Service (Task Scheduler registration
# needs admin rights); the rest works unelevated.
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:SystemDrive\Logix",
    [string]$RepoUrl = "https://github.com/xdukunx/logix.git",
    [string]$Branch = "main",
    [string]$AdminEmails = "",
    [string]$AdminPassword = "",
    [string]$IngestKey = "",
    [string]$AllowedOrigins = "",
    [ValidateSet("0", "1")][string]$DevMode = "",
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 8000,
    [switch]$InstallDeps = $true,
    [switch]$Service
)
$ErrorActionPreference = "Stop"

function Say($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Warning $msg }

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# A winget install lands on disk immediately but is invisible to THIS process
# until PATH is re-read: the environment block was captured when the shell
# started. Without this the script installed Python correctly and then decided
# Python was not installed -- which is exactly why a "one-line installer" had
# to be finished by hand.
function Update-SessionPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Install-WithWinget($id, $label) {
    if (-not (Test-Cmd "winget")) {
        Warn "winget is not available, so $label cannot be installed automatically."
        return $false
    }
    Say "Installing $label (winget: $id)"
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
    Update-SessionPath
    return $true
}

# --- 1. Prerequisites: python, node, git ------------------------------------
# Every version this project actually needs is pinned and checked here, so
# nothing is left to work out by hand afterwards:
#   Python  >= 3.9   (3.12 is what gets installed; server/.venv is built from it)
#   Node.js >= 18    (Vite 7 / React 19; CI builds the dashboard on Node 20 LTS)
#   git              (optional -- a zip download is the fallback)
$PYTHON_MIN = [Version]"3.9"
$NODE_MIN = 18

Say "Checking prerequisites"

function Get-PythonCmd {
    foreach ($candidate in @("py", "python3", "python")) {
        if (-not (Test-Cmd $candidate)) { continue }
        try {
            $raw = & $candidate -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $version = [Version]($raw.Trim())
                if ($version -ge $PYTHON_MIN) { return @{ Cmd = $candidate; Version = $version } }
                Warn "$candidate is Python $version; Logix needs $PYTHON_MIN or newer."
            }
        } catch { }
    }
    return $null
}

$pyInfo = Get-PythonCmd
if (-not $pyInfo) {
    Warn "No Python $PYTHON_MIN+ on PATH."
    [void](Install-WithWinget "Python.Python.3.12" "Python 3.12")
    $pyInfo = Get-PythonCmd
}
if (-not $pyInfo) {
    throw "Python $PYTHON_MIN+ not found and could not be installed automatically. Install Python 3.12 from python.org (tick 'Add python.exe to PATH'), then re-run."
}
$py = $pyInfo.Cmd
Say "Using Python $($pyInfo.Version) ($py)"

# Node is no longer optional-by-omission. It used to be: if npm happened to be
# on PATH the React dashboard got built, and if it was not, the script printed
# a warning and quietly shipped the legacy vanilla-JS UI instead -- so whether
# an install ended up with the real dashboard came down to what the machine
# already had lying around. It is installed here like any other dependency.
function Get-NodeMajor {
    if (-not (Test-Cmd "node")) { return 0 }
    try {
        $raw = (& node --version 2>$null)   # "v20.11.1"
        if ($raw -match '^v?(\d+)\.') { return [int]$Matches[1] }
    } catch { }
    return 0
}

$nodeMajor = Get-NodeMajor
if ($nodeMajor -lt $NODE_MIN) {
    if ($nodeMajor -gt 0) { Warn "Node $nodeMajor is older than the required $NODE_MIN." }
    [void](Install-WithWinget "OpenJS.NodeJS.LTS" "Node.js LTS")
    $nodeMajor = Get-NodeMajor
}
if ($nodeMajor -ge $NODE_MIN) {
    Say "Using Node $nodeMajor"
} else {
    Warn "Node.js $NODE_MIN+ is still not available. The dashboard build will be skipped and the server will serve the legacy static UI."
    Warn "Install Node.js LTS from nodejs.org, then re-run this script to get the full dashboard."
}

if (-not (Test-Cmd "git")) {
    [void](Install-WithWinget "Git.Git" "git")
    if (-not (Test-Cmd "git")) { Warn "git still not found; will fall back to downloading a zip archive." }
}

# --- 2. Get the code onto this machine ---------------------------------------
Say "Fetching Logix into $InstallDir"
if (Test-Cmd "git") {
    if (Test-Path (Join-Path $InstallDir ".git")) {
        git -C $InstallDir fetch --depth 1 origin $Branch
        git -C $InstallDir checkout $Branch
        git -C $InstallDir reset --hard "origin/$Branch"
        Say "Updated existing checkout"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $InstallDir -Parent) | Out-Null
        git clone --depth 1 --branch $Branch $RepoUrl $InstallDir
    }
} else {
    $zipUrl = ($RepoUrl -replace '\.git$', '') + "/archive/refs/heads/$Branch.zip"
    $zipPath = Join-Path $env:TEMP "logix-$Branch.zip"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    $extractDir = Join-Path $env:TEMP "logix-extract"
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $inner = Get-ChildItem $extractDir | Select-Object -First 1
    New-Item -ItemType Directory -Force -Path (Split-Path $InstallDir -Parent) | Out-Null
    Move-Item $inner.FullName $InstallDir -Force
}

Set-Location $InstallDir

# --- 3. Build the dashboard --------------------------------------------------
if ((Get-NodeMajor) -ge $NODE_MIN -and (Test-Cmd "npm")) {
    Say "Building the React dashboard"
    Push-Location frontend
    try {
        npm ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) {
            Warn "npm ci failed (usually a lockfile/registry mismatch); retrying with npm install"
            npm install --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
        }
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed with exit code $LASTEXITCODE" }
        Say "Dashboard built into frontend\dist"
    } catch {
        # Loud, and it names the two commands to run by hand. The previous
        # version swallowed npm's real error entirely, so a failed build looked
        # identical to a machine that simply had no Node on it.
        Warn "Dashboard build failed: $($_.Exception.Message)"
        Warn "The server will serve the legacy static UI. To retry:"
        Warn "    cd $InstallDir\frontend; npm install; npm run build"
    } finally {
        Pop-Location
    }
} else {
    Warn "Skipping the dashboard build (no usable Node.js). The legacy static UI will be served."
}

# --- 4. Hand off to the real installer --------------------------------------
Say "Running install\setup_server.py"
$pyArgs = @()
if ($AdminEmails)    { $pyArgs += @("--admin-emails", $AdminEmails) }
if ($AdminPassword)  { $pyArgs += @("--admin-password", $AdminPassword) }
if ($IngestKey)      { $pyArgs += @("--ingest-key", $IngestKey) }
if ($AllowedOrigins) { $pyArgs += @("--allowed-origins", $AllowedOrigins) }
if ($DevMode)        { $pyArgs += @("--dev-mode", $DevMode) }
$pyArgs += @("--host", $BindHost, "--port", $Port)
if (-not $InstallDeps) { $pyArgs += "--no-install-deps" }
if ($Service)     { $pyArgs += "--service" }

& $py install/setup_server.py @pyArgs
