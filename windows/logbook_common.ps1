# MindLab Report Logbook common helpers v5.7
$ErrorActionPreference = 'Stop'

$Global:LabDir = 'C:\lab'
$Global:StateDir = Join-Path $env:ProgramData 'MindLabLogbook'
$Global:SessionFile = Join-Path $Global:StateDir 'session.json'
$Global:ErrorLog = Join-Path $Global:LabDir 'logbook_error.log'
$Global:PopupLock = Join-Path $Global:StateDir 'popup.lock'

function Write-LogbookError {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path $Global:LabDir | Out-Null
        "$(Get-Date -Format o) $Message" | Out-File -FilePath $Global:ErrorLog -Append -Encoding UTF8
    } catch {}
}

function Write-LogbookInfo {
    param([string]$Message)
    Write-LogbookError "INFO: $Message"
}

function Ensure-LogbookDirs {
    New-Item -ItemType Directory -Force -Path $Global:LabDir | Out-Null
    New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
}

function Test-AnyDeskInteractiveWindow {
    if ($env:LOGBOOK_FORCE_ANYDESK -eq '1') { return $true }
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -like 'AnyDesk*' -and
            -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
        })
        foreach ($p in $procs) {
            $title = [string]$p.MainWindowTitle
            if ($title -match '(?i)(anydesk|session|connected|remote|incoming|desk)') {
                return $true
            }
        }
    } catch {}
    return $false
}

function Get-LogbookSessionType {
    if (Test-AnyDeskInteractiveWindow) { return @('AnyDesk', 1) }
    return @('Physical', 0)
}

function Get-ProcessByCommandPattern {
    param([string]$Pattern)
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.CommandLine -match $Pattern
        })
    } catch {
        return @()
    }
}

