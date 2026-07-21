$ErrorActionPreference = 'Stop'

# Downloads and silently runs the official Logix wizard installer
# (LogixAgentSetup.exe) from the project's GitHub Release, then -- if server
# parameters were supplied -- configures the device by re-running the agent's
# own install_logbook_tasks.ps1 non-interactively (reusing the exact tooling
# the wizard uses, no duplicate config logic).
#
# CHECKSUM: fill $checksum64 with the sha256 of the released asset before
# publishing to the Chocolatey community feed (moderation requires it). Get it
# from the release, e.g.:
#   (Get-FileHash LogixAgentSetup.exe -Algorithm SHA256).Hash
$version   = '1.1.1'
$url64      = "https://github.com/xdukunx/logix/releases/download/v$version/LogixAgentSetup.exe"
# SHA256 of the v1.1.1 release asset. Recompute if the asset is rebuilt.
$checksum64 = '51DDC119E867C72A581F03050E97575056685B7224FD99A4525D4B1D9ACF32E6'

$packageArgs = @{
    packageName    = 'logix'
    fileType       = 'exe'
    url64bit       = $url64
    softwareName   = 'Logix Agent*'
    checksum64     = $checksum64
    checksumType64 = 'sha256'
    # Inno Setup silent switches. The wizard's server-settings page is skipped
    # in silent mode; configuration happens below via package parameters, or
    # later via the Logix settings popup.
    silentArgs     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
    validExitCodes = @(0, 3010, 1641)
}

# If the checksum hasn't been filled in (local/internal build), don't block the
# install on it -- but warn loudly. Community-feed packages MUST keep it set.
if ($checksum64 -eq 'REPLACE_WITH_RELEASE_EXE_SHA256') {
    Write-Warning 'Logix: installer checksum is a placeholder. Set checksum64 in chocolateyInstall.ps1 before publishing.'
    $packageArgs.Remove('checksum64')
    $packageArgs.Remove('checksumType64')
}

Install-ChocolateyPackage @packageArgs

# --- Optional server configuration via package parameters -------------------
# choco install logix --params "'/ServerUrl:https://logix.example.org /ApiKey:KEY /DeviceName:WS-07'"
$pp = Get-PackageParameters
if ($pp.ServerUrl -and $pp.ApiKey) {
    $agent = Join-Path $env:ProgramFiles 'Logix\install_logbook_tasks.ps1'
    if (Test-Path $agent) {
        Write-Host 'Configuring Logix agent from package parameters...'
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $agent,
                  '-NonInteractive','-RunNow',
                  '-ServerUrl', $pp.ServerUrl, '-ServerApiKey', $pp.ApiKey)
        if ($pp.DeviceName) { $args += @('-DeviceName', $pp.DeviceName) }
        Start-Process powershell.exe -ArgumentList $args -Wait -WindowStyle Hidden
    } else {
        Write-Warning "Logix agent script not found at $agent; skipping auto-config."
    }
} else {
    Write-Host 'Logix installed. Configure the server via the Logix settings popup, or re-run with:'
    Write-Host "  choco install logix --params `"'/ServerUrl:https://logix.example.org /ApiKey:KEY /DeviceName:WS-07'`""
}
