param(
    # Defaults to the CURRENT user's SID, not "$env:USERDOMAIN\$env:USERNAME" --
    # on a Microsoft-Account-linked Windows sign-in (the common case on a
    # personal laptop, as opposed to a domain-joined lab workstation),
    # $env:USERNAME is a display-name-derived string that Task Scheduler's
    # name lookup often can't resolve to a SID, failing with "No mapping
    # between account names and security IDs was done" (0x80070534). A SID
    # is accepted directly by both -User and -UserId below and needs no
    # name resolution, so it works regardless of account type.
    [string]$TaskUser = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value,
    [switch]$RunNow,
    [switch]$TestPopup,
    [switch]$UseWSL,
    # Render the session timer inside a YASB status bar instead of as the
    # floating pill (windows/logix_yasb.ps1). The script has existed since the
    # bar posture shipped, but no installer path ever copied it or offered it,
    # so the only way to reach the feature was to know the file was there and
    # run it by hand out of a git checkout. Prompted for interactively, same
    # as the WSL question below, and settable unattended with -Yasb.
    [switch]$Yasb,
    # Path to the AnyDesk 7 installer to deploy so the "Remote" action works.
    # Defaults to an AnyDesk*.exe sitting next to this script. -SkipAnyDesk opts out.
    [string]$AnyDeskInstaller = "",
    [switch]$SkipAnyDesk,
    # Wizard/silent mode: no prompts, no settings popup. Server config comes
    # from these params instead (written to config.env). Used by the Inno Setup
    # wizard so a device installs unattended.
    [switch]$NonInteractive,
    [string]$ServerUrl = "",
    [string]$ServerApiKey = "",
        [string]$DeviceName = "",
    # One-time enrollment code from the dashboard (Perangkat > Tambah perangkat,
    # or ops/go_live.py register). When given, the installer performs the real
    # device handshake unattended: it redeems the code and stores the per-device
    # key in device.json. That key is what lets the server run in
    # LOGIX_REQUIRE_DEVICE_KEY mode, where the shared key no longer works.
    [string]$InviteCode = "",
    # Trust the server certificate from this .crt before enrolling. A lab server
    # issues its own certificate (Caddyfile.lab), so a fresh workstation does not
    # trust it yet and every HTTPS call would fail. Importing it here is what
    # makes an unattended install over HTTPS possible at all.
    [string]$ServerCertPath = ""
)
$ErrorActionPreference = 'Stop'

# Writing to Program Files and registering a machine scheduled task both require
# elevation. Fail fast with a clear message rather than half-installing.
$__principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $__principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'This installer must run elevated (it writes C:\Program Files\Logix and registers a scheduled task).' -ForegroundColor Yellow
    Write-Host 'Open PowerShell as Administrator, then re-run this script.' -ForegroundColor Yellow
    exit 1
}

