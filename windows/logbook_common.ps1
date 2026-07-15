# MindLab Report Logbook common helpers v5.7
$ErrorActionPreference = 'Stop'

# Program scripts live in $Global:InstallDir (Program Files) -- read-only at
# runtime, written only by the elevated installer. All WRITABLE runtime state
# (session.json, timer.pid, the error log, markers) lives in $Global:StateDir
# under %ProgramData%, which the non-elevated agent can create and modify. The
# error log was historically in the program dir (C:\lab); it moved to StateDir
# because Program Files is not writable by the standard-user runtime.
$Global:InstallDir = 'C:\Program Files\Logix'
$Global:LabDir = $Global:InstallDir   # back-compat alias for older references
$Global:StateDir = Join-Path $env:ProgramData 'MindLabLogbook'
$Global:SessionFile = Join-Path $Global:StateDir 'session.json'
$Global:ErrorLog = Join-Path $Global:StateDir 'logbook_error.log'
$Global:PopupLock = Join-Path $Global:StateDir 'popup.lock'

function Write-LogbookError {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
        "$(Get-Date -Format o) $Message" | Out-File -FilePath $Global:ErrorLog -Append -Encoding UTF8
    } catch {}
}

function Write-LogbookInfo {
    param([string]$Message)
    Write-LogbookError "INFO: $Message"
}

# Only the writable StateDir is created at runtime; InstallDir (Program Files)
# is provisioned by the elevated installer, not here.
function Ensure-LogbookDirs {
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
# elevated token - see the existing HKCU:\...\Run write a few lines below
# this function's caller), so this grants that one specific account just
# enough rights (SetValue + ReadKey on this one key, nothing broader) to
# toggle the sign-in gate at runtime without needing to be an admin.
# Idempotent - safe to call on every install/reinstall.
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

# Runtime processes (monitor/popup/timer) must be able to DELETE state files in
# $Global:StateDir -- most importantly session.json, whose removal is what
# actually ends a session (SELESAI / END / AUTO_CLOSE / idle-timeout). If any of
# those processes ever ran elevated (an old scheduled task registered with
# -RunLevel Highest, or a manual elevated restart helper), the files it created
# are owned by BUILTIN\Administrators with no delete right for the normal
# interactive account. A later NON-elevated run then logs the END event but
# silently fails to remove session.json, leaving a "zombie" session: its timer
# keeps counting (even from a previous day) and the next unlock shows no sign-in
# form because the popup sees a session still on disk and only resumes the timer.
# This grants the interactive user an inheritable Modify ACE on the state dir so
# every file created there -- whoever creates it -- stays deletable by that user,
# and repairs any children already orphaned by a past elevated run. Install-time
# only: resetting admin-owned children requires running elevated.
function Grant-LogbookStateDirAccess {
    $identity = "$env:USERDOMAIN\$env:USERNAME"
    try {
        New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
        $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
                   [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $acl = Get-Acl -Path $Global:StateDir
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::Modify,
            $inherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)))
        Set-Acl -Path $Global:StateDir -AclObject $acl
        # Children created before this ACE never inherited it and may still be
        # admin-owned -- grant the same right on each directly so the current
        # session.json/timer.pid become removable by this account immediately.
        foreach ($child in @(Get-ChildItem -Path $Global:StateDir -Force -ErrorAction SilentlyContinue)) {
            try {
                $childAcl = Get-Acl -Path $child.FullName
                $childAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $identity,
                    [System.Security.AccessControl.FileSystemRights]::Modify,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
                Set-Acl -Path $child.FullName -AclObject $childAcl
            } catch {
                Write-LogbookError "State dir child ACL repair failed for $($child.FullName): $($_.Exception.Message)"
            }
        }
        Write-LogbookInfo "State dir access ensured for $identity on $Global:StateDir."
    } catch {
        Write-LogbookError "Grant-LogbookStateDirAccess failed for ${identity}: $($_.Exception.Message)"
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
        $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\Program Files\Logix\logbook_timer.ps1')
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
        $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\Program Files\Logix\logbook_popup.ps1')
        if ($ForceNew) { $args += '-ForceNew' }
        if ($TestMode) { $args += '-TestMode' }
        # -WindowStyle Hidden hides only the powershell CONSOLE window, not the
        # WPF form the popup opens with ShowDialog() -- the timer widget launches
        # exactly this way and renders fine. Keeps a stray console from sitting
        # on the user's desktop for the whole session.
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args | Out-Null
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
            logoPath = 'C:\Program Files\Logix\logo.png'
            title    = 'Report Logbook'
            subtitle = 'Computational Workstation'
            # LogiX Client Foundation palette (docs/design/LogiX Client
            # Foundation.dc.html): "Blue is the direction; everything else is a
            # theme." Accent #2563EB on a deep-navy surface ramp. Maroon retired.
            # A lab re-themes by overriding any of these in config -- absent keys
            # fall back to these defaults via Get-LogbookTheme.
            colors   = @{
                primary         = '#0E1626'  # elevated surface (cards / inputs)
                accent          = '#2563EB'  # brand blue
                muted           = '#93A1B8'  # muted text / hairline captions
                text            = '#EEF3FB'  # primary text
                surface         = '#070C15'  # deepest surface (fullscreen popup)
                surfaceWidget   = '#0B1017'  # corner timer widget surface
                surfaceElevated = '#0E1626'  # raised panels / inputs
                border          = '#223451'  # 1px hairline border
            }
            # Solid "signal bar" colors -- status is a colored edge on a calm
            # surface, never a tinted card. Normal/Notice/Warning/Critical.
            signals  = @{
                normal   = '#22C55E'  # session running
                notice   = '#3B82F6'  # privacy / screenshot (calm, never red)
                warning  = '#F59E0B'  # attention
                critical = '#EF4444'  # power countdown / urgent
            }
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
            hintReady      = 'Siap disimpan. Tuliskan keterangan kegiatan sedetail mungkin agar mudah dipahami admin -- hanya nama, NIM, tipe akses, tujuan, dan keterangan yang dicatat, bukan aktivitas di layar Anda.'
            # --- Client Copy Deck (docs/design/LogiX Copy Deck.dc.html) ---
            # Returning-user fast path (C8.1)
            welcomeBack      = 'Lanjutkan sesi Anda'
            continueAs       = 'Lanjut sebagai {0}'
            notYou           = 'Bukan saya / ganti data'
            whatsRecorded    = 'Apa yang dicatat?'
            privacyOneLiner  = 'Siapa, cara & kapan - bukan ketikan.'
            # Timer widget (C8.2)
            timerEnd         = 'SELESAI'
            timerEndArmed    = 'Tekan lagi untuk selesai'
            timerNama        = 'Nama'
            timerTujuan      = 'Tujuan'
            timerPerangkat   = 'Perangkat'
            # Notifications (C8.3)
            msgFromAdmin     = 'Pesan dari Admin'
            msgReply         = 'Balas'
            msgClose         = 'Tutup'
            noticePrivacyTitle = 'Pemberitahuan Privasi'
            noticeScreenshot = 'Admin baru saja mengambil tangkapan layar perangkat ini untuk keperluan pemantauan.'
            noticeAlwaysTold = 'Anda selalu diberi tahu - tidak pernah diam-diam.'
            noticeAck        = 'Mengerti'
            emergencyTitle   = 'Peringatan Sistem'
            emergencyBody    = 'Perangkat ini akan dimatikan oleh admin. Simpan pekerjaan Anda sekarang.'
            emergencySaved   = 'Saya sudah menyimpan'
            # Lock overlay (C8.4)
            lockTitle        = 'Workstation dikunci oleh admin lab'
            lockPausedNote   = 'Sesi Anda dijeda, bukan diakhiri. Semua pekerjaan & waktu sesi tetap tersimpan.'
            lockPausedBadge  = 'DIJEDA'
            lockElapsedLabel = 'Waktu sesi berjalan'
            lockUserLabel    = 'Pengguna'
            lockReasonLabel  = 'Alasan dari admin'
            lockUnlockHint   = 'Masuk kembali untuk melanjutkan sesi'
            lockUnlockBtn    = 'Buka & Lanjutkan'
            # Setup wizard (C8.4)
            setupWelcomeBody = 'Daftarkan komputer ini ke server lab agar sesi & kehadiran tercatat otomatis. Butuh kode undangan dari admin.'
            setupStart       = 'Mulai'
            setupSkip        = 'Lewati (mode lokal saja)'
            setupCodeTitle   = 'Masukkan kode undangan'
            setupCodeHint    = 'Minta kode dari admin lab. Berlaku 15 menit & hanya sekali pakai.'
            setupVerify      = 'Verifikasi'
            setupConfirmTitle = 'Konfirmasi perangkat'
            setupFinish      = 'Selesaikan Pengaturan'
            # English locale (future). Get-LogbookText falls back to the ID
            # string above for any key missing here, so 'en' is safe to grow
            # incrementally.
            en = @{
                intro          = 'Fill in your session details to start using this workstation.'
                submit         = 'Start Session'
                hintIncomplete = 'Please complete name, ID, access type, purpose, and notes.'
                hintReady      = 'Ready to save. Describe your activity in as much detail as you can -- only your name, ID, access type, purpose, and notes are recorded, never what is on your screen.'
                welcomeBack    = 'Continue your session'
                continueAs     = 'Continue as {0}'
                notYou         = 'Not you / change details'
                whatsRecorded  = "What's recorded?"
                timerEnd       = 'END'
                timerEndArmed  = 'Press again to end'
                timerNama      = 'Name'; timerTujuan = 'Purpose'; timerPerangkat = 'Device'
                msgFromAdmin   = 'Message from Admin'; msgReply = 'Reply'; msgClose = 'Close'
                noticePrivacyTitle = 'Privacy Notice'
                noticeAlwaysTold = 'You are always notified - never silently.'
                noticeAck      = 'Got it'
                emergencyTitle = 'System Alert'
                emergencySaved = 'I have saved'
                lockTitle      = 'Workstation locked by the lab admin'
                lockPausedBadge = 'PAUSED'
                lockUnlockBtn  = 'Unlock & Resume'
                setupStart     = 'Start'; setupVerify = 'Verify'; setupFinish = 'Finish Setup'
            }
        }
        # UI language for client surfaces. 'id' (default) or 'en'. Resolved by
        # Get-LogbookText, which falls back to the ID string for any key the
        # chosen locale hasn't translated yet.
        locale         = 'id'
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
        $raw = $raw -replace '^', ''   # tolerate a leading BOM
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

