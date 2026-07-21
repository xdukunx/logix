$ErrorActionPreference = 'Stop'

# Runs the Logix wizard installer's own uninstaller (Inno Setup unins000.exe),
# which stops the monitor, unregisters the scheduled task, drops the HKCU Run
# fallback, and removes the program files -- the same teardown as Add/Remove
# Programs. Runtime state and AnyDesk are left as-is (AnyDesk is a separate
# app); see windows/uninstall_logbook.ps1 for a deeper wipe.
$uninstall = Join-Path $env:ProgramFiles 'Logix\unins000.exe'
if (Test-Path $uninstall) {
    $packageArgs = @{
        packageName    = 'logix'
        fileType       = 'exe'
        file           = $uninstall
        silentArgs     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        validExitCodes = @(0, 3010, 1641)
    }
    Uninstall-ChocolateyPackage @packageArgs
} else {
    Write-Warning "Logix uninstaller not found at $uninstall; it may already be removed."
}
