# Compile the Logix Agent wizard installer. Finds ISCC (Inno Setup 6) and builds
# logix-agent.iss -> Output\LogixAgentSetup.exe. Run: powershell -File installer\build.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$iscc = @(
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe',
    # winget --scope user puts it here.
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
    Write-Host 'Inno Setup 6 (ISCC.exe) not found. Install it from https://jrsoftware.org/isdl.php' -ForegroundColor Red
    exit 1
}

$anydesk = Join-Path $here 'assets\anydesk-7-0-0.exe'
if (-not (Test-Path $anydesk)) {
    Write-Host "WARNING: $anydesk missing -- the wizard will build but won't bundle AnyDesk." -ForegroundColor Yellow
}

# Regenerate the mascot branding (wizard images + icon) if a source artwork is
# present. Best-effort: if there's no mascot or no Python, the installer just
# falls back to Inno's stock images (the .iss guards every branding directive).
$mascot = Get-ChildItem -Path (Join-Path $here 'branding') -Filter 'mascot-source.*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mascot) {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) {
        Write-Host "Building mascot branding from $($mascot.Name)..." -ForegroundColor Cyan
        & $py.Source (Join-Path $here 'build_branding.py')
        if ($LASTEXITCODE -ne 0) { Write-Host 'Branding step failed; using stock wizard images.' -ForegroundColor Yellow }
    } else {
        Write-Host 'Python not found; skipping mascot branding (stock wizard images).' -ForegroundColor Yellow
    }
} else {
    Write-Host 'No installer\branding\mascot-source.* found; using stock wizard images.' -ForegroundColor Yellow
}

# Bundle the embeddable Python the agent logs sessions with (Find-LogixPython
# prefers {app}\python). Without it a lab PC records sessions only if a real
# Python happens to be on the signed-in account's PATH -- and on stock Windows
# the only "python" there is the Store stub, which runs nothing.
$pyVersion = '3.12.10'
$pyDir = Join-Path $here 'assets\python'
if (-not (Test-Path (Join-Path $pyDir 'python.exe'))) {
    $zipName = "python-$pyVersion-embed-amd64.zip"
    $zip = Join-Path $env:TEMP $zipName
    Write-Host "Fetching $zipName from python.org..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$pyVersion/$zipName" -OutFile $zip -UseBasicParsing
        New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
        Expand-Archive -Path $zip -DestinationPath $pyDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        # Trust the signature, not the download: python.exe must carry a valid
        # Python Software Foundation Authenticode signature, or it is not shipped.
        $sig = Get-AuthenticodeSignature (Join-Path $pyDir 'python.exe')
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
            Remove-Item $pyDir -Recurse -Force
            throw "python.exe signature check failed ($($sig.Status))."
        }
    } catch {
        Write-Host "WARNING: could not bundle Python: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '  The installer will build without it; PCs then need Python 3 installed for all users.' -ForegroundColor Yellow
    }
}

& $iscc (Join-Path $here 'logix-agent.iss')
if ($LASTEXITCODE -eq 0) {
    Write-Host "Built: $(Join-Path $here 'Output\LogixAgentSetup.exe')" -ForegroundColor Green
} else {
    Write-Host "ISCC failed (exit $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