# Writes the single incoming-message drop the timer widget polls each tick and
# shows inline near the clock. allow_reply lets the widget offer a reply box for
# admin messages (BROADCAST) but not for one-way notices (screenshot/power).
function Set-LogbookIncomingMessage {
    param([string]$Text, [string]$Reason = 'Direction Message', [string]$CommandId = '', [bool]$AllowReply = $true)
    Ensure-LogbookDirs
    $msgPath = Join-Path $Global:StateDir 'incoming_message.json'
    @{ text = $Text; reason = $Reason; command_id = $CommandId; allow_reply = $AllowReply; received_at = (Get-Date).ToString('o') } |
        ConvertTo-Json | Out-File -FilePath $msgPath -Encoding UTF8 -Force
}

# Device -> admin message (Logix Control replies). Posts to /api/replies with the
# same credential order as the heartbeat (per-device key first, shared key
# fallback). command_id links a reply back to the broadcast it answers.
function Send-LogbookReply {
    param([Parameter(Mandatory=$true)][string]$Text, [string]$CommandId = '')
    try {
        $serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
        if (-not $serverUrl) { return $false }
        $serverKey = Get-LogbookDeviceApiKey
        if (-not $serverKey) { $serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY' }
        $payload = @{
            hostname    = $env:COMPUTERNAME
            device_name = Get-LogbookDeviceDisplayName
            message     = $Text
            command_id  = $CommandId
        }
        $headers = @{ 'Content-Type' = 'application/json' }
        if ($serverKey) { $headers['X-API-Key'] = $serverKey }
        $apiUrl = $serverUrl.TrimEnd('/') + '/api/replies'
        Invoke-RestMethod -Uri $apiUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 3) -Headers $headers -TimeoutSec 5 -UseBasicParsing | Out-Null
        Write-LogbookInfo "Reply sent to server (command_id: $CommandId)."
        return $true
    } catch {
        Write-LogbookError "Reply send failed: $($_.Exception.Message)"
        return $false
    }
}