function Stop-LogbookTimers {
    try {
        $procs = Get-ProcessByCommandPattern 'logbook_timer\.ps1'
        foreach ($p in $procs) {
            if ([int]$p.ProcessId -ne [int]$PID) {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
        $pidFile = Join-Path $Global:StateDir 'timer.pid'
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } catch { Write-LogbookError "Stop timers failed: $($_.Exception.Message)" }
}

function Test-LogbookPopupRunning {
    $procs = Get-ProcessByCommandPattern 'logbook_popup\.ps1'
    foreach ($p in $procs) {
        if ([int]$p.ProcessId -ne [int]$PID) { return $true }
    }
    return $false
}

# Install-time-only, must run elevated. The popup/monitor run as a normal
# (often non-admin) user at runtime, and by default that account cannot
# write HKCU:\...\Policies\System even in its own hive (Windows locks that
# subtree down for exactly this reason). Elevation preserves the calling
# user's identity (HKCU still resolves to the same account, just with an
# elevated token — see the existing HKCU:\...\Run write a few lines below
# this function's caller), so this grants that one specific account just
# enough rights (SetValue + ReadKey on this one key, nothing broader) to
# toggle the sign-in gate at runtime without needing to be an admin.
# Idempotent — safe to call on every install/reinstall.
function Grant-LogbookTaskMgrGateAccess {
    $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
    $identity = "$env:USERDOMAIN\$env:USERNAME"
    try {
        if (-not (Test-Path $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
        $acl = Get-Acl -Path $keyPath
        $already = $acl.Access | Where-Object {
            $_.IdentityReference.Value -eq $identity -and
            $_.AccessControlType -eq 'Allow' -and
            ($_.RegistryRights -band [System.Security.AccessControl.RegistryRights]::SetValue)
        }
        if ($already) {
            Write-LogbookInfo "Task Manager gate: $identity already has write access."
            return
        }
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $identity,
            ([System.Security.AccessControl.RegistryRights]::SetValue -bor [System.Security.AccessControl.RegistryRights]::ReadKey),
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        Set-Acl -Path $keyPath -AclObject $acl
        Write-LogbookInfo "Task Manager gate: granted $identity write access."
    } catch {
        Write-LogbookError "Grant-LogbookTaskMgrGateAccess failed for ${identity}: $($_.Exception.Message)"
    }
}

# Gate Task Manager while the sign-in popup is showing, using the standard
# Windows policy Task Manager itself honors (shows "disabled by your
# administrator" instead of opening) rather than fighting the process.
# Scoped to the interactive user only (HKCU), and restores whatever value
# was there before (so it doesn't clobber a real admin/GPO-managed setting).
# Always call this in a try/finally around the popup's ShowDialog() so it
# is restored on every exit path, including exceptions.
function Set-TaskManagerDisabled {
    param([bool]$Disabled)
    $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
    $markerPath = Join-Path $Global:StateDir 'taskmgr_prev_value.txt'
    try {
        if ($Disabled) {
            $prev = 'none'
            if (Test-Path $keyPath) {
                $existing = Get-ItemProperty -Path $keyPath -Name 'DisableTaskMgr' -ErrorAction SilentlyContinue
                if ($null -ne $existing -and $null -ne $existing.DisableTaskMgr) { $prev = "$($existing.DisableTaskMgr)" }
            }
            New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
            $prev | Out-File -FilePath $markerPath -Encoding UTF8 -Force

            if (-not (Test-Path $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
            New-ItemProperty -Path $keyPath -Name 'DisableTaskMgr' -PropertyType DWord -Value 1 -Force | Out-Null
            Write-LogbookInfo "Task Manager disabled for sign-in gate."
        } else {
            $restoreVal = 'none'
            if (Test-Path $markerPath) {
                $restoreVal = (Get-Content $markerPath -Raw -ErrorAction SilentlyContinue).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($restoreVal) -or $restoreVal -eq 'none') {
                if (Test-Path $keyPath) { Remove-ItemProperty -Path $keyPath -Name 'DisableTaskMgr' -ErrorAction SilentlyContinue }
            } else {
                New-ItemProperty -Path $keyPath -Name 'DisableTaskMgr' -PropertyType DWord -Value ([int]$restoreVal) -Force | Out-Null
            }
            Remove-Item -Path $markerPath -Force -ErrorAction SilentlyContinue
            Write-LogbookInfo "Task Manager restored to prior state."
        }
    } catch {
        Write-LogbookError "Task Manager policy toggle failed: $($_.Exception.Message)"
    }
}

function Start-LogbookTimer {
    param([string]$SessionId = '')
    try {
        Stop-LogbookTimers
        $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_timer.ps1')
        if ($SessionId) { $args += @('-SessionId', $SessionId) }
        $timer = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $args
        $pidFile = Join-Path $Global:StateDir 'timer.pid'
        $timer.Id | Out-File -FilePath $pidFile -Encoding ascii -Force
        return $true
    } catch {
        Write-LogbookError "Timer start failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-LogbookPopup {
    param([switch]$ForceNew, [switch]$TestMode)
    try {
        if (Test-LogbookPopupRunning) { return $true }
        $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_popup.ps1')
        if ($ForceNew) { $args += '-ForceNew' }
        if ($TestMode) { $args += '-TestMode' }
        # IMPORTANT: do not use -WindowStyle Hidden here. It hides the WPF form too.
        Start-Process powershell.exe -ArgumentList $args | Out-Null
        return $true
    } catch {
        Write-LogbookError "Popup start failed: $($_.Exception.Message)"
        return $false
    }
}

# Whether to route bridge events through WSL (lab workstations, dual-boot
# boxes with a distro already set up for SSH logging) or call the native
# Python core directly (everything else, notably loaned/rented laptops --
# they typically have no WSL distro installed at all, which makes the WSL
# call fail outright; see logbook_error.log "no installed distributions").
# install/install.py already deploys log_physical.py + paths.py natively to
# LOGIX_HOME on every OS, so native is the safe default; WSL is opt-in via
# LOGIX_USE_WSL=1 in config.env (set by install_logbook_tasks.ps1 -UseWSL).
function Test-LogbookUseWSL {
    $val = Get-LogbookConfigEnv 'LOGIX_USE_WSL'
    return ($val -eq '1' -or $val -eq 'true')
}

function Get-LogixCoreDir {
    $logixHome = Get-LogbookConfigEnv 'LOGIX_HOME'
    if ($logixHome) { return $logixHome }
    return (Join-Path $env:ProgramData 'Logix')
}

function Find-LogixPython {
    foreach ($cmd in @('python', 'py')) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }
    return $null
}

function Invoke-WSLBridge {
    param([string]$PayloadPath, [string]$Event, [string]$SessionId)
    $wslPayloadPath = '/mnt/c/ProgramData/MindLabLogbook/' + (Split-Path $PayloadPath -Leaf)
    $output = & wsl.exe -u root -e /usr/bin/python3 /opt/software/logix/log_physical.py --json-file $wslPayloadPath 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-LogbookError "WSL root log returned exit code $rc for event $Event. Output: $output"
        $output = & wsl.exe -e /usr/bin/python3 /opt/software/logix/log_physical.py --json-file $wslPayloadPath 2>&1
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            Write-LogbookError "WSL user log returned exit code $rc for event $Event. Output: $output"
            return $false
        }
    }
    Write-LogbookInfo "WSL log OK event=$Event sid=$SessionId Output: $output"
    return $true
}

function Invoke-NativeBridge {
    param([string]$PayloadPath, [string]$Event, [string]$SessionId)
    $python = Find-LogixPython
    if (-not $python) {
        Write-LogbookError "Native bridge: no python/py found on PATH for event $Event"
        return $false
    }
    $script = Join-Path (Get-LogixCoreDir) 'log_physical.py'
    if (-not (Test-Path $script)) {
        Write-LogbookError "Native bridge: log_physical.py not found at $script (run install/install.py on this machine first) for event $Event"
        return $false
    }
    # Local ErrorActionPreference override: this file sets 'Stop' globally, and
    # under 'Stop' any stderr line from a native exe (2>&1) -- even a benign
    # informational one, like log_physical.py's local_only privacy notice --
    # gets promoted from a non-terminating to a terminating error and throws,
    # masquerading as a bridge failure. $LASTEXITCODE is the real signal.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $python $script --json-file $PayloadPath 2>&1
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($rc -ne 0) {
        Write-LogbookError "Native bridge returned exit code $rc for event $Event. Output: $output"
        return $false
    }
    Write-LogbookInfo "Native bridge log OK event=$Event sid=$SessionId Output: $output"
    return $true
}

function Invoke-WSLLogbook {
    param(
        [Parameter(Mandatory=$true)][string]$Event,
        [string]$SessionType = '',
        [int]$AnyDeskDetected = 0,
        [string]$SessionId = '',
        [string]$Nama = '',
        [string]$Nim = '',
        [string]$Tujuan = '',
        [string]$Keterangan = ''
    )
    Ensure-LogbookDirs
    $winUser = "$env:USERDOMAIN\$env:USERNAME"
    $payloadPath = Join-Path $Global:StateDir ("payload-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $payload = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        event = $Event
        username = $env:USERNAME
        windows_user = $winUser
        hostname = $env:COMPUTERNAME
        session_type = $SessionType
        source = 'windows_wpf'
        session_id = $SessionId
        nama = $Nama
        nim = $Nim
        tujuan = $Tujuan
        keterangan = $Keterangan
        anydesk_detected = $AnyDeskDetected
    }
    try {
        $payload | ConvertTo-Json -Depth 5 | Out-File -FilePath $payloadPath -Encoding UTF8 -Force
        Write-LogbookInfo "Bridge payload event=$Event sid=$SessionId nama=$Nama nim=$Nim tujuan=$Tujuan"
        if (Test-LogbookUseWSL) {
            return Invoke-WSLBridge -PayloadPath $payloadPath -Event $Event -SessionId $SessionId
        }
        return Invoke-NativeBridge -PayloadPath $payloadPath -Event $Event -SessionId $SessionId
    } catch {
        Write-LogbookError "Bridge log error for event ${Event}: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $payloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-LogbookDefaultConfig {
    # Built-in defaults. With no config file present the popup renders
    # these out of the box.
    return @{
        branding = @{
            logoText = 'Logix'
            logoPath = 'C:\lab\logo.png'
            title    = 'Report Logbook'
            subtitle = 'Computational Workstation'
            colors   = @{ primary = '#073763'; accent = '#741B47'; muted = '#C0C0C0'; text = '#FFFFFF' }
        }
        text = @{
            intro          = 'Isi data penggunaan workstation sebelum memulai sesi.'
            startHint      = 'Waktu mulai akan dicatat saat tombol Mulai sesi ditekan.'
            namaLabel      = 'Nama Pengguna'
            nimLabel       = 'NIM/NIP/NIK'
            accessLabel    = 'Tipe Akses'
            purposeLabel   = 'Tujuan Penggunaan'
            ketLabel       = 'Keterangan Kegiatan'
            submit         = 'Mulai Sesi'
            hint           = 'Mohon isi data dengan benar dan selengkap mungkin, apabila ada error atau kesalahan, segera hubungi admin.'
            hintIncomplete = 'Lengkapi Nama, NIM/ID, tipe akses, tujuan, dan keterangan.'
            hintReady      = 'Siap disimpan. Nama, NIM, tujuan, dan keterangan akan dikirim ke SQLite.'
        }
        accessTypes    = @('Physical', 'AnyDesk')
        purposes       = @('Visualisasi Data', 'Running Data', 'Maintenance')
        requiredFields = @('nama', 'nim', 'access', 'purpose', 'keterangan')
    }
}

function ConvertTo-LogbookHashtable($obj) {
    # JSON -> hashtable/array so config merges and member access stay uniform.
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-LogbookHashtable $p.Value }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return @($obj | ForEach-Object { ConvertTo-LogbookHashtable $_ })
    }
    return $obj
}

function Merge-LogbookConfig($base, $override) {
    # Deep-merge $override into $base. Objects merge key-by-key; arrays/scalars replace.
    if ($null -eq $override) { return $base }
    foreach ($key in @($override.Keys)) {
        if ($base.Contains($key) -and ($base[$key] -is [hashtable]) -and ($override[$key] -is [hashtable])) {
            Merge-LogbookConfig $base[$key] $override[$key]
        } else {
            $base[$key] = $override[$key]
        }
    }
    return $base
}

function Read-LogbookConfigFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content $Path -Raw -Encoding UTF8
        $raw = $raw -replace '^﻿', ''   # tolerate a leading BOM
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ConvertTo-LogbookHashtable ($raw | ConvertFrom-Json)
    } catch {
        Write-LogbookError "Config load failed for ${Path}: $($_.Exception.Message)"
        return $null
    }
}

function Get-LogbookConfigEnv {
    param([string]$Key)
    $envVal = [System.Environment]::GetEnvironmentVariable($Key)
    if ($envVal) { return $envVal }
    $cfgPath = 'C:\ProgramData\Logix\config.env'
    if (Test-Path $cfgPath) {
        try {
            $lines = Get-Content $cfgPath -ErrorAction SilentlyContinue
            if ($lines) {
                foreach ($line in $lines) {
                    $trimmed = $line.Trim()
                    if (-not $trimmed -or $trimmed.StartsWith('#') -or -not $trimmed.Contains('=')) { continue }
                    if ($trimmed.StartsWith('export ')) { $trimmed = $trimmed.Substring(7) }
                    $parts = $trimmed.Split('=', 2)
                    if ($parts.Count -eq 2) {
                        $k = $parts[0].Trim()
                        $v = $parts[1].Trim().Trim("'").Trim('"')
                        if ($k -eq $Key) { return $v }
                    }
                }
            }
        } catch {}
    }
    return ''
}

function Get-AnyDeskId {
    # Check standard per-user and system-wide AnyDesk system.conf files
    $paths = @(
        "$env:PROGRAMDATA\AnyDesk\system.conf",
        "$env:APPDATA\AnyDesk\system.conf"
    )
    foreach ($path in $paths) {
        if (Test-Path $path) {
            try {
                $lines = Get-Content $path -ErrorAction SilentlyContinue
                foreach ($line in $lines) {
                    if ($line -match 'ad\.anydesk\.id=([0-9]+)') {
                        return $Matches[1]
                    }
                }
            } catch {}
        }
    }
    # Check default install locations by calling AnyDesk --get-id
    $anydeskPaths = @(
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
        "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe"
    )
    foreach ($ap in $anydeskPaths) {
        if (Test-Path $ap) {
            try {
                $id = & $ap --get-id 2>$null
                $id = "$id".Trim()
                if ($id -match '^[0-9]+$') { return $id }
            } catch {}
        }
    }
    return ''
}

function Get-LogbookDeviceApiKey {
    # Per-device key from device.json (written by logbook_setup.ps1 on a
    # successful /api/enroll). Mirrors the server's own verify_api_key
    # fallback order: per-device key first, shared LOGIX_SERVER_API_KEY
    # from config.env as the bootstrap/unenrolled fallback.
    $identityPath = 'C:\ProgramData\Logix\device.json'
    if (Test-Path $identityPath) {
        try {
            $obj = Get-Content $identityPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($obj -and $obj.api_key) { return [string]$obj.api_key }
        } catch {}
    }
    return ''
}

function Get-LogbookDeviceDisplayName {
    # This device's local name preference, same source Send-LogbookHeartbeat
    # sends to the server -- also used by the timer widget so it shows the
    # same name the dashboard does (absent an admin rename; that's a
    # server-side override the agent doesn't need to know about).
    $deviceName = Get-LogbookConfigEnv -Key 'LOGIX_DEVICE_NAME'
    if ([string]::IsNullOrWhiteSpace($deviceName)) { $deviceName = $env:COMPUTERNAME }
    return $deviceName
}

function Send-LogbookHeartbeat {
    param(
        [Parameter(Mandatory=$true)][string]$Status
    )
    try {
        $serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
        if (-not $serverUrl) { return }
        $serverKey = Get-LogbookDeviceApiKey
        if (-not $serverKey) { $serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY' }

        $username = $env:USERNAME
        if (Test-Path $Global:SessionFile) {
            try {
                $s = Get-ActiveLogbookSession
                if ($s -and $s.nama) { $username = $s.nama }
                elseif ($s -and $s.username) { $username = $s.username }
            } catch {}
        }

        $anydeskId = Get-AnyDeskId
        $deviceName = Get-LogbookDeviceDisplayName

        # Outcomes for commands delivered on a *previous* heartbeat -- see
        # apply_command_acks() server-side. Read what's pending, send it,
        # and only clear the file once the server has actually confirmed
        # receipt (a dropped response leaves it for the next attempt --
        # at-least-once delivery, absorbed by the server's idempotent
        # "AND status = 'queued'" guard on re-application).
        $acksPath = Join-Path $Global:StateDir 'pending_acks.json'
        $pendingAcks = @()
        if (Test-Path $acksPath) {
            try {
                $loaded = Get-Content $acksPath -Raw | ConvertFrom-Json
                if ($loaded) { $pendingAcks = @($loaded) }
            } catch {}
        }

        $payload = @{
            hostname    = $env:COMPUTERNAME
            device_name = $deviceName
            status      = $Status
            username    = $username
            anydesk_id  = $anydeskId
        }
        if ($pendingAcks.Count -gt 0) { $payload['acks'] = $pendingAcks }

        $headers = @{
            'Content-Type' = 'application/json'
        }
        if ($serverKey) { $headers['X-API-Key'] = $serverKey }
        $body = $payload | ConvertTo-Json -Depth 5
        $apiUrl = $serverUrl.TrimEnd('/') + '/api/heartbeat'

        $res = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $body -Headers $headers -TimeoutSec 3 -UseBasicParsing
        # Reaching here means the POST succeeded -- the acks we just sent
        # are now the server's problem.
        if ($pendingAcks.Count -gt 0) {
            Remove-Item $acksPath -Force -ErrorAction SilentlyContinue
        }

        $newAcks = @()
        if ($res -and $res.commands) {
            foreach ($cmd in $res.commands) {
                $name = $cmd.command.ToUpper()
                $param = $cmd.param
                Write-LogbookInfo "Received remote command: $name (param: $param)"

                if ($name -eq 'LOCK') {
                    Write-LogbookInfo "Remote LOCK trigger execution."
                    try {
                        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_end.ps1','-Reason','LOCK') | Out-Null
                        Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_popup.ps1','-ForceNew') | Out-Null
                        $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = '' }
                    } catch {
                        $newAcks += @{ command_id = $cmd.command_id; status = 'failed'; detail = $_.Exception.Message }
                    }
                }
                elseif ($name -eq 'BROADCAST') {
                    # Drop for the timer widget to pick up on its next tick
                    # and show inline, near the timer -- not a separate
                    # MessageBox popup. Same file-drop-and-poll idiom as
                    # session.json/popup.lock/timer.pid; there's no other
                    # IPC channel between this process (the monitor loop)
                    # and the timer's own separate powershell.exe process.
                    # "done" here means the file was written for the timer
                    # to pick up, not that the user has seen/dismissed it.
                    Write-LogbookInfo "Remote message received (reason: $($cmd.reason))."
                    try {
                        Ensure-LogbookDirs
                        $msgPath = Join-Path $Global:StateDir 'incoming_message.json'
                        $reason = if ($cmd.reason) { [string]$cmd.reason } else { 'Direction Message' }
                        @{ text = $param; reason = $reason; received_at = (Get-Date).ToString('o') } |
                            ConvertTo-Json | Out-File -FilePath $msgPath -Encoding UTF8 -Force
                        $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = '' }
                    } catch {
                        $newAcks += @{ command_id = $cmd.command_id; status = 'failed'; detail = $_.Exception.Message }
                    }
                }
            }
        }

        # Persist immediately after executing, before this function's own
        # outer try/catch has any chance to swallow a later error -- this is
        # what guarantees an outcome is never silently lost. If the file
        # already has unsent acks from an earlier failed delivery attempt,
        # append rather than overwrite.
        if ($newAcks.Count -gt 0) {
            $existing = @()
            if (Test-Path $acksPath) {
                try {
                    $loaded = Get-Content $acksPath -Raw | ConvertFrom-Json
                    if ($loaded) { $existing = @($loaded) }
                } catch {}
            }
            ($existing + $newAcks) | ConvertTo-Json -Depth 5 | Out-File -FilePath $acksPath -Encoding UTF8 -Force
        }
    } catch {
        # Fail silently
    }
}

