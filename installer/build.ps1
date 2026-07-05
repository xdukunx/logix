# Compile the Logix Agent wizard installer. Finds ISCC (Inno Setup 6) and builds
# logix-agent.iss -> Output\LogixAgentSetup.exe. Run: powershell -File installer\build.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$iscc = @(
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
    Write-Host 'Inno Setup 6 (ISCC.exe) not found. Install it from https://jrsoftware.org/isdl.php' -ForegroundColor Red
    exit 1
}

$anydesk = Join-Path $here 'assets\anydesk-7-0-0.exe'
if (-not (Test-Path $anydesk)) {
    Write-Host "WARNING: $anydesk missing -- the wizard will build but won't bundle AnyDesk." -ForegroundColor Yellow
}

& $iscc (Join-Path $here 'logix-agent.iss')
if ($LASTEXITCODE -eq 0) {
    Write-Host "Built: $(Join-Path $here 'Output\LogixAgentSetup.exe')" -ForegroundColor Green
} else {
    Write-Host "ISCC failed (exit $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
