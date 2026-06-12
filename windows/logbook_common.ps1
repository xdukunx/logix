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
    $wslPayloadPath = '/mnt/c/ProgramData/MindLabLogbook/' + (Split-Path $payloadPath -Leaf)
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
        Write-LogbookInfo "WSL payload event=$Event sid=$SessionId nama=$Nama nim=$Nim tujuan=$Tujuan"
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
    } catch {
        Write-LogbookError "WSL log error for event ${Event}: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $payloadPath -Force -ErrorAction SilentlyContinue
    }
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