function Get-LogbookConfig {
    # Cascading: built-in defaults <- machine config <- per-user config.
    $cfg = Get-LogbookDefaultConfig
    
    # Try to fetch from central server first
    $serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
    $serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY'
    $serverCfg = $null
    
    $cachePath = Join-Path $Global:StateDir 'server_config_cache.json'
    
    if ($serverUrl) {
        try {
            $headers = @{}
            if ($serverKey) { $headers['X-API-Key'] = $serverKey }
            $apiUrl = $serverUrl.TrimEnd('/') + '/api/config'
            Write-LogbookInfo "Fetching config from server: $apiUrl"
            # 2 second timeout to not block UI startup if server is offline
            $res = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 2 -UseBasicParsing
            if ($res) {
                $serverCfg = ConvertTo-LogbookHashtable $res
                # Save to cache
                New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
                $res | ConvertTo-Json -Depth 5 | Out-File -FilePath $cachePath -Encoding UTF8 -Force
                Write-LogbookInfo "Cached config from server."
            }
        } catch {
            Write-LogbookError "Failed to fetch server config: $($_.Exception.Message). Falling back to cache/local."
        }
    }
    
    # If server fetch failed, try to load from local cache
    if (-not $serverCfg -and (Test-Path $cachePath)) {
        $serverCfg = Read-LogbookConfigFile $cachePath
        if ($serverCfg) {
            Write-LogbookInfo "Applied cached server config."
        }
    }
    
    if ($serverCfg) {
        $cfg = Merge-LogbookConfig $cfg $serverCfg
    }
    
    $machine = Join-Path $Global:LabDir 'logbook_config.json'
    $perUser = Join-Path (Join-Path $env:APPDATA 'MindLabLogbook') 'logbook_config.json'
    foreach ($path in @($machine, $perUser)) {
        $override = Read-LogbookConfigFile $path
        if ($override) {
            $cfg = Merge-LogbookConfig $cfg $override
            Write-LogbookInfo "Applied config override: $path"
        }
    }
    return $cfg
}