# Screen capture lives in its own on-demand script (logbook_screenshot.ps1),
# NOT here: the capture-and-upload pattern trips Windows Defender's AMSI, and
# having it inline would get this whole always-loaded core file blocked as
# "malicious", breaking every agent function. Isolated, only the screenshot
# feature is affected if AV objects, and the SCREENSHOT handler shells out to it.
function Invoke-LogbookScreenshotCapture {
    param([Parameter(Mandatory=$true)][string]$CommandId)
    $script = Join-Path $Global:LabDir 'logbook_screenshot.ps1'
    if (-not (Test-Path $script)) { throw "logbook_screenshot.ps1 not found at $script" }
    Start-Process powershell.exe -WindowStyle Hidden -Wait -ArgumentList @(
        '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$script,'-CommandId',$CommandId) | Out-Null
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

                # Logix Control command dispatch. LOCK/BROADCAST are the
                # originals; SCREENSHOT/SHUTDOWN/RESTART/LOGOFF are the Logix
                # Control additions. All paths ack their outcome; unknown names
                # fail explicitly rather than being silently dropped.
                try {
                    switch ($name) {
                        'LOCK' {
                            Write-LogbookInfo "Remote LOCK trigger execution."
                            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_end.ps1'),'-Reason','LOCK') | Out-Null
                            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_popup.ps1'),'-ForceNew') | Out-Null
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = '' }
                        }
                        'BROADCAST' {
                            # Drop for the timer widget to show inline near the
                            # clock -- not a separate MessageBox. command_id
                            # rides along so a reply typed into the widget can
                            # reference the exact broadcast it answers. "done"
                            # means the file was written, not that the user saw it.
                            Write-LogbookInfo "Remote message received (reason: $($cmd.reason))."
                            $reason = if ($cmd.reason) { [string]$cmd.reason } else { 'Direction Message' }
                            Set-LogbookIncomingMessage -Text $param -Reason $reason -CommandId ([string]$cmd.command_id)
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = '' }
                        }
                        'SCREENSHOT' {
                            # Transparency first, then capture: the person at the
                            # device always sees a notice that a capture happened
                            # (docs/PRIVACY.md, "never silently").
                            Write-LogbookInfo "Remote SCREENSHOT trigger execution."
                            Set-LogbookIncomingMessage -Text 'Admin baru saja mengambil tangkapan layar perangkat ini untuk keperluan pemantauan.' -Reason 'Screen View Notice' -AllowReply $false
                            Invoke-LogbookScreenshotCapture -CommandId ([string]$cmd.command_id)
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = 'screenshot uploaded' }
                        }
                        'SHUTDOWN' {
                            Write-LogbookInfo "Remote SHUTDOWN trigger execution."
                            Set-LogbookIncomingMessage -Text 'Perangkat ini akan dimatikan oleh admin dalam 30 detik. Simpan pekerjaan Anda sekarang.' -Reason 'Emergency Alert' -AllowReply $false
                            & shutdown.exe /s /t 30 /c 'Logix: perangkat dimatikan oleh admin. Simpan pekerjaan Anda.' | Out-Null
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = 'shutdown scheduled (30s)' }
                        }
                        'RESTART' {
                            Write-LogbookInfo "Remote RESTART trigger execution."
                            Set-LogbookIncomingMessage -Text 'Perangkat ini akan dimulai ulang oleh admin dalam 30 detik. Simpan pekerjaan Anda sekarang.' -Reason 'Emergency Alert' -AllowReply $false
                            & shutdown.exe /r /t 30 /c 'Logix: perangkat dimulai ulang oleh admin. Simpan pekerjaan Anda.' | Out-Null
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = 'restart scheduled (30s)' }
                        }
                        'LOGOFF' {
                            # Close the logbook session cleanly first so hours
                            # aren't lost, then sign the user out.
                            Write-LogbookInfo "Remote LOGOFF trigger execution."
                            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_end.ps1'),'-Reason','END') -Wait | Out-Null
                            & shutdown.exe /l /f | Out-Null
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = 'user logged off' }
                        }
                        default {
                            Write-LogbookError "Unknown remote command: $name"
                            $newAcks += @{ command_id = $cmd.command_id; status = 'failed'; detail = "unknown command $name" }
                        }
                    }
                } catch {
                    $newAcks += @{ command_id = $cmd.command_id; status = 'failed'; detail = $_.Exception.Message }
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

function Get-LogbookText($cfg, [string]$Key, [string]$Fallback = '') {
    # Resolve a client UI string by key, honoring $cfg.locale ('id' default,
    # 'en' optional). Falls back to the ID string for any key the chosen
    # locale hasn't translated, then to $Fallback. Optional -f args are
    # applied by the caller (these are format templates, e.g. 'Lanjut sebagai {0}').
    $t = $cfg.text
    $locale = [string]$cfg.locale
    if ($locale -eq 'en' -and $t -and $t.en) {
        $en = $t.en
        if ($en.Contains($Key) -and -not [string]::IsNullOrWhiteSpace([string]$en[$Key])) {
            return [string]$en[$Key]
        }
    }
    if ($t -and $t.Contains($Key) -and -not [string]::IsNullOrWhiteSpace([string]$t[$Key])) {
        return [string]$t[$Key]
    }
    return $Fallback
}

function Get-LogbookTheme($cfg) {
    # Resolve the full client palette from config, with the Client Foundation
    # defaults as fallbacks. Backward-compatible: a config that only sets the
    # legacy four colours (primary/accent/muted/text) still renders -- the
    # surface ramp and signal colours derive from sensible defaults. Every
    # value is a #RRGGBB string ready to drop straight into XAML.
    $c = $cfg.branding.colors
    $s = $cfg.branding.signals
    $val = {
        param($map, $key, $fallback)
        if ($map -and $map.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$map[$key])) {
            return [string]$map[$key]
        }
        return $fallback
    }
    $accent          = & $val $c 'accent'          '#2563EB'
    $text            = & $val $c 'text'            '#EEF3FB'
    $muted           = & $val $c 'muted'           '#93A1B8'
    $surfaceElevated = & $val $c 'surfaceElevated' (& $val $c 'primary' '#0E1626')
    return @{
        accent          = $accent
        text            = $text
        muted           = $muted
        surface         = & $val $c 'surface'       '#070C15'
        surfaceWidget   = & $val $c 'surfaceWidget' '#0B1017'
        surfaceElevated = $surfaceElevated
        border          = & $val $c 'border'        '#223451'
        signalNormal    = & $val $s 'normal'        '#22C55E'
        signalNotice    = & $val $s 'notice'        '#3B82F6'
        signalWarning   = & $val $s 'warning'       '#F59E0B'
        signalCritical  = & $val $s 'critical'      '#EF4444'
    }
}

