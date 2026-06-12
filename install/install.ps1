# Logix installer launcher for Windows.
# Usage (elevated PowerShell):  .\install\install.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $py) {
    Write-Error 'Python 3 not found. Install it from https://www.python.org/downloads/ first.'
    exit 1
}
& $py (Join-Path $here 'install.py') @args
exit $LASTEXITCODE
