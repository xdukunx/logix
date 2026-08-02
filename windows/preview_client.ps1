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
    Set-LogbookNumericOnly $script:pvNim

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
    # WPF requires WindowStyle=None whenever AllowsTransparency=True (the timer
    # widget and the emergency overlay are both transparent-background windows
    # for their custom shapes) -- forcing SingleBorderWindow on those crashes at
    # ShowDialog. Give solid-background surfaces a normal title bar; leave the
    # transparent ones borderless (matches how they really render anyway).
    if ($window.AllowsTransparency) {
        $window.WindowStyle = 'None'; $window.ResizeMode = 'NoResize'
    } else {
        $window.WindowStyle = 'SingleBorderWindow'; $window.ResizeMode = 'CanResize'
    }
    $window.WindowState = 'Normal'; $window.Topmost = $false; $window.ShowInTaskbar = $true
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
    # The v3 widget sizes itself (SizeToContent), so it gets its own show path
    # rather than Show-PreviewWindow's fixed-size one. Hover to expand, click
    # SELESAI twice to confirm, double-click to flip pill <-> strip, and press
    # M to simulate an incoming admin message.
    $session = @{ session_type = 'SSH'; nama = 'A. Rahmawati'; tujuan = 'Simulasi DFT' }
    $window = [Windows.Markup.XamlReader]::Load(
        (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookTimerXaml $script:pvCfg $session 'WS-07 - GPU-A100'))))
    $script:pvWin = $window
    $window.Topmost = $true
    $window.WindowStartupLocation = 'Manual'
    $work = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $work.Left + (($work.Width - 240) / 2.0)
    $window.Top = $work.Top + 10 - 16
    $window.Title = 'Logix - Timer Pill & Strip (PREVIEW)'

    $script:pvPill = $window.FindName('PillView')
    $script:pvCard = $window.FindName('CardView')
    $script:pvSliver = $window.FindName('SliverView')
    $script:pvCardInfo = $window.FindName('CardInfo')
    $script:pvCardMsg = $window.FindName('CardMessage')
    $script:pvQuick = $window.FindName('CardQuickReply')
    $script:pvSent = $window.FindName('CardSent')
    $script:pvSelesai = $window.FindName('SelesaiBtn')
    $script:pvArmedCap = $window.FindName('ArmedCaption')
    $script:pvPillClock = $window.FindName('PillClock')
    $script:pvCardClock = $window.FindName('CardClock')
    $script:pvSliverText = $window.FindName('SliverText')
    $script:pvTheme = Get-LogbookTheme $script:pvCfg
    $script:pvBc = New-Object System.Windows.Media.BrushConverter
    $script:pvPosture = 'pill'
    $script:pvOpen = $false
    $script:pvArmed = $false
    $script:pvHasMsg = $false

    $script:pvSync = {
        $showCard = $script:pvOpen
        $script:pvCard.Visibility = $(if ($showCard) { 'Visible' } else { 'Collapsed' })
        $script:pvPill.Visibility = $(if (-not $showCard -and $script:pvPosture -eq 'pill') { 'Visible' } else { 'Collapsed' })
        $script:pvSliver.Visibility = $(if (-not $showCard -and $script:pvPosture -eq 'strip') { 'Visible' } else { 'Collapsed' })
        $script:pvCardInfo.Visibility = $(if ($script:pvArmed -or $script:pvHasMsg) { 'Collapsed' } else { 'Visible' })
        $script:pvCardMsg.Visibility = $(if ($script:pvHasMsg) { 'Visible' } else { 'Collapsed' })
        $script:pvQuick.Visibility = $(if ($script:pvHasMsg) { 'Visible' } else { 'Collapsed' })
        $script:pvSelesai.Visibility = $(if ($script:pvHasMsg) { 'Collapsed' } else { 'Visible' })
        $script:pvArmedCap.Visibility = $(if ($script:pvArmed) { 'Visible' } else { 'Collapsed' })
        $script:pvCard.Width = $(if ($script:pvHasMsg) { 260 } else { 240 })
    }

    $script:pvElapsed = [TimeSpan]::FromHours(2).Add([TimeSpan]::FromMinutes(14)).Add([TimeSpan]::FromSeconds(41))
    $script:pvClockTimer = New-Object Windows.Threading.DispatcherTimer
    $script:pvClockTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:pvClockTimer.Add_Tick({
        $script:pvElapsed = $script:pvElapsed.Add([TimeSpan]::FromSeconds(1))
        $h = [int][Math]::Floor($script:pvElapsed.TotalHours)
        $script:pvPillClock.Text = ('{0:00}:{1:00}' -f $h, $script:pvElapsed.Minutes)
        $script:pvCardClock.Text = ('{0:00}:{1:00}:{2:00}' -f $h, $script:pvElapsed.Minutes, $script:pvElapsed.Seconds)
        $script:pvSliverText.Text = $script:pvPillClock.Text + ' ' + [char]0x00B7 + ' WS-07'
        if ($script:pvArmed) {
            $script:pvArmTicks -= 1
            if ($script:pvArmTicks -le 0) { & $script:pvDisarm }
        }
    })
    $script:pvArmTicks = 0
    $script:pvDisarm = {
        $script:pvArmed = $false
        $script:pvSelesai.Content = (Get-LogbookText $script:pvCfg 'timerEnd' 'SELESAI')
        $script:pvSelesai.Background = $script:pvBc.ConvertFromString('#00FFFFFF')
        $script:pvSelesai.BorderBrush = $script:pvBc.ConvertFromString($script:pvTheme.border)
        $script:pvSelesai.Foreground = $script:pvBc.ConvertFromString($script:pvTheme.text)
        & $script:pvSync
    }
    $script:pvSelesai.Add_Click({
        if (-not $script:pvArmed) {
            $script:pvArmed = $true
            $script:pvArmTicks = 3
            $script:pvSelesai.Content = (Get-LogbookText $script:pvCfg 'timerEndArmed' 'Tekan lagi untuk selesai')
            $red = $script:pvBc.ConvertFromString($script:pvTheme.signalCritical)
            $script:pvSelesai.Background = $red; $script:pvSelesai.BorderBrush = $red
            $script:pvSelesai.Foreground = [System.Windows.Media.Brushes]::White
            & $script:pvSync
        } else {
            [System.Windows.MessageBox]::Show(
                'SELESAI dikonfirmasi (PRATINJAU). Agent asli memanggil Close-LogbookSessionAndLock di titik ini.',
                'Logix - Preview') | Out-Null
            $script:pvWin.Close()
        }
    })
    $window.Add_MouseEnter({ $script:pvOpen = $true; & $script:pvSync })
    $window.Add_MouseLeave({ $script:pvOpen = $false; if ($script:pvArmed) { & $script:pvDisarm }; & $script:pvSync })
    $window.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.ClickCount -eq 2) {
            $script:pvPosture = $(if ($script:pvPosture -eq 'pill') { 'strip' } else { 'pill' })
            $script:pvOpen = $false
            & $script:pvSync
        }
    })
    $window.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'M') {
            $script:pvHasMsg = -not $script:pvHasMsg
            $script:pvWin.FindName('MessageMeta').Text = 'ADMIN ' + [char]0x00B7 + ' ' + (Get-Date).ToString('HH:mm')
            $script:pvWin.FindName('MessageText').Text = 'Lab tutup 17:00. Simpan pekerjaan sebelum pulang ya.'
            $blue = $script:pvBc.ConvertFromString($script:pvTheme.accent)
            $green = $script:pvBc.ConvertFromString($script:pvTheme.signalNormal)
            $c = $(if ($script:pvHasMsg) { $blue } else { $green })
            $script:pvWin.FindName('PillDot').Fill = $c
            $script:pvWin.FindName('CardDot').Fill = $c
            & $script:pvSync
        }
    })
    foreach ($q in @('QuickOkBtn','QuickWaitBtn','QuickFreeBtn')) {
        $window.FindName($q).Add_Click({
            $script:pvHasMsg = $false
            $script:pvSent.Visibility = 'Visible'
            $script:pvWin.FindName('SentText').Text = 'Terkirim ke admin ' + [char]0x00B7 + ' ' + (Get-Date).ToString('HH:mm')
            & $script:pvSync
            $script:pvSent.Visibility = 'Visible'
        })
    }
    $window.Add_Closed({ try { $script:pvClockTimer.Stop() } catch {} })

    & $script:pvSync
    $script:pvClockTimer.Start()
    Write-Host 'Opening: Timer Pill & Strip -- hover to expand, double-click to flip posture, M to simulate a message.' -ForegroundColor Cyan
    [void]$window.ShowDialog()
}

