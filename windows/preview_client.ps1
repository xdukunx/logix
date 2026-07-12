# Non-destructive preview of every client surface straight from this repo
# (not the installed copy). Renders the SAME XAML the real agent uses, so what
# you see is what a workstation shows -- minus the fullscreen/topmost/kiosk
# chrome, the Task Manager gating, and the real session/timer side effects.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\preview_client.ps1 -Surface all
#
# -Surface: popup | welcome | timer | notif | lock | all (default all). Each
# opens a normal, resizable, closable window; close it (title-bar X) to
# advance to the next.
#
# The POPUP preview is fully INTERACTIVE: fill the form, watch "Mulai Sesi"
# enable, click it. It writes a sample session to a TEMP file and shows a
# confirmation -- it does NOT write the real session, gate Task Manager, take
# over the screen, or start the real timer.
#
# NOTE on scope: everything an event handler touches lives in $script: scope.
# WPF handlers fire long after the wiring code returns, and PowerShell closures
# over function-local variables go stale by then (the real agent avoids this by
# wiring at top-level script scope). $script: keeps the refs alive.
param(
    [ValidateSet('popup', 'welcome', 'timer', 'notif', 'lock', 'all')]
    [string]$Surface = 'all',
    [switch]$STAChild
)
$ErrorActionPreference = 'Stop'

# WPF needs STA. Relaunch into an STA host if we're not already in one.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -Surface $Surface -STAChild
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
. (Join-Path $PSScriptRoot 'logbook_common.ps1')

$script:pvCfg = Get-LogbookConfig
$repoLogo = Join-Path $PSScriptRoot 'logo.png'
if (Test-Path $repoLogo) { $script:pvCfg.branding.logoPath = $repoLogo }

function Get-PvComboText($combo) {
    try { $t = [string]$combo.Text; if (-not [string]::IsNullOrWhiteSpace($t)) { return $t } } catch {}
    try { if ($combo.SelectedItem -and $combo.SelectedItem.Content) { return [string]$combo.SelectedItem.Content } } catch {}
    return ''
}