# Program scripts install here (read-only at runtime). Runtime state stays in
# %ProgramData%\Logix. $oldLab is the legacy location we migrate away
# from and remove at the end.
$installDir = 'C:\Program Files\Logix'
$oldLab = 'C:\lab'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Whether session events log through WSL (lab workstations that already have
# a distro set up for the SSH-side bridge) or the native Python core that
# install/install.py deploys to LOGIX_HOME on every OS. Loaned/rented laptops
# typically have no WSL distro at all, so native is the safer default -- see
# Invoke-WSLLogbook / Test-LogbookUseWSL in logbook_common.ps1.
function Set-LogixConfigValue {
    param([string]$Key, [string]$Value)
    $cfgDir = Join-Path $env:ProgramData 'Logix'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfgPath = Join-Path $cfgDir 'config.env'
    $lines = if (Test-Path $cfgPath) { @(Get-Content $cfgPath) } else { @() }
    $pattern = "^\s*#?\s*(?:export\s+)?$Key\s*="
    $found = $false
    # @(...) is load-bearing: without it a 0- or 1-line config.env makes $out a
    # single STRING, and the += below then concatenates text instead of
    # appending a line -- every key ends up welded onto one line and the agent
    # can no longer read its own server URL. Only bites on a genuinely fresh
    # machine, where config.env starts empty, which is exactly the case that
    # matters.
    $out = @(foreach ($line in $lines) {
        if ($line -match $pattern) { $found = $true; "$Key=$Value" } else { $line }
    })
    if (-not $found) { $out += "$Key=$Value" }
    $out | Set-Content -Path $cfgPath -Encoding UTF8
}

$useWsl = $UseWSL.IsPresent
if (-not $PSBoundParameters.ContainsKey('UseWSL') -and -not $NonInteractive) {
    Write-Host ''
    Write-Host 'Does this machine have WSL set up with a Linux distro for the logging bridge?' -ForegroundColor Cyan
    Write-Host '  Most lab workstations do; loaned/rented laptops usually do not.' -ForegroundColor DarkGray
    $ans = Read-Host 'Use WSL bridge instead of native Python? (y/N)'
    $useWsl = $ans -match '^(y|yes)$'
}
Set-LogixConfigValue -Key 'LOGIX_USE_WSL' -Value $(if ($useWsl) { '1' } else { '0' })
Write-Host "Logging bridge: $(if ($useWsl) { 'WSL' } else { 'native Python' })" -ForegroundColor Green

# Status-bar posture. Asked the same way as the WSL question above, and only
# when the operator did not already decide with -Yasb. Detecting an existing
# YASB config makes the default the right one on a machine that has a bar.
$yasbWanted = $Yasb.IsPresent
if (-not $PSBoundParameters.ContainsKey('Yasb') -and -not $NonInteractive) {
    $yasbInstalled = Test-Path (Join-Path $env:USERPROFILE '.config\yasb\config.yaml')
    Write-Host ''
    Write-Host 'Show the session timer inside a YASB status bar instead of the floating pill?' -ForegroundColor Cyan
    if ($yasbInstalled) {
        Write-Host '  A YASB config was found on this machine.' -ForegroundColor DarkGray
    } else {
        Write-Host '  No YASB config found; pick No unless you are about to install YASB.' -ForegroundColor DarkGray
    }
    Write-Host '  The bar reserves its own space, so nothing is ever covered by an overlay.' -ForegroundColor DarkGray
    $ansYasb = Read-Host "Use the YASB bar? (y/N)"
    $yasbWanted = $ansYasb -match '^(y|yes)$'
}

# Server config passed by the wizard (or CLI) -> config.env, so the agent knows
# where to report and with what key without the interactive settings popup.
if ($ServerUrl)    { Set-LogixConfigValue -Key 'LOGIX_SERVER_URL'     -Value $ServerUrl }
if ($ServerApiKey) { Set-LogixConfigValue -Key 'LOGIX_SERVER_API_KEY' -Value $ServerApiKey }
if ($DeviceName)   { Set-LogixConfigValue -Key 'LOGIX_DEVICE_NAME'    -Value $DeviceName }

# --- Real device handshake ---------------------------------------------------
# With an invite code we enroll for real instead of relying on the shared
# bootstrap key: the server hands back a key belonging to THIS device only,
# which is what lets it run in LOGIX_REQUIRE_DEVICE_KEY mode where the shared
# key is refused outright. Codes are single-use, expire in 15 minutes, and can
# be pinned to one hostname, so a code that leaks is worth nothing elsewhere.
if ($ServerCertPath -and (Test-Path $ServerCertPath)) {
    # A lab server issues its own certificate, so a fresh workstation does not
    # trust it yet and enrollment over HTTPS would fail before it starts.
    try {
        Import-Certificate -FilePath $ServerCertPath -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop | Out-Null
        Write-Host "Trusted server certificate from $ServerCertPath" -ForegroundColor Green
    } catch {
        Write-Host "WARNING: could not import $ServerCertPath : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($InviteCode) {
    if (-not $ServerUrl) {
        Write-Host 'WARNING: -InviteCode given without -ServerUrl; skipping enrollment.' -ForegroundColor Yellow
    } else {
        $identityDir = 'C:\ProgramData\Logix'
        $identityPath = Join-Path $identityDir 'device.json'
        try {
            New-Item -ItemType Directory -Force -Path $identityDir | Out-Null
            # device_name is sent at enrolment, not left for the first
            # heartbeat to supply -- see the same change in logbook_setup.ps1
            # and install/install.py. All three enrolment paths now agree on
            # both the hostname source and the display name.
            $body = @{
                invite_code   = $InviteCode
                hostname      = $env:COMPUTERNAME
                device_name   = $DeviceName
                os            = 'windows'
                os_version    = [System.Environment]::OSVersion.VersionString
                agent_version = 'installer'
            } | ConvertTo-Json
            $enrolled = Invoke-RestMethod -Uri ($ServerUrl.TrimEnd('/') + '/api/enroll') -Method Post `
                -Body $body -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing
            @{ device_id = $enrolled.device_id; api_key = $enrolled.api_key; category = $enrolled.category } |
                ConvertTo-Json | Out-File -FilePath $identityPath -Encoding UTF8 -Force
            Write-Host "Enrolled with the server (device_id $($enrolled.device_id))." -ForegroundColor Green
            # The per-device key supersedes the shared one; drop the bootstrap
            # key so a copy of it is not left sitting on the workstation.
            Set-LogixConfigValue -Key 'LOGIX_SERVER_API_KEY' -Value ''
        } catch {
            Write-Host "ERROR: enrollment failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '  The agent will still install and will fall back to the shared key if one is set.' -ForegroundColor Yellow
            Write-Host '  Re-run with a fresh code once the server is reachable.' -ForegroundColor Yellow
        }
    }
}

# Copy scripts from installer source folder to the install dir. Includes THIS
# script: installer/README.md tells operators to re-run
# "C:\Program Files\Logix\install_logbook_tasks.ps1" to re-point a device, so
# a stale copy there would re-register the task with whatever action string it
# was built with (exactly how an old powershell.exe action -- and its
# every-30-minutes terminal tab -- could sneak back). Self-copy is safe:
# PowerShell parses the whole file before running it, and the -ieq guard below
# skips the copy when already running from the install dir.
$files = @(
    'install_logbook_tasks.ps1',
    'logbook_common.ps1',
    'logbook_popup.ps1',
    'logbook_monitor.ps1',
    'logbook_timer.ps1',
    'logbook_screenshot.ps1',
    'logbook_end.ps1',
    'logbook_setup.ps1',
    'cleanup_logbook_state.ps1',
    'debug_logbook_detection.ps1',
    'repair_logbook_permissions.ps1',
    'logix_yasb.ps1',
    'uninstall_logbook.ps1'
)
foreach ($f in $files) {
    $src = Join-Path $PSScriptRoot $f
    $dst = Join-Path $installDir $f
    # Skip the copy when already running from the install dir (the wizard installs
    # the scripts to $installDir first, then runs this from there) -- copying a
    # file onto itself throws.
    if ((Test-Path $src) -and -not ($src -ieq $dst)) {
        Copy-Item -Path $src -Destination $dst -Force
    }
}

. (Join-Path $installDir 'logbook_common.ps1')
Ensure-LogbookDirs

Write-Host 'Logix Report Logbook installer' -ForegroundColor Cyan
Write-Host 'User:' $TaskUser

# One-time grant so the sign-in popup can gate Task Manager at runtime even
# on a standard (non-admin) account - this install step runs elevated, the
# scheduled task it registers below does not. See
# Grant-LogbookTaskMgrGateAccess in logbook_common.ps1 for why this is safe
# and narrowly scoped.
Grant-LogbookTaskMgrGateAccess

# Grant the interactive account an inheritable Modify ACE on the state dir so
# session.json/timer.pid stay deletable by the (non-elevated) runtime, and
# repair any files a past elevated run left owned by Administrators. Pairs with
# the -RunLevel Limited task below -- together they keep all state files
# user-owned so ending a session (removing session.json) can never fail. See
# Grant-LogbookStateDirAccess in logbook_common.ps1.
Grant-LogbookStateDirAccess

# Deliberately AFTER Grant-LogbookStateDirAccess: logix_yasb.ps1 -Enable writes
# widget_prefs.json into the state dir, and this installer runs elevated. With
# the inheritable Modify ACE already on the directory, the new file is writable
# by the (non-elevated) widget, which is what lets a later posture change stick
# instead of failing silently the way admin-owned state files do.
if ($yasbWanted) {
    Write-Host ''
    Write-Host 'Enabling the YASB status-bar posture...' -ForegroundColor Cyan
    try {
        & (Join-Path $installDir 'logix_yasb.ps1') -Enable
    } catch {
        Write-LogbookError "YASB enable failed: $($_.Exception.Message)"
        Write-Host "Run it yourself later:  & '$installDir\logix_yasb.ps1' -Enable" -ForegroundColor Yellow
    }
} else {
    Write-Host "Timer posture: floating pill. To switch later:  & '$installDir\logix_yasb.ps1' -Enable" -ForegroundColor DarkGray
}

# Auto-deploy AnyDesk 7 so the dashboard's "Remote" action works out of the box.
# The agent already reports this device's AnyDesk ID on every heartbeat
# (Get-AnyDeskId in logbook_common.ps1), so once AnyDesk is present the ID shows
# up on the dashboard automatically -- no admin typing it in. Idempotent: skips
# if AnyDesk is already installed.
function Install-AnyDesk {
    param([string]$InstallerPath)
    $anydeskExe = @(
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
        "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $anydeskExe) {
        if (-not $InstallerPath) {
            $found = Get-ChildItem -Path $PSScriptRoot -Filter 'AnyDesk*.exe' -File -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { $InstallerPath = $found.FullName }
        }
        if (-not $InstallerPath -or -not (Test-Path $InstallerPath)) {
            Write-Host 'AnyDesk installer not found -- skipping (Remote will stay disabled).' -ForegroundColor Yellow
            Write-Host "  Drop the AnyDesk 7 installer at windows\AnyDesk.exe or pass -AnyDeskInstaller <path>." -ForegroundColor DarkGray
            return
        }
        Write-Host "Installing AnyDesk silently from $InstallerPath ..." -ForegroundColor Cyan
        $target = "${env:ProgramFiles(x86)}\AnyDesk"
        try {
            & $InstallerPath --install $target --start-with-win --create-shortcuts --silent
            Start-Sleep -Seconds 5
        } catch { Write-LogbookError "AnyDesk silent install failed: $($_.Exception.Message)" }
        $anydeskExe = @("$target\AnyDesk.exe", "$env:ProgramFiles\AnyDesk\AnyDesk.exe") |
                      Where-Object { Test-Path $_ } | Select-Object -First 1
    } else {
        Write-Host "AnyDesk already installed ($anydeskExe)." -ForegroundColor Green
    }
    if (-not $anydeskExe) { Write-Host 'AnyDesk install did not complete; Remote stays disabled.' -ForegroundColor Yellow; return }

    # Optional unattended-access password (LOGIX_ANYDESK_PASSWORD in config.env)
    # so an admin can connect without the local user clicking Accept. Only set
    # when explicitly configured -- never a default.
    $adPass = Get-LogbookConfigEnv 'LOGIX_ANYDESK_PASSWORD'
    if ($adPass) {
        try {
            $adPass | & $anydeskExe --set-password
            Write-Host 'AnyDesk unattended-access password configured.' -ForegroundColor Green
        } catch { Write-LogbookError "AnyDesk set-password failed: $($_.Exception.Message)" }
    }
    try {
        $id = (& $anydeskExe --get-id 2>$null | Out-String).Trim()
        if ($id) { Write-Host "AnyDesk ID for this device: $id (auto-reported to the dashboard)." -ForegroundColor Green }
    } catch {}
}
if (-not $SkipAnyDesk) { Install-AnyDesk -InstallerPath $AnyDeskInstaller }

# Clean the old direct Start/End tasks that caused duplicate stacks.
foreach ($t in @('MindLab Report Logbook Start','MindLab Report Logbook End','Lab Logbook Start','Lab Logbook End')) {
    try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

# Kill old timer/monitor instances before installing the single monitor model.
try {
    Stop-LogbookTimers
    $monitors = Get-ProcessByCommandPattern 'logbook_monitor\.ps1'
    foreach ($p in $monitors) {
        if ([int]$p.ProcessId -ne [int]$PID) { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue }
    }
} catch {}

# conhost --headless: on Windows 11, Windows Terminal is the default console
# host and can open a visible terminal tab for a Task Scheduler powershell
# launch even with -WindowStyle Hidden. With the 30-minute self-heal trigger
# below, that meant a terminal tab popping up on the user's desktop every 30
# minutes. The headless conhost wrapper never creates a window (see
# Start-HiddenPowerShell in logbook_common.ps1 for the full story).
$monitorCmd = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Program Files\Logix\logbook_monitor.ps1"'
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument $monitorCmd
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $TaskUser
# Self-heal trigger: everything (popup on unlock, heartbeats, remote
# commands) depends on the resident monitor, and a dead monitor previously
# stayed dead until the next logon -- observed in the field as "no popup or
# timer after lock/unlock" right after an otherwise-successful install (the
# monitor had exited with 0xC000013A/terminated within minutes; root cause
# of that one exit was never pinned down, so the durable fix is surviving
# ANY death). This re-fires the script every 30 minutes indefinitely; while
# a monitor is alive, Task Scheduler's default MultipleInstances=IgnoreNew
# means the firing is a no-op (and the monitor's own mutex is a second
# guard against e.g. the HKCU Run fallback racing it), so the only effect
# is a dead monitor coming back within <=30 minutes.
$healTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)
# RunLevel Limited (NOT Highest): the monitor and everything it spawns (popup,
# timer) must run as the plain interactive user so the state files they create
# are user-owned and therefore user-deletable. Running elevated made
# session.json/timer.pid owned by BUILTIN\Administrators, after which a
# non-elevated run (e.g. the HKCU Run fallback below) could no longer remove
# them -- so ending a session silently failed and its timer kept counting. The
# only privileged thing the popup does, gating Task Manager, already works
# unelevated via Grant-LogbookTaskMgrGateAccess above.
$principal = New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType Interactive -RunLevel Limited
# ExecutionTimeLimit 0 = unlimited. The old 30-day limit meant Task
# Scheduler force-killed the monitor after 30 days on a workstation that
# stays logged in for months, silently disabling the sign-in popup until
# the next logon. RestartCount/RestartInterval additionally restart the
# task automatically if the monitor process dies abnormally.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
# The pre-rename task name is unregistered alongside the new one. Without
# this an upgraded workstation keeps the old registration and ends up with
# TWO monitors racing for the same session files.
foreach ($legacyTask in @('MindLab Report Logbook Monitor', 'Logix Agent Monitor')) {
    try { Unregister-ScheduledTask -TaskName $legacyTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}
Register-ScheduledTask -TaskName 'Logix Agent Monitor' -Action $action -Trigger @($trigger, $healTrigger) -Principal $principal -Settings $settings -Force | Out-Null

# HKCU Run is a fallback if Task Scheduler policy does not fire.
try {
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $runPath -Force | Out-Null
    # The pre-rename value is removed first, or both fire at logon.
    Remove-ItemProperty -Path $runPath -Name 'MindLabReportLogbookMonitor' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $runPath -Name 'LogixAgentMonitor' -Value "`"$env:SystemRoot\System32\conhost.exe`" $monitorCmd"
} catch { Write-LogbookError "HKCU Run registration failed: $($_.Exception.Message)" }

Write-Host 'OK: single monitor installed. Old duplicate Start/End tasks removed.' -ForegroundColor Green
Get-ScheduledTask -TaskName 'Logix Agent Monitor' | Select-Object TaskName, State

if (-not $NonInteractive) {
    Write-Host 'Launching settings popup to configure server credentials...' -ForegroundColor Cyan
    Start-HiddenPowerShell -Wait -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\Program Files\Logix\logbook_setup.ps1') | Out-Null
}

# Migrate any logo asset then remove the legacy C:\lab program dir so the app
# lives entirely under Program Files. Runtime state (%ProgramData%) is untouched.
if ((Test-Path $oldLab) -and ($oldLab -ne $installDir)) {
    try {
        $oldLogo = Join-Path $oldLab 'logo.png'
        if (Test-Path $oldLogo) { Copy-Item $oldLogo (Join-Path $installDir 'logo.png') -Force -ErrorAction SilentlyContinue }
        Get-ChildItem -Path $oldLab -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $oldLab 'logbook_error.log') -Force -ErrorAction SilentlyContinue
        if (-not (Get-ChildItem -Path $oldLab -Force -ErrorAction SilentlyContinue)) {
            Remove-Item $oldLab -Force -Recurse -ErrorAction SilentlyContinue
        }
        Write-Host "Migrated program files to $installDir and cleaned up legacy $oldLab." -ForegroundColor Green
    } catch { Write-LogbookError "Legacy C:\lab cleanup failed: $($_.Exception.Message)" }
}

if ($RunNow) {
    # Start via the scheduled task (NOT Start-Process): this installer runs
    # elevated, and a Start-Process child would inherit that elevation, which is
    # exactly what makes state files admin-owned and unremovable. The task's
    # RunLevel Limited principal launches the monitor as the plain user.
    Start-ScheduledTask -TaskName 'Logix Agent Monitor'
    Write-Host 'Monitor launched (non-elevated via scheduled task).' -ForegroundColor Green
}
if ($TestPopup) {
    Start-HiddenPowerShell -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\Program Files\Logix\logbook_popup.ps1','-TestMode') | Out-Null
}