# NIM/NIP/NIK is numbers-only (student/staff ID, national ID) -- reject
# non-digit keystrokes at the source and strip non-digits from paste, rather
# than validating after the fact. Shared by the real popup (logbook_popup.ps1)
# and the interactive preview (preview_client.ps1) so both behave the same.
function Set-LogbookNumericOnly($TextBox) {
    $TextBox.Add_PreviewTextInput({
        param($sender, $e)
        if ($e.Text -notmatch '^[0-9]+$') { $e.Handled = $true }
    })
    $TextBox.Add_PreviewKeyDown({
        param($sender, $e)
        # Space bar doesn't fire PreviewTextInput as printable text on some
        # layouts -- block it explicitly so it can't sneak a blank in.
        if ($e.Key -eq 'Space') { $e.Handled = $true }
    })
    [System.Windows.DataObject]::AddPastingHandler($TextBox, {
        param($sender, $e)
        if ($e.DataObject.GetDataPresent([System.Windows.DataFormats]::Text)) {
            $text = [string]$e.DataObject.GetData([System.Windows.DataFormats]::Text)
            $digits = ($text -replace '[^0-9]', '')
            if ($digits -ne $text) {
                if ($digits) { $sender.SelectedText = $digits }
                $e.CancelCommand()
            }
        } else {
            $e.CancelCommand()
        }
    })
}

function Build-LogbookPopupXaml($cfg) {
    # Render the popup XAML from config. Pure string building (no WPF), so it is
    # unit-testable by parsing the result as [xml].
    $theme   = Get-LogbookTheme $cfg
    $accent  = $theme.accent
    $muted   = $theme.muted            # muted TEXT
    $text    = $theme.text
    $primary = $theme.surfaceElevated  # card / input surface
    $surface = $theme.surface          # deepest fullscreen surface
    $border  = $theme.border           # hairline BORDER
    $overlay = '#D8' + $surface.TrimStart('#')  # deep translucent scrim over blur

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
        Topmost="True" ShowInTaskbar="False" Background="$surface"
        FontFamily="Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="PrussianBlue" Color="$primary" />
    <SolidColorBrush x:Key="Silver" Color="$muted" />
    <SolidColorBrush x:Key="Pompadour" Color="$accent" />
    <SolidColorBrush x:Key="WhiteBrush" Color="$text" />

    <Style x:Key="LabelTextStyle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="FontSize" Value="13" />
      <Setter Property="Foreground" Value="$text" />
      <Setter Property="Margin" Value="0,0,0,7" />
    </Style>

    <Style x:Key="InputTextBoxStyle" TargetType="TextBox">
      <Setter Property="Height" Value="44" />
      <Setter Property="Padding" Value="12,8" />
      <Setter Property="FontFamily" Value="Segoe UI" />
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
      <Setter Property="FontFamily" Value="Segoe UI" />
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
      <Setter Property="FontFamily" Value="Segoe UI" />
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

    <Border Width="790" CornerRadius="18" BorderBrush="$border" BorderThickness="1" Background="$primary"
            HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True">
      <Border.Effect><DropShadowEffect BlurRadius="32" ShadowDepth="0" Opacity="0.42" Color="$accent" /></Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto" />
          <RowDefinition Height="*" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" CornerRadius="18,18,0,0" Padding="30,26,30,24" BorderBrush="$text" BorderThickness="0,0,0,1">
          <!-- Mascot hero: the faculty mascot (MascotImage, populated from
               branding.logoPath in logbook_popup.ps1) sits centred above the
               wordmark and title. LogoText stays the wordmark fallback and is
               always shown beneath the mascot. -->
          <StackPanel HorizontalAlignment="Center">
            <Image Name="MascotImage" Height="132" MaxWidth="240" Stretch="Uniform" HorizontalAlignment="Center"
                   SnapsToDevicePixels="True" RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed" Margin="0,0,0,12" />
            <TextBlock Name="LogoText" Text="$logoText" FontFamily="Segoe UI Semibold" FontSize="30"
                       FontWeight="SemiBold" Foreground="$text" HorizontalAlignment="Center" />
            <TextBlock Text="$title" FontFamily="Segoe UI" FontSize="20" FontWeight="SemiBold"
                       Foreground="$text" HorizontalAlignment="Center" Margin="0,4,0,0" />
            <TextBlock Text="$subtitle" FontFamily="Segoe UI" FontSize="13" Foreground="$muted"
                       HorizontalAlignment="Center" Margin="0,2,0,0" />
          </StackPanel>
        </Border>

        <StackPanel Grid.Row="1" Margin="36,28,36,34">
          <TextBlock Text="$tIntro" FontFamily="Segoe UI" FontSize="12.5"
                     FontWeight="SemiBold" Foreground="$text" Margin="0,0,0,7" />
          <TextBlock Name="StartTimeText" Text="$tStart" FontFamily="Segoe UI"
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
            <Border Grid.Column="0" Background="$primary" CornerRadius="10" Padding="12,9" BorderBrush="$border" BorderThickness="1">
              <TextBlock Name="HintText" Text="$tHint"
                         FontFamily="Segoe UI" FontSize="11.5" FontWeight="SemiBold" Foreground="$muted" TextWrapping="Wrap" />
            </Border>
            <Button Grid.Column="2" Name="SubmitBtn" Height="48" Content="$tSubmit" FontFamily="Segoe UI"
                    FontSize="21" FontWeight="Bold" Background="$accent" Foreground="$text" BorderBrush="$border"
                    BorderThickness="1" IsEnabled="False" Opacity="0.45" />
          </Grid>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
"@
}