function Set-PvMascot($window) {
    $logoPath = [string]$script:pvCfg.branding.logoPath
    if (Test-Path $logoPath) {
        try {
            $m = New-Object System.Windows.Media.Imaging.BitmapImage
            $m.BeginInit(); $m.UriSource = New-Object System.Uri($logoPath); $m.CacheOption = 'OnLoad'; $m.EndInit(); $m.Freeze()
            $mi = $window.FindName('MascotImage')
            if ($mi) { $mi.Source = $m; $mi.Visibility = 'Visible' }
        } catch { Write-Host "Mascot load failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

# Wire the popup form like the real agent -- required-field validation enables
# the button; clicking "starts a session" into a TEMP file (never the real one).
function Enable-PopupInteractive($window) {
    $script:pvNama = $window.FindName('NamaBox'); $script:pvNim = $window.FindName('NimBox')
    $script:pvAccess = $window.FindName('AccessBox'); $script:pvTujuan = $window.FindName('TujuanBox')
    $script:pvKet = $window.FindName('KetBox'); $script:pvBtn = $window.FindName('SubmitBtn')
    $script:pvHint = $window.FindName('HintText'); $script:pvReq = @($script:pvCfg.requiredFields)
    $window.FindName('StartTimeText').Text = [string]$script:pvCfg.text.startHint

    $bc = New-Object System.Windows.Media.BrushConverter
    $fg = $bc.ConvertFromString((Get-LogbookTheme $script:pvCfg).accent)
    $bg = $bc.ConvertFromString('#FFFFFF')
    foreach ($combo in @($script:pvAccess, $script:pvTujuan)) {
        $combo.Background = $bg; $combo.Foreground = $fg
        foreach ($it in $combo.Items) { try { $it.Background = $bg; $it.Foreground = $fg } catch {} }
    }
    $script:pvAccess.SelectedIndex = 0; $script:pvTujuan.SelectedIndex = 0

    $validate = {
        $vals = @{ nama = $script:pvNama.Text; nim = $script:pvNim.Text; access = (Get-PvComboText $script:pvAccess); purpose = (Get-PvComboText $script:pvTujuan); keterangan = $script:pvKet.Text }
        $ok = $true
        foreach ($f in $script:pvReq) { if ([string]::IsNullOrWhiteSpace([string]$vals[$f])) { $ok = $false; break } }
        $script:pvBtn.IsEnabled = $ok
        if ($ok) { $script:pvBtn.Opacity = 1.0; $script:pvHint.Text = [string]$script:pvCfg.text.hintReady }
        else { $script:pvBtn.Opacity = 0.45; $script:pvHint.Text = [string]$script:pvCfg.text.hintIncomplete }
    }
    @($script:pvNama, $script:pvNim, $script:pvKet) | ForEach-Object { $_.Add_TextChanged($validate) }
    $script:pvTujuan.Add_SelectionChanged($validate); $script:pvTujuan.Add_KeyUp($validate)
    $script:pvAccess.Add_SelectionChanged($validate)
    & $validate

    $script:pvBtn.Add_Click({
        $obj = [ordered]@{
            session_id   = "preview-$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
            start_time   = (Get-Date).ToString('o')
            session_type = (Get-PvComboText $script:pvAccess).Trim()
            username     = $env:USERNAME; hostname = $env:COMPUTERNAME
            nama         = $script:pvNama.Text.Trim(); nim = $script:pvNim.Text.Trim()
            tujuan       = (Get-PvComboText $script:pvTujuan).Trim(); keterangan = $script:pvKet.Text.Trim()
        }
        $tmp = Join-Path $env:TEMP ("logix_preview_session_" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".json")
        $obj | ConvertTo-Json -Depth 4 | Out-File $tmp -Encoding UTF8
        [System.Windows.MessageBox]::Show(
            "Sesi dimulai (PRATINJAU).`n`n$($obj.nama) - $($obj.session_type)`nTujuan: $($obj.tujuan)`n`nDisimpan ke: $tmp`n`nCatatan: ini hanya pratinjau UI. Agent asli yang menulis sesi sungguhan lalu memulai timer.",
            "Logix - Sesi dimulai (pratinjau)") | Out-Null
        $script:pvWin.Close()
    })
    $script:pvNama.Focus() | Out-Null
}

function Show-PreviewWindow([string]$xaml, [string]$title, [double]$w, [double]$h, [scriptblock]$after) {
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    $script:pvWin = $window
    if ($after) { & $after $window }
    $window.WindowStyle = 'SingleBorderWindow'; $window.WindowState = 'Normal'
    $window.ResizeMode = 'CanResize'; $window.Topmost = $false; $window.ShowInTaskbar = $true
    $window.SizeToContent = 'Manual'; $window.Width = $w; $window.Height = $h
    $window.WindowStartupLocation = 'CenterScreen'; $window.Title = $title
    Write-Host "Opening: $title (close the window to continue)" -ForegroundColor Cyan
    [void]$window.ShowDialog()
}

$sampleProfile = @{ nama = 'Dhana Pratama'; nim = '081234567'; tujuan = 'Running Data'; keterangan = 'batch DFT ~3 jam' }

if ($Surface -in 'popup', 'all') {
    Show-PreviewWindow (Build-LogbookPopupXaml $script:pvCfg) 'Logix - Sign-in Popup (INTERACTIVE PREVIEW)' 980 940 {
        param($window)
        Set-PvMascot $window
        Enable-PopupInteractive $window
    }
}

if ($Surface -in 'welcome', 'all') {
    Show-PreviewWindow (Build-LogbookWelcomeBackXaml $script:pvCfg $sampleProfile 'SSH') 'Logix - Returning User Fast Path (PREVIEW)' 720 720 {
        param($window)
        Set-PvMascot $window
        $window.FindName('StartBtn').Add_Click({ [System.Windows.MessageBox]::Show('Mulai Sesi (pratinjau) - resume dari profil tersimpan.', 'Preview') | Out-Null; $script:pvWin.Close() })
        $window.FindName('ChangeBtn').Add_Click({ $script:pvWin.Close() })
    }
}

if ($Surface -in 'timer', 'all') {
    $session = @{ session_type = 'SSH'; nama = 'A. Rahmawati'; tujuan = 'Simulasi DFT' }
    Show-PreviewWindow (Build-LogbookTimerXaml $script:pvCfg $session 'WS-07 - GPU-A100') 'Logix - Timer Widget + SELESAI (PREVIEW)' 320 360 {
        param($window)
        $window.FindName('ClockMain').Text = '02:14'
        $window.FindName('ClockSeconds').Text = '41'
    }
}

if ($Surface -in 'notif', 'all') {
    Show-PreviewWindow (Build-LogbookEmergencyOverlayXaml $script:pvCfg) 'Logix - Emergency Countdown Overlay (PREVIEW)' 700 640 {
        param($window)
        $script:pvCount = $window.FindName('CountNumber'); $script:pvSecs = 30; $script:pvCount.Text = '30'
        $script:pvTimer = New-Object Windows.Threading.DispatcherTimer
        $script:pvTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:pvTimer.Add_Tick({ $script:pvSecs -= 1; if ($script:pvSecs -le 0) { $script:pvCount.Text = '0'; $script:pvTimer.Stop() } else { $script:pvCount.Text = [string]$script:pvSecs } })
        $window.FindName('SavedBtn').Add_Click({ $script:pvTimer.Stop(); $script:pvWin.Close() })
        $script:pvTimer.Start()
    }
}

if ($Surface -in 'lock', 'all') {
    Show-PreviewWindow (Build-LogbookLockXaml $script:pvCfg 'Dhana Pratama' 'Pemeliharaan singkat GPU driver. Mohon tunggu +-10 menit.') 'Logix - Lock / Paused Overlay (PREVIEW)' 760 720 {
        param($window)
        $window.FindName('LockClock').Text = (Get-Date).ToString('HH:mm') + ' - ' + (Get-Date).ToString('dddd, dd MMM yyyy')
        $window.FindName('LockElapsed').Text = '02:21:07'
        $window.FindName('UnlockBtn').Add_Click({ $script:pvWin.Close() })
    }
}

Write-Host 'Preview done.' -ForegroundColor Green