if ($Surface -in 'notif', 'all') {
    Show-PreviewWindow (Build-LogbookCountdownOverlayXaml $script:pvCfg) 'Logix - Countdown / Broadcast Overlay (PREVIEW)' 760 560 {
        param($window)
        $script:pvCount = $window.FindName('CountNumber')
        $script:pvSecs = 300
        $window.FindName('OverlayBody').Text = 'Idle 2 jam terdeteksi. Gerakkan mouse atau perpanjang untuk melanjutkan.'
        $window.FindName('AckBtn').Visibility = 'Collapsed'
        $script:pvTimer = New-Object Windows.Threading.DispatcherTimer
        $script:pvTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:pvTimer.Add_Tick({
            $script:pvSecs -= 1
            if ($script:pvSecs -lt 0) { $script:pvSecs = 0; $script:pvTimer.Stop() }
            $script:pvCount.Text = ('{0:00}:{1:00}' -f [int]($script:pvSecs / 60), ($script:pvSecs % 60))
        })
        $window.FindName('ExtendBtn').Add_Click({ $script:pvTimer.Stop(); $script:pvWin.Close() })
        $window.FindName('EndNowBtn').Add_Click({ $script:pvTimer.Stop(); $script:pvWin.Close() })
        $window.Add_Closed({ try { $script:pvTimer.Stop() } catch {} })
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