function Build-LogbookWelcomeBackXaml($cfg, $profile, [string]$detectedType) {
    # Returning-user fast path (Action canvas: LogiX Sign-in Popup SA). A
    # returning user confirms one saved identity and starts -- no full form.
    # Same deep-navy fullscreen surface as the main popup. Named controls the
    # controller wires: StartBtn (resume) and ChangeBtn (fall through to form).
    $theme  = Get-LogbookTheme $cfg
    $accent = $theme.accent; $text = $theme.text; $muted = $theme.muted
    $surface = $theme.surface; $elevated = $theme.surfaceElevated; $border = $theme.border
    $overlay = '#D8' + $surface.TrimStart('#')

    $logoText = ConvertTo-LogbookXmlText ([string]$cfg.branding.logoText)
    $title    = ConvertTo-LogbookXmlText ([string]$cfg.branding.title)
    $subtitle = ConvertTo-LogbookXmlText ([string]$cfg.branding.subtitle)
    $nama     = [string]$profile.nama
    $nim      = [string]$profile.nim
    $tujuan   = [string]$profile.tujuan
    $access   = if ([string]::IsNullOrWhiteSpace([string]$detectedType)) { 'Physical' } else { [string]$detectedType }

    # Avatar initials from the name (up to two).
    $initials = (($nama -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() }) -join '')
    if ($initials.Length -gt 2) { $initials = $initials.Substring(0,2) }
    if ([string]::IsNullOrWhiteSpace($initials)) { $initials = '?' }
    $nimMasked = if ($nim.Length -gt 4) { $nim.Substring(0,4) + '...' } else { $nim }
    $meta = ConvertTo-LogbookXmlText ("NIM $nimMasked - $access - $tujuan")

    $tWelcome = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'welcomeBack' 'Lanjutkan sesi Anda')
    $tContinue = ConvertTo-LogbookXmlText (([string](Get-LogbookText $cfg 'continueAs' 'Lanjut sebagai {0}')) -f $nama)
    $tNotYou  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'notYou' 'Bukan saya / ganti data')
    $tSubmit  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'submit' 'Mulai Sesi')
    $tPrivacy = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'privacyOneLiner' 'Siapa, cara & kapan - bukan ketikan.')
    $tRecorded = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'whatsRecorded' 'Apa yang dicatat?')
    $started  = ConvertTo-LogbookXmlText ('Sesi dimulai ' + (Get-Date).ToString('HH:mm'))
    $nameX    = ConvertTo-LogbookXmlText $nama

    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="False" Background="$surface" FontFamily="Segoe UI">
  <Grid>
    <Image Name="BgImage" Stretch="Fill" Opacity="0.88"><Image.Effect><BlurEffect Radius="24" KernelType="Gaussian" /></Image.Effect></Image>
    <Rectangle Fill="$overlay" />
    <Border Width="430" CornerRadius="16" BorderBrush="$border" BorderThickness="1" Background="$elevated"
            HorizontalAlignment="Center" VerticalAlignment="Center" Padding="34,30,34,28">
      <Border.Effect><DropShadowEffect BlurRadius="40" ShadowDepth="0" Opacity="0.5" Color="#070C15" /></Border.Effect>
      <StackPanel>
        <Image Name="MascotImage" Height="96" MaxWidth="200" Stretch="Uniform" HorizontalAlignment="Center"
               RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed" Margin="0,0,0,10" />
        <TextBlock Text="$logoText" FontFamily="Segoe UI Semibold" FontSize="28" FontWeight="SemiBold" Foreground="$text" HorizontalAlignment="Center" />
        <TextBlock Text="$title" FontSize="15" FontWeight="SemiBold" Foreground="$text" HorizontalAlignment="Center" Margin="0,6,0,0" />
        <TextBlock Text="$subtitle" FontSize="12" Foreground="$muted" HorizontalAlignment="Center" Margin="0,1,0,0" />
        <Border Height="1" Background="$border" Margin="0,20,0,18" />
        <TextBlock Text="$tWelcome" FontSize="12" FontWeight="SemiBold" Foreground="$muted" Margin="0,0,0,12" />
        <Border Background="$surface" CornerRadius="12" BorderBrush="$border" BorderThickness="1" Padding="14,12" Margin="0,0,0,18">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Width="44" Height="44" CornerRadius="22" Background="$accent" VerticalAlignment="Center">
              <TextBlock Text="$initials" FontFamily="Segoe UI Semibold" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="$tContinue" FontFamily="Segoe UI Semibold" FontSize="17" FontWeight="Bold" Foreground="$text" TextTrimming="CharacterEllipsis" />
              <TextBlock Text="$meta" FontFamily="Consolas" FontSize="12" Foreground="$muted" Margin="0,3,0,0" TextTrimming="CharacterEllipsis" />
            </StackPanel>
          </Grid>
        </Border>
        <Button Name="StartBtn" Height="50" Content="$tSubmit" FontFamily="Segoe UI Semibold" FontSize="19" FontWeight="Bold"
                Background="$accent" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" />
        <Button Name="ChangeBtn" Content="$tNotYou" Background="Transparent" BorderThickness="0" Foreground="$muted"
                FontSize="13" FontWeight="SemiBold" Cursor="Hand" Margin="0,12,0,0" HorizontalAlignment="Center" />
        <TextBlock Text="$started" FontFamily="Consolas" FontSize="11" Foreground="$muted" HorizontalAlignment="Center" Margin="0,14,0,0" />
        <Border Height="1" Background="$border" Margin="0,16,0,14" />
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
          <TextBlock Text="$tPrivacy" FontSize="11.5" Foreground="$muted" VerticalAlignment="Center" />
          <TextBlock Text="  $tRecorded" FontSize="11.5" FontWeight="SemiBold" Foreground="$accent" VerticalAlignment="Center" />
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
}

