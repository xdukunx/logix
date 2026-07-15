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

# --- 1. Prerequisites: python, then git (best-effort via winget) ------------
Say "Checking prerequisites"
$py = if (Test-Cmd "py") { "py" } elseif (Test-Cmd "python") { "python" } else { $null }
if (-not $py) {
    if (Test-Cmd "winget") {
        Warn "Python not found; attempting 'winget install Python.Python.3.12'"
        winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements
        $py = if (Test-Cmd "py") { "py" } elseif (Test-Cmd "python") { "python" } else { $null }
    }
    if (-not $py) { throw "Python 3 not found and could not auto-install it. Install Python 3.9+ from python.org, then re-run." }
}

if (-not (Test-Cmd "git")) {
    if (Test-Cmd "winget") {
        Warn "git not found; attempting 'winget install Git.Git'"
        winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
        # winget installs need a fresh PATH in this session.
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
    }
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

# --- 3. Build the dashboard (optional -- falls back to the legacy static UI) -
if (Test-Cmd "npm") {
    Say "Building the React dashboard"
    Push-Location frontend
    try {
        npm ci --no-audit --no-fund 2>$null
        if ($LASTEXITCODE -ne 0) { npm install --no-audit --no-fund }
        npm run build
    } catch {
        Warn "Dashboard build failed; the server will serve the legacy static UI instead."
    } finally {
        Pop-Location
    }
} else {
    Warn "npm not found; skipping the React dashboard build (legacy static UI will be served). Install Node.js and run 'cd frontend; npm install; npm run build' later to upgrade it."
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
if ($InstallDeps) { $pyArgs += "--install-deps" }
if ($Service)     { $pyArgs += "--service" }

& $py install/setup_server.py @pyArgs