function ConvertTo-LogbookXmlText([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Build-LogbookPopupXaml($cfg) {
    # Render the popup XAML from config. Pure string building (no WPF), so it is
    # unit-testable by parsing the result as [xml].
    $primary = [string]$cfg.branding.colors.primary
    $accent  = [string]$cfg.branding.colors.accent
    $muted   = [string]$cfg.branding.colors.muted
    $text    = [string]$cfg.branding.colors.text
    $overlay = "#B0" + $accent.TrimStart('#')

    $logoText = ConvertTo-LogbookXmlText ([string]$cfg.branding.logoText)
    $title    = ConvertTo-LogbookXmlText ([string]$cfg.branding.title)
    $subtitle = ConvertTo-LogbookXmlText ([string]$cfg.branding.subtitle)
    $tIntro   = ConvertTo-LogbookXmlText ([string]$cfg.text.intro)
    $tStart   = ConvertTo-LogbookXmlText ([string]$cfg.text.startHint)
    $tNama    = ConvertTo-LogbookXmlText ([string]$cfg.text.namaLabel)
    $tNim     = ConvertTo-LogbookXmlText ([string]$cfg.text.nimLabel)
    $tAccess  = ConvertTo-LogbookXmlText ([string]$cfg.text.accessLabel)
    $tPurpose = ConvertTo-LogbookXmlText ([string]$cfg.text.purposeLabel)
    $tKet     = ConvertTo-LogbookXmlText ([string]$cfg.text.ketLabel)
    $tSubmit  = ConvertTo-LogbookXmlText ([string]$cfg.text.submit)
    $tHint    = ConvertTo-LogbookXmlText ([string]$cfg.text.hint)

    $accessItems  = (@($cfg.accessTypes) | ForEach-Object { "                <ComboBoxItem Content=`"$(ConvertTo-LogbookXmlText $_)`" />" }) -join "`r`n"
    $purposeItems = (@($cfg.purposes)    | ForEach-Object { "                <ComboBoxItem Content=`"$(ConvertTo-LogbookXmlText $_)`" />" }) -join "`r`n"

    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="False" Background="$accent"
        FontFamily="Poppins, Montserrat, Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="PrussianBlue" Color="$primary" />
    <SolidColorBrush x:Key="Silver" Color="$muted" />
    <SolidColorBrush x:Key="Pompadour" Color="$accent" />
    <SolidColorBrush x:Key="WhiteBrush" Color="$text" />

    <Style x:Key="LabelTextStyle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Poppins, Montserrat, Segoe UI" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="FontSize" Value="13" />
      <Setter Property="Foreground" Value="$text" />
      <Setter Property="Margin" Value="0,0,0,7" />
    </Style>

    <Style x:Key="InputTextBoxStyle" TargetType="TextBox">
      <Setter Property="Height" Value="44" />
      <Setter Property="Padding" Value="12,8" />
      <Setter Property="FontFamily" Value="Montserrat, Poppins, Segoe UI" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="Medium" />
      <Setter Property="BorderBrush" Value="$muted" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Background" Value="$primary" />
      <Setter Property="Foreground" Value="$text" />
      <Setter Property="CaretBrush" Value="$text" />
      <Setter Property="SelectionBrush" Value="$accent" />
      <Setter Property="SelectionTextBrush" Value="$text" />
    </Style>

    <Style x:Key="ReadableComboBoxItemStyle" TargetType="ComboBoxItem">
      <Setter Property="FontFamily" Value="Poppins, Montserrat, Segoe UI" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Background" Value="$text" />
      <Setter Property="Foreground" Value="$accent" />
      <Setter Property="Padding" Value="10,7" />
      <Setter Property="MinHeight" Value="36" />
      <Setter Property="BorderBrush" Value="#E6E6E6" />
      <Setter Property="BorderThickness" Value="0,0,0,1" />
    </Style>

    <Style x:Key="ReadableComboBoxStyle" TargetType="ComboBox">
      <Setter Property="Height" Value="44" />
      <Setter Property="Padding" Value="8,6" />
      <Setter Property="FontFamily" Value="Poppins, Montserrat, Segoe UI" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Background" Value="$text" />
      <Setter Property="Foreground" Value="$accent" />
      <Setter Property="BorderBrush" Value="$muted" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="TextElement.Foreground" Value="$accent" />
      <Setter Property="ItemContainerStyle" Value="{StaticResource ReadableComboBoxItemStyle}" />
    </Style>
  </Window.Resources>

  <Grid>
    <Image Name="BgImage" Stretch="Fill" Opacity="0.88">
      <Image.Effect><BlurEffect Radius="24" KernelType="Gaussian" /></Image.Effect>
    </Image>
    <Rectangle Fill="$overlay" />

    <Border Width="790" CornerRadius="18" BorderBrush="$muted" BorderThickness="1" Background="$primary"
            HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True">
      <Border.Effect><DropShadowEffect BlurRadius="32" ShadowDepth="0" Opacity="0.42" Color="$accent" /></Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto" />
          <RowDefinition Height="*" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" CornerRadius="18,18,0,0" Padding="30,22,30,22" BorderBrush="$text" BorderThickness="0,0,0,1">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="330" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <Image Grid.Column="0" Name="LogoImage" Width="260" Height="72" Stretch="Uniform" HorizontalAlignment="Left" VerticalAlignment="Center"
                   SnapsToDevicePixels="True" RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed" />
            <TextBlock Grid.Column="0" Name="LogoText" Text="$logoText" FontFamily="Poppins, Montserrat, Segoe UI Semibold" FontSize="30"
                       FontWeight="SemiBold" Foreground="$text" VerticalAlignment="Center" />
            <StackPanel Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Right">
              <TextBlock Text="$title" FontFamily="Poppins, Montserrat, Segoe UI" FontSize="29" FontWeight="SemiBold"
                         Foreground="$text" HorizontalAlignment="Right" />
              <TextBlock Text="$subtitle" FontFamily="Montserrat, Poppins, Segoe UI" FontSize="14" Foreground="$muted"
                         HorizontalAlignment="Right" Margin="0,2,0,0" />
            </StackPanel>
          </Grid>
        </Border>

        <StackPanel Grid.Row="1" Margin="36,28,36,34">
          <TextBlock Text="$tIntro" FontFamily="Poppins, Montserrat, Segoe UI" FontSize="12.5"
                     FontWeight="SemiBold" Foreground="$text" Margin="0,0,0,7" />
          <TextBlock Name="StartTimeText" Text="$tStart" FontFamily="Montserrat, Poppins, Segoe UI"
                     FontSize="12" Foreground="$muted" Margin="0,0,0,18" />

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="18" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <TextBlock Text="$tNama" Style="{StaticResource LabelTextStyle}" />
              <TextBox Name="NamaBox" Style="{StaticResource InputTextBoxStyle}" Margin="0,0,0,15" />
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="$tNim" Style="{StaticResource LabelTextStyle}" />
              <TextBox Name="NimBox" Style="{StaticResource InputTextBoxStyle}" Margin="0,0,0,15" />
            </StackPanel>
          </Grid>

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="230" />
              <ColumnDefinition Width="18" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <TextBlock Text="$tAccess" Style="{StaticResource LabelTextStyle}" />
              <ComboBox Name="AccessBox" Style="{StaticResource ReadableComboBoxStyle}" IsEditable="True" IsReadOnly="True" Margin="0,0,0,15">
$accessItems
              </ComboBox>
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="$tPurpose" Style="{StaticResource LabelTextStyle}" />
              <ComboBox Name="TujuanBox" Style="{StaticResource ReadableComboBoxStyle}" IsEditable="True" IsReadOnly="True" Margin="0,0,0,15">
$purposeItems
              </ComboBox>
            </StackPanel>
          </Grid>

          <TextBlock Text="$tKet" Style="{StaticResource LabelTextStyle}" />
          <TextBox Name="KetBox" Style="{StaticResource InputTextBoxStyle}" Height="122" Padding="12,10" TextWrapping="Wrap" AcceptsReturn="True"
                   VerticalScrollBarVisibility="Auto" Margin="0,0,0,20" />

          <Grid Margin="0,0,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="18" />
              <ColumnDefinition Width="198" />
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="$primary" CornerRadius="10" Padding="12,9" BorderBrush="$muted" BorderThickness="1">
              <TextBlock Name="HintText" Text="$tHint"
                         FontFamily="Montserrat, Poppins, Segoe UI" FontSize="11.5" FontWeight="SemiBold" Foreground="$muted" TextWrapping="Wrap" />
            </Border>
            <Button Grid.Column="2" Name="SubmitBtn" Height="48" Content="$tSubmit" FontFamily="Poppins, Montserrat, Segoe UI"
                    FontSize="21" FontWeight="Bold" Background="$accent" Foreground="$text" BorderBrush="$muted"
                    BorderThickness="1" IsEnabled="False" Opacity="0.45" />
          </Grid>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
"@
}

# Chamfered-rounded shape path data (three rounded corners, a diagonal
# chamfer replacing the top-right one), parameterized by content height and
# width so it can be recomputed at runtime as the timer widget grows/shrinks
# (collapsed clock-only <-> expanded info <-> message extension). r/c are
# fixed; height and width vary. See logbook_timer.ps1's
# Sync-LogbookTimerShape.
function Get-LogbookTimerShapeData([double]$ContentHeight, [double]$ContentWidth = 320) {
    $r = 20; $c = 44
    # Clamped to a sane range -- defense in depth against any future bug
    # feeding this a wildly wrong size (a prior version of the
    # message-extend animation had exactly that bug, filling the screen).
    $h = [Math]::Round([Math]::Min([Math]::Max($ContentHeight, 90), 500))
    $w = [Math]::Round([Math]::Min([Math]::Max($ContentWidth, 150), 500))
    return "M $r,0 L $($w-$c),0 L $w,$c L $w,$($h-$r) A $r,$r 0 0 1 $($w-$r),$h L $r,$h A $r,$r 0 0 1 0,$($h-$r) L 0,$r A $r,$r 0 0 1 $r,0 Z"
}

# Session timer widget (Logix Control dashboard follow-up). Same
# pure-string-building pattern as Build-LogbookPopupXaml above -- config-
# driven colors, XML-escaped free-text inputs. The shape is a single Path
# geometry used both as the border/fill layer and, via Grid.Clip, to clip
# the content layer so nothing renders past the cut corner.
# Base fill is a fixed near-black -- "dominated by black" is a deliberate
# constant, not config-driven; only the primary/accent accents come from
# branding.colors.
#
# Width is FIXED at the narrow clock width -- the widget must only ever
# grow DOWNWARD (an explicit product decision; a first iteration that also
# widened on hover was rejected). Height is driven by two independently
# toggleable sections --
#   InfoSection    (nama/tujuan/device + accent bar): visible for the
#                  first 10s of a session or while the user hovers the
#                  widget, collapsed otherwise so the user can focus on
#                  the time, not the data.
#   MessageSection (an incoming admin message): collapsed by default,
#                  animated open/closed by logbook_timer.ps1, extending
#                  the shape downward from wherever it currently ends --
#                  below the timer if InfoSection is collapsed, below the
#                  full info block if it's expanded.
# Both sections are Grid rows sized "Auto", so a Collapsed section takes
# zero space -- no reserved blank area, unlike an earlier "*"-row design.
# Everything inside must fit the narrow width: values ellipsize, message
# text wraps.
function Build-LogbookTimerXaml($cfg, $session, $deviceName) {
    $primary = [string]$cfg.branding.colors.primary
    $accent  = [string]$cfg.branding.colors.accent
    $muted   = [string]$cfg.branding.colors.muted
    $text    = [string]$cfg.branding.colors.text

    $sessionType = ConvertTo-LogbookXmlText ([string]$session.session_type)
    $nama        = ConvertTo-LogbookXmlText ([string]$session.nama)
    $tujuan      = ConvertTo-LogbookXmlText ([string]$session.tujuan)
    $device      = ConvertTo-LogbookXmlText ([string]$deviceName)

    # Fixed initial height (matches HEIGHT_EXPANDED in logbook_timer.ps1 --
    # InfoSection defaults to Visible). Deliberately NOT SizeToContent --
    # two earlier attempts at having WPF auto-size the window (first via
    # SizeToContent toggling, then via Measure()/DesiredSize) both produced
    # wrong/huge heights that only surfaced on a live Windows run, not in
    # XML-structural tests. logbook_timer.ps1 owns height transitions
    # entirely via a small set of fixed target heights instead. Width 230
    # (shape 210) is the permanent width -- sized for the clock, verified
    # headlessly to fit worst-case digits with slack.
    $seedShapeData = Get-LogbookTimerShapeData 190 210

    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="230" Height="210" WindowStyle="None" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" AllowsTransparency="True" Background="Transparent" Left="18" Top="18">
  <Grid>
    <Path Name="ShapePath" Margin="10" Fill="#0B0F19" Stroke="$primary" StrokeThickness="1.3" Data="$seedShapeData">
      <Path.Effect>
        <DropShadowEffect BlurRadius="22" ShadowDepth="0" Opacity="0.45" Color="$primary" />
      </Path.Effect>
    </Path>

    <Grid Name="ContentGrid" Margin="10" Clip="$seedShapeData">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="18,14,18,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Ellipse Name="Pulse" Width="8" Height="8" Fill="$accent" Margin="0,3,8,0" VerticalAlignment="Center" />
        <TextBlock Name="Label" Grid.Column="1" Text="$sessionType" FontFamily="Segoe UI Semibold" FontSize="11" Foreground="$muted" TextTrimming="CharacterEllipsis" />
      </Grid>

      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="18,4,18,10" VerticalAlignment="Bottom">
        <TextBlock Name="ClockMain" Text="00:00" FontFamily="Consolas" FontSize="40" FontWeight="Bold" Foreground="$text"/>
        <TextBlock Name="ClockSeconds" Text="00" FontFamily="Consolas" FontSize="16" FontWeight="Bold" Foreground="$primary" Margin="4,0,0,6" VerticalAlignment="Bottom"/>
      </StackPanel>

      <StackPanel Grid.Row="2" Name="InfoSection" Visibility="Visible">
        <Border Height="1" Background="#22FFFFFF" Margin="18,0,18,8"/>

        <Grid Margin="18,0,18,4">
          <Grid.ColumnDefinitions><ColumnDefinition Width="48"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock Text="Nama" FontFamily="Segoe UI" FontSize="10.5" Foreground="$muted"/>
          <TextBlock Grid.Column="1" Name="NamaValue" Text="$nama" FontFamily="Segoe UI Semibold" FontSize="10.5" Foreground="$text" TextTrimming="CharacterEllipsis"/>
        </Grid>

        <Grid Margin="18,0,18,4">
          <Grid.ColumnDefinitions><ColumnDefinition Width="48"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock Text="Tujuan" FontFamily="Segoe UI" FontSize="10.5" Foreground="$muted"/>
          <TextBlock Grid.Column="1" Name="TujuanValue" Text="$tujuan" FontFamily="Segoe UI Semibold" FontSize="10.5" Foreground="$text" TextTrimming="CharacterEllipsis"/>
        </Grid>

        <Grid Margin="18,0,18,8">
          <Grid.ColumnDefinitions><ColumnDefinition Width="48"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock Text="Device" FontFamily="Segoe UI" FontSize="10.5" Foreground="$muted"/>
          <TextBlock Grid.Column="1" Name="DeviceValue" Text="$device" FontFamily="Segoe UI Semibold" FontSize="10.5" Foreground="$text" TextTrimming="CharacterEllipsis"/>
        </Grid>

        <Border Height="4" Margin="18,0,18,14" CornerRadius="2">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="$primary" Offset="0"/>
              <GradientStop Color="$accent" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>
      </StackPanel>

      <Border Grid.Row="3" Name="MessageSection" Visibility="Collapsed" Margin="14,0,14,14" Padding="10,10" CornerRadius="10"
              Background="#16FFFFFF" BorderThickness="3,1,1,1" BorderBrush="$accent">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Name="MessageIconBadge" Grid.Column="0" Width="24" Height="24" CornerRadius="12" Background="$accent" VerticalAlignment="Top" Margin="0,1,10,0">
            <TextBlock Name="MessageIcon" Text="!" FontFamily="Segoe UI Semibold" FontSize="12" Foreground="#0B0F19" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Grid.Column="1">
            <TextBlock Name="MessageTitle" Text="Emergency Alert" FontFamily="Segoe UI Semibold" FontSize="11" Foreground="$accent"/>
            <TextBlock Name="MessageText" Text="" FontFamily="Segoe UI" FontSize="10.5" Foreground="$text" TextWrapping="Wrap" Margin="0,2,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
"@
}

function Get-ActiveLogbookSession {
    try {
        if (Test-Path $Global:SessionFile) {
            return (Get-Content $Global:SessionFile -Raw | ConvertFrom-Json)
        }
    } catch { Write-LogbookError "Read active session failed: $($_.Exception.Message)" }
    return $null
}

function Get-ActiveLogbookSessionAgeSeconds {
    $session = Get-ActiveLogbookSession
    if ($null -eq $session -or -not $session.start_time) { return $null }
    try {
        $start = [datetime]$session.start_time
        return [int]((Get-Date) - $start).TotalSeconds
    } catch { return $null }
}

function Close-ActiveLogbookSession {
    param([string]$Reason = 'END')
    Ensure-LogbookDirs
    try {
        if (Test-Path $Global:SessionFile) {
            $session = Get-Content $Global:SessionFile -Raw | ConvertFrom-Json
            [void](Invoke-WSLLogbook -Event $Reason -SessionType $session.session_type -AnyDeskDetected ([int]$session.anydesk_detected) -SessionId $session.session_id -Nama $session.nama -Nim $session.nim -Tujuan $session.tujuan -Keterangan $session.keterangan)
            Remove-Item $Global:SessionFile -Force -ErrorAction SilentlyContinue
            Write-LogbookInfo "Closed active session sid=$($session.session_id) reason=$Reason"
        }
        Stop-LogbookTimers
        return $true
    } catch {
        Write-LogbookError "Close active session failed: $($_.Exception.Message)"
        Stop-LogbookTimers
        return $false
    }
}

function Get-SystemBootTime {
    try {
        return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch {
        Write-LogbookError "Get boot time failed: $($_.Exception.Message)"
        return $null
    }
}

# A session file that predates the machine's most recent boot means whatever
# was supposed to close it (lock/logoff/shutdown handler) never finished --
# e.g. a hard shutdown killed the process before the WSL call completed, or
# the shutdown reason simply wasn't one Windows delivered to this process in
# time. Resuming it blindly (the old behavior) lets elapsed time keep
# accumulating across reboots -- this is how a session was observed still
# "active" 16 hours later. Call this before resuming any on-disk session.
function Close-StaleLogbookSessionIfAny {
    if (-not (Test-Path $Global:SessionFile)) { return $false }
    $session = Get-ActiveLogbookSession
    if ($null -eq $session -or -not $session.start_time) { return $false }
    try {
        $start = [datetime]$session.start_time
        $bootTime = Get-SystemBootTime
        if ($null -eq $bootTime) { return $false }
        if ($bootTime -gt $start) {
            Write-LogbookInfo "Stale session detected sid=$($session.session_id) started=$($session.start_time) boot=$($bootTime.ToString('o')); auto-closing instead of resuming."
            Close-ActiveLogbookSession -Reason 'AUTO_CLOSE' | Out-Null
            return $true
        }
    } catch { Write-LogbookError "Stale session check failed: $($_.Exception.Message)" }
    return $false
}