function Build-LogbookEmergencyOverlayXaml($cfg) {
    # Emergency countdown (design: LogiX Notifications S3). A shutdown in 30s is
    # too important for the corner widget, so Variant 3 escapes to a centered,
    # dimmed-backdrop, always-on-top overlay. Big live Consolas numeral, red,
    # pulsing ring. The controller drives CountNumber via a DispatcherTimer.
    $theme  = Get-LogbookTheme $cfg
    $red    = $theme.signalCritical; $text = $theme.text; $muted = $theme.muted
    $surface = $theme.surface; $elevated = $theme.surfaceElevated; $border = $theme.border
    $tTitle = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'emergencyTitle' 'Peringatan Sistem')
    $tBody  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'emergencyBody' 'Perangkat ini akan dimatikan oleh admin. Simpan pekerjaan Anda sekarang.')
    $tSaved = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'emergencySaved' 'Saya sudah menyimpan')
    $device = ConvertTo-LogbookXmlText (Get-LogbookDeviceDisplayName)
    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="False" AllowsTransparency="True" Background="#CC070C15" FontFamily="Segoe UI">
  <Grid>
    <Border Width="440" CornerRadius="16" Background="$elevated" BorderBrush="$red" BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Center" Padding="34,30" >
      <Border.Effect><DropShadowEffect BlurRadius="48" ShadowDepth="0" Opacity="0.6" Color="#000000" /></Border.Effect>
      <StackPanel HorizontalAlignment="Center">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,4">
          <Ellipse Width="10" Height="10" Fill="$red" Margin="0,0,9,0" VerticalAlignment="Center"/>
          <TextBlock Text="$tTitle" FontFamily="Segoe UI Semibold" FontSize="16" FontWeight="Bold" Foreground="$red" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock Text="$device" FontFamily="Consolas" FontSize="12" Foreground="$muted" HorizontalAlignment="Center" Margin="0,0,0,10"/>
        <Grid Width="180" Height="180" HorizontalAlignment="Center">
          <Ellipse Name="Ring" Width="180" Height="180" Stroke="$red" StrokeThickness="4" Opacity="0.85"/>
          <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
            <TextBlock Name="CountNumber" Text="30" FontFamily="Consolas" FontSize="76" FontWeight="Bold" Foreground="$text" HorizontalAlignment="Center"/>
            <TextBlock Text="detik" FontFamily="Segoe UI" FontSize="13" Foreground="$muted" HorizontalAlignment="Center" Margin="0,-6,0,0"/>
          </StackPanel>
        </Grid>
        <TextBlock Text="$tBody" FontSize="14" Foreground="$text" TextWrapping="Wrap" TextAlignment="Center" MaxWidth="360" Margin="0,16,0,18"/>
        <Button Name="SavedBtn" Content="$tSaved" Height="44" MinWidth="200" Cursor="Hand"
                Background="$red" Foreground="#FFFFFF" BorderThickness="0" FontFamily="Segoe UI Semibold" FontSize="15" FontWeight="Bold"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
}

