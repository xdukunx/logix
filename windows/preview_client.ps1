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
    # Same fixed heights the real widget uses (logbook_timer.ps1's
    # HEIGHT_COLLAPSED/HEIGHT_EXPANDED) -- measured headlessly via
    # ContentGrid.Measure(), not guessed, so the chamfered shape always
    # matches the window exactly (no transparent gaps, no clipped content).
    $script:pvHCollapsed = 152
    $script:pvHExpanded = 235
    $script:pvTimerW = 230
    $session = @{ session_type = 'SSH'; nama = 'A. Rahmawati'; tujuan = 'Simulasi DFT' }
    Show-PreviewWindow (Build-LogbookTimerXaml $script:pvCfg $session 'WS-07 - GPU-A100') 'Logix - Timer Widget (hover to expand, click SELESAI) (PREVIEW)' $script:pvTimerW $script:pvHCollapsed {
        param($window)
        # Live-ticking clock (starts at 02:14:41, counts up every second) so
        # this reads as a running session, not a frozen screenshot -- and the
        # real SELESAI two-step (arm on first click, confirm within 3s on the
        # second), so you can actually click-test it here. Everything an event
        # handler touches must be $script: scoped (see Enable-PopupInteractive
        # above) -- a DispatcherTimer's Tick handler fires long after this
        # block returns, and closures over merely-local variables go stale by
        # then, corrupting later ShowDialog() calls for OTHER surfaces.
        $script:pvClockMain = $window.FindName('ClockMain'); $script:pvClockSeconds = $window.FindName('ClockSeconds')
        $script:pvElapsed = [TimeSpan]::FromHours(2).Add([TimeSpan]::FromMinutes(14)).Add([TimeSpan]::FromSeconds(41))
        $script:pvClockTimer = New-Object Windows.Threading.DispatcherTimer
        $script:pvClockTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:pvClockTimer.Add_Tick({
            $script:pvElapsed = $script:pvElapsed.Add([TimeSpan]::FromSeconds(1))
            $script:pvClockMain.Text = ('{0:00}:{1:00}' -f [math]::Floor($script:pvElapsed.TotalHours), $script:pvElapsed.Minutes)
            $script:pvClockSeconds.Text = ('{0:00}' -f $script:pvElapsed.Seconds)
        })
        $script:pvClockTimer.Start()

        # Info (Nama/Tujuan/Device) only shows on hover -- matches the real
        # widget's Update-LogbookInfoVisibility. Resync the shape + clip to
        # the new size every time, exactly like Sync-LogbookTimerShape does,
        # or the outline drifts out of alignment with the actual content.
        $script:pvInfoSection = $window.FindName('InfoSection')
        $script:pvShapePath = $window.FindName('ShapePath')
        $script:pvContentGrid = $window.FindName('ContentGrid')
        $script:pvInfoSection.Visibility = 'Collapsed'
        $script:pvSyncShape = {
            $geom = [System.Windows.Media.Geometry]::Parse((Get-LogbookTimerShapeData ($script:pvWin.Height - 20) ($script:pvTimerW - 20)))
            $script:pvShapePath.Data = $geom
            $script:pvContentGrid.Clip = $geom
        }
        $window.Add_MouseEnter({
            $script:pvInfoSection.Visibility = 'Visible'
            $script:pvWin.Height = $script:pvHExpanded
            & $script:pvSyncShape
        })
        $window.Add_MouseLeave({
            $script:pvInfoSection.Visibility = 'Collapsed'
            $script:pvWin.Height = $script:pvHCollapsed
            & $script:pvSyncShape
        })

        $script:pvSelesaiBtn = $window.FindName('SelesaiBtn')
        $script:pvTheme = Get-LogbookTheme $script:pvCfg
        $script:pvBc = New-Object System.Windows.Media.BrushConverter
        $script:pvArmed = $false
        $script:pvArmTimer = New-Object Windows.Threading.DispatcherTimer
        $script:pvArmTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:pvArmTimer.Add_Tick({
            $script:pvArmed = $false; $script:pvArmTimer.Stop()
            $script:pvSelesaiBtn.Content = (Get-LogbookText $script:pvCfg 'timerEnd' 'SELESAI')
            $script:pvSelesaiBtn.Background = $script:pvBc.ConvertFromString('#14FFFFFF')
            $script:pvSelesaiBtn.BorderBrush = $script:pvBc.ConvertFromString($script:pvTheme.border)
            $script:pvSelesaiBtn.Foreground = $script:pvBc.ConvertFromString($script:pvTheme.muted)
        })
        $script:pvSelesaiBtn.Add_Click({
            if (-not $script:pvArmed) {
                $script:pvArmed = $true
                $script:pvSelesaiBtn.Content = (Get-LogbookText $script:pvCfg 'timerEndArmed' 'Tekan lagi untuk selesai')
                $red = $script:pvBc.ConvertFromString($script:pvTheme.signalCritical)
                $script:pvSelesaiBtn.Background = $red; $script:pvSelesaiBtn.BorderBrush = $red
                $script:pvSelesaiBtn.Foreground = [System.Windows.Media.Brushes]::White
                $script:pvArmTimer.Stop(); $script:pvArmTimer.Start()
            } else {
                [System.Windows.MessageBox]::Show('SELESAI dikonfirmasi (PRATINJAU). Agent asli akan mengunci workstation di titik ini.', 'Logix - Preview') | Out-Null
                $script:pvWin.Close()
            }
        })
        # Safety net: however this window closes (SELESAI, or the title-bar X),
        # stop both timers so they can never keep ticking into the next surface.
        $window.Add_Closed({
            try { $script:pvClockTimer.Stop() } catch {}
            try { $script:pvArmTimer.Stop() } catch {}
        })
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
        # Safety net: stop the countdown however this window closes, so it
        # can't keep ticking (and referencing this closed window's controls)
        # into the next surface if closed via the title-bar X instead of the button.
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
