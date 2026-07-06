# Compile the NSIS (Comnyang-style) Logix installer. Regenerates the mascot
# branding, finds makensis, and builds Output\LogixAgentSetup-nsis.exe.
#
#   powershell -File installer\nsis\build.ps1            # real installer
#   powershell -File installer\nsis\build.ps1 -Preview   # no-UAC UI preview
param([switch]$Preview)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Split-Path -Parent $here

$mk = @(
    'C:\Program Files (x86)\NSIS\makensis.exe',
    'C:\Program Files\NSIS\makensis.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $mk) {
    Write-Host 'NSIS (makensis.exe) not found. Install from https://nsis.sourceforge.io/Download' -ForegroundColor Red
    exit 1
}

# Regenerate the mascot branding (logix.ico + wizard-small.bmp the .nsi embeds).
# Unlike the Inno script, the .nsi File commands are unconditional, so these
# assets must exist at compile time.
$mascot = Get-ChildItem -Path (Join-Path $installer 'branding') -Filter 'mascot-source.*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mascot) {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) {
        Write-Host "Building mascot branding from $($mascot.Name)..." -ForegroundColor Cyan
        & $py.Source (Join-Path $installer 'build_branding.py')
    } else {
        Write-Host 'Python not found; branding assets may be missing.' -ForegroundColor Yellow
    }
}

$mkArgs = @()
if ($Preview) { $mkArgs += '/DPREVIEW' }
$mkArgs += (Join-Path $here 'logix-agent.nsi')
& $mk @mkArgs
if ($LASTEXITCODE -eq 0) {
    $name = if ($Preview) { 'LogixAgentSetup-nsis-preview.exe' } else { 'LogixAgentSetup-nsis.exe' }
    Write-Host "Built: $(Join-Path $installer "Output\$name")" -ForegroundColor Green
} else {
    Write-Host "makensis failed (exit $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