function Build-LogbookLockXaml($cfg, [string]$Nama, [string]$Reason) {
    # Lock / paused overlay (design: LogiX Lock & Setup SA). Reads "in use,
    # paused" -- never punitive. The session keeps running; only the screen is
    # held. Controller drives LockClock + LockElapsed; UnlockBtn resumes.
    $theme  = Get-LogbookTheme $cfg
    $accent = $theme.accent; $text = $theme.text; $muted = $theme.muted
    $surface = $theme.surface; $elevated = $theme.surfaceElevated; $border = $theme.border
    $warn   = $theme.signalWarning
    $logoText = ConvertTo-LogbookXmlText ([string]$cfg.branding.logoText)
    $namaX  = ConvertTo-LogbookXmlText $Nama
    $reasonX = ConvertTo-LogbookXmlText $Reason
    $tTitle = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockTitle' 'Workstation dikunci oleh admin lab')
    $tPaused = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockPausedNote' 'Sesi Anda dijeda, bukan diakhiri. Semua pekerjaan & waktu sesi tetap tersimpan.')
    $tBadge = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockPausedBadge' 'DIJEDA')
    $tElapsed = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockElapsedLabel' 'Waktu sesi berjalan')
    $tUser  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockUserLabel' 'Pengguna')
    $tReason = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockReasonLabel' 'Alasan dari admin')
    $tHint  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockUnlockHint' 'Masuk kembali untuk melanjutkan sesi')
    $tUnlock = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockUnlockBtn' 'Buka & Lanjutkan')
    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="False" Background="$surface" FontFamily="Segoe UI">
  <Grid>
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="520">
      <Image Name="MascotImage" Height="96" Stretch="Uniform" HorizontalAlignment="Center" Visibility="Collapsed" Margin="0,0,0,10"/>
      <TextBlock Text="$logoText" FontFamily="Segoe UI Semibold" FontSize="30" FontWeight="SemiBold" Foreground="$text" HorizontalAlignment="Center"/>
      <TextBlock Name="LockClock" Text="--:--" FontFamily="Consolas" FontSize="15" Foreground="$muted" HorizontalAlignment="Center" Margin="0,6,0,22"/>
      <TextBlock Text="$tTitle" FontFamily="Segoe UI Semibold" FontSize="20" FontWeight="Bold" Foreground="$text" HorizontalAlignment="Center" TextAlignment="Center"/>
      <TextBlock Text="$tPaused" FontSize="14" Foreground="$muted" TextWrapping="Wrap" TextAlignment="Center" Margin="0,8,0,20"/>
      <Border Background="$elevated" CornerRadius="12" BorderBrush="$border" BorderThickness="1" Padding="20,16" Margin="0,0,0,20">
        <StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,10">
            <Border Background="#22F59E0B" CornerRadius="999" Padding="9,3" Margin="0,0,10,0">
              <TextBlock Text="$tBadge" FontFamily="Segoe UI Semibold" FontSize="11" FontWeight="Bold" Foreground="$warn"/>
            </Border>
            <TextBlock Text="$tElapsed" FontSize="12" Foreground="$muted" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Name="LockElapsed" Text="00:00:00" FontFamily="Consolas" FontSize="40" FontWeight="Bold" Foreground="$text" HorizontalAlignment="Center" Margin="0,0,0,12"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="$tUser" FontSize="12" Foreground="$muted" Width="120"/>
            <TextBlock Grid.Column="1" Text="$namaX" FontFamily="Segoe UI Semibold" FontSize="13" Foreground="$text"/>
          </Grid>
          <Grid Margin="0,6,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="$tReason" FontSize="12" Foreground="$muted" Width="120"/>
            <TextBlock Grid.Column="1" Text="$reasonX" FontSize="13" Foreground="$text" TextWrapping="Wrap"/>
          </Grid>
        </StackPanel>
      </Border>
      <TextBlock Text="$tHint" FontSize="12" Foreground="$muted" HorizontalAlignment="Center" Margin="0,0,0,10"/>
      <Button Name="UnlockBtn" Content="$tUnlock" Height="46" MinWidth="220" HorizontalAlignment="Center" Cursor="Hand"
              Background="$accent" Foreground="#FFFFFF" BorderThickness="0" FontFamily="Segoe UI Semibold" FontSize="15" FontWeight="Bold"/>
    </StackPanel>
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
    $theme        = Get-LogbookTheme $cfg
    $accent       = $theme.accent
    $muted        = $theme.muted
    $text         = $theme.text
    $primary        = $theme.surfaceElevated
    $widget         = $theme.surfaceWidget
    $border         = $theme.border
    $signalNormal   = $theme.signalNormal
    $signalWarning  = $theme.signalWarning
    $signalCritical = $theme.signalCritical
    $tSelesai       = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'timerEnd' 'SELESAI')

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
    <Path Name="ShapePath" Margin="10" Fill="$widget" Stroke="$border" StrokeThickness="1.3" Data="$seedShapeData">
      <Path.Effect>
        <DropShadowEffect BlurRadius="22" ShadowDepth="0" Opacity="0.55" Color="#070C15" />
      </Path.Effect>
    </Path>

    <Grid Name="ContentGrid" Margin="10" Clip="$seedShapeData">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="18,14,18,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Ellipse Name="Pulse" Width="8" Height="8" Fill="$signalNormal" Margin="0,3,8,0" VerticalAlignment="Center" />
        <TextBlock Name="Label" Grid.Column="1" Text="$sessionType" FontFamily="Segoe UI Semibold" FontSize="11" Foreground="$muted" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" />
      </Grid>

      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="18,4,18,4" VerticalAlignment="Bottom">
        <TextBlock Name="ClockMain" Text="00:00" FontFamily="Consolas" FontSize="40" FontWeight="Bold" Foreground="$text"/>
        <TextBlock Name="ClockSeconds" Text="00" FontFamily="Consolas" FontSize="16" FontWeight="Bold" Foreground="$muted" Margin="4,0,0,6" VerticalAlignment="Bottom"/>
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

        <Border Height="4" Margin="18,0,18,12" CornerRadius="2">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="$primary" Offset="0"/>
              <GradientStop Color="$accent" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>
      </StackPanel>

      <!-- SELESAI lives in its OWN row, a sibling of InfoSection (NOT nested
           inside it): always present regardless of whether Nama/Tujuan/
           Device are shown or collapsed (hover / first-10s only). Two-step to
           prevent misclicks. Filled soft surface + icon (not a hollow outline
           pill) so it reads as a real, deliberate control at a glance;
           stretches to the same 18px inset every other row in this card
           uses, so it aligns with the layout instead of floating centered.
           Warms to amber on hover; the controller (logbook_timer.ps1) arms
           it red on first press and ends the session on a confirming second
           press within 3s. -->
      <Button Grid.Row="3" Name="SelesaiBtn" Content="$tSelesai" Cursor="Hand" Margin="18,0,18,12"
              Padding="0,10" Background="#14FFFFFF" BorderBrush="$border" BorderThickness="1" Foreground="$muted"
              FontFamily="Segoe UI Semibold" FontSize="12" FontWeight="Bold">
        <Button.Template>
          <ControlTemplate TargetType="Button">
            <Border x:Name="SelesaiBg" CornerRadius="9" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Path Data="M18.36 6.64A9 9 0 1 1 5.64 6.64 M12 2 L12 12" Stroke="{TemplateBinding Foreground}"
                      StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                      Width="13" Height="13" Stretch="Uniform" Margin="0,0,7,0"/>
                <TextBlock Text="{TemplateBinding Content}" VerticalAlignment="Center"
                           Foreground="{TemplateBinding Foreground}" FontFamily="Segoe UI Semibold" FontSize="{TemplateBinding FontSize}" FontWeight="Bold"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="SelesaiBg" Property="Background" Value="#33F59E0B"/>
                <Setter TargetName="SelesaiBg" Property="BorderBrush" Value="$signalWarning"/>
                <Setter Property="Foreground" Value="$signalWarning"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="SelesaiBg" Property="Opacity" Value="0.75"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Button.Template>
      </Button>

      <Border Grid.Row="4" Name="MessageSection" Visibility="Collapsed" Margin="14,0,14,14" Padding="10,10" CornerRadius="10"
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
            if (Test-Path $Global:SessionFile) {
                # Removing session.json is what actually ends the session; if it
                # survives, the session is NOT closed no matter that the event
                # was logged above. Almost always an ACL/ownership problem (the
                # file was created by an elevated run and this process is not).
                # Do NOT report success -- surface the real error and fail so the
                # caller (and the log) can see why SELESAI "did nothing".
                try {
                    Remove-Item $Global:SessionFile -Force -ErrorAction Stop
                } catch {
                    Write-LogbookError "Could NOT remove session file '$($Global:SessionFile)' closing sid=$($session.session_id) reason=$Reason -- session will not end and its timer keeps running. Likely ACL/ownership (file owned by another/elevated account). Run windows\repair_logbook_permissions.ps1 as admin. Error: $($_.Exception.Message)"
                    Stop-LogbookTimers
                    return $false
                }
            }
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

# Upper bound (seconds) on how long a single session may span before resuming it
# stops making sense as a logbook duration. Configurable via
# LOGIX_MAX_SESSION_HOURS; 0/unset falls back to the 8-hour default (roughly a
# working day). See Close-OverAgeLogbookSessionIfAny.
function Get-LogbookMaxSessionSeconds {
    $hours = Get-LogbookConfigEnv 'LOGIX_MAX_SESSION_HOURS'
    $parsed = 0.0
    if ($hours -and [double]::TryParse($hours, [ref]$parsed) -and $parsed -gt 0) {
        return [int]($parsed * 3600)
    }
    return 8 * 3600
}

# Companion to Close-StaleLogbookSessionIfAny, but keyed off wall-clock age
# rather than reboot. A machine locked or slept overnight WITHOUT a reboot keeps
# start_time newer than LastBootUpTime, so the stale-check above never fires and
# the session resumes with a timer reading e.g. 25:00:00 -- "continuing from
# yesterday". Call this on the resume/unlock path (see logbook_popup.ps1's
# early-exit and logbook_monitor.ps1): a session older than
# Get-LogbookMaxSessionSeconds is closed so a fresh sign-in form is shown
# instead. Deliberately NOT called on every timer tick of an actively-used
# unlocked session -- a legitimate long compute run stays open while the user is
# present; this only caps the "came back to a locked machine" case.
function Close-OverAgeLogbookSessionIfAny {
    if (-not (Test-Path $Global:SessionFile)) { return $false }
    $ageSec = Get-ActiveLogbookSessionAgeSeconds
    if ($null -eq $ageSec) { return $false }
    $maxSec = Get-LogbookMaxSessionSeconds
    if ($maxSec -le 0) { return $false }
    if ($ageSec -ge $maxSec) {
        Write-LogbookInfo "Session age ${ageSec}s exceeds cap ${maxSec}s; auto-closing instead of resuming."
        Close-ActiveLogbookSession -Reason 'AUTO_CLOSE' | Out-Null
        return $true
    }
    return $false
}

# Product decision: a lock or sleep/resume cycle, by itself, is NOT a
# session boundary -- someone stepping away for coffee (or a laptop lid
# closing) shouldn't split one lab visit into two logbook rows, no matter
# how long the lock/sleep lasted. Only a real departure signal ends a
# session: explicit sign-out (this function, wired to the timer widget's
# SELESAI button), OS shutdown/logoff (SessionEnding /
# ConsoleDisconnect/RemoteDisconnect/SessionLogoff in logbook_monitor.ps1),
# reboot (Close-StaleLogbookSessionIfAny above), or genuinely being idle
# with the screen unlocked for LOGIX_IDLE_TIMEOUT_HOURS (below). Locking
# the workstation here is deliberate: it both signals departure to anyone
# walking up to the machine and guarantees the *next* sign-in goes through
# the unlock path, which starts a fresh session when none is on disk.
function Close-LogbookSessionAndLock {
    Close-ActiveLogbookSession -Reason 'END' | Out-Null
    # Guarantee the next sign-in form appears rather than relying solely on the
    # monitor's SessionUnlock event, which was observed NOT to re-prompt after an
    # END (leaving the user with no way to start a new session on return). The
    # popup is a full-screen topmost overlay, so it sits ready behind the Windows
    # lock screen and is there the moment the user signs back in.
    Start-LogbookPopup | Out-Null
    try {
        Start-Process 'rundll32.exe' -ArgumentList 'user32.dll,LockWorkStation' | Out-Null
    } catch {
        Write-LogbookError "Lock workstation failed: $($_.Exception.Message)"
    }
}

# How often the monitor heartbeats the server AND polls for queued remote
# commands (lock / message / power). Lower = snappier remote actions -- a lock
# from the dashboard lands within this many seconds instead of up to 30 -- at
# the cost of more requests. Configurable via LOGIX_HEARTBEAT_SECONDS; default
# 5s, floored at 2s.
function Get-LogbookHeartbeatSeconds {
    $val = Get-LogbookConfigEnv 'LOGIX_HEARTBEAT_SECONDS'
    $parsed = 0
    if ($val -and [int]::TryParse($val, [ref]$parsed) -and $parsed -ge 2) {
        return $parsed
    }
    return 5
}

function Get-LogbookIdleTimeoutSeconds {
    $hours = Get-LogbookConfigEnv 'LOGIX_IDLE_TIMEOUT_HOURS'
    $parsed = 0.0
    if ($hours -and [double]::TryParse($hours, [ref]$parsed) -and $parsed -gt 0) {
        return [int]($parsed * 3600)
    }
    return 4 * 3600
}

if (-not ([System.Management.Automation.PSTypeName]'LogixIdle').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LogixIdle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
}
"@
}

# Seconds since the last keyboard/mouse input anywhere on the machine (not
# per-window) -- used only to catch "left unlocked and walked away"; a
# locked screen is gated out separately (see logbook_monitor.ps1's
# workstation_locked.flag) because locking already means "same session,
# any duration" per the product decision above.
function Get-LogbookIdleSeconds {
    try {
        $lii = New-Object LogixIdle+LASTINPUTINFO
        $lii.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($lii)
        if (-not [LogixIdle]::GetLastInputInfo([ref]$lii)) { return $null }
        $idleMs = [Environment]::TickCount - $lii.dwTime
        if ($idleMs -lt 0) { return 0 }
        return [double]$idleMs / 1000.0
    } catch {
        Write-LogbookError "Get idle seconds failed: $($_.Exception.Message)"
        return $null
    }
}
