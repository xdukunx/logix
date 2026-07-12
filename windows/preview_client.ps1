# Non-destructive preview of every client surface straight from this repo
# (not the installed copy). Renders the SAME XAML the real agent uses, so what
# you see is what a workstation shows -- minus the fullscreen/topmost/kiosk
# chrome, the Task Manager gating, and the real session/timer side effects.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\preview_client.ps1 -Surface all
#
# -Surface: popup | timer | all (default all). Each opens a normal, resizable,
# closable window; close it with the title-bar X to advance to the next.
#
# The POPUP preview is fully INTERACTIVE: fill the form, watch "Mulai Sesi"
# enable, click it. It writes a sample session to a TEMP file and shows a
# confirmation -- it does NOT write the real session, gate Task Manager, take
# over the screen, or start the real timer. This is the safe way to click
# through the new sign-in UI end to end.
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

$cfg = Get-LogbookConfig
$repoLogo = Join-Path $PSScriptRoot 'logo.png'
if (Test-Path $repoLogo) { $cfg.branding.logoPath = $repoLogo }

function Get-ComboText($combo) {
    try { $t = [string]$combo.Text; if (-not [string]::IsNullOrWhiteSpace($t)) { return $t } } catch {}
    try { if ($combo.SelectedItem -and $combo.SelectedItem.Content) { return [string]$combo.SelectedItem.Content } } catch {}
    return ''
}

# Wire the popup form so it behaves like the real agent's sign-in -- required-
# field validation enables the button, and clicking it "starts a session" into
# a TEMP file (never the real one). Mirrors logbook_popup.ps1's validate/submit.
function Enable-PopupInteractive($window, $cfg) {
    $nama = $window.FindName('NamaBox'); $nim = $window.FindName('NimBox')
    $access = $window.FindName('AccessBox'); $tujuan = $window.FindName('TujuanBox')
    $ket = $window.FindName('KetBox'); $btn = $window.FindName('SubmitBtn')
    $hint = $window.FindName('HintText')
    $window.FindName('StartTimeText').Text = [string]$cfg.text.startHint

    # Light, readable dropdowns (white surface, accent text) over the dark popup.
    $bc = New-Object System.Windows.Media.BrushConverter
    $fg = $bc.ConvertFromString((Get-LogbookTheme $cfg).accent)
    $bg = $bc.ConvertFromString('#FFFFFF')
    foreach ($combo in @($access, $tujuan)) {
        $combo.Background = $bg; $combo.Foreground = $fg
        foreach ($it in $combo.Items) { try { $it.Background = $bg; $it.Foreground = $fg } catch {} }
    }
    $access.SelectedIndex = 0; $tujuan.SelectedIndex = 0

    $req = @($cfg.requiredFields)
    $validate = {
        $vals = @{ nama = $nama.Text; nim = $nim.Text; access = (Get-ComboText $access); purpose = (Get-ComboText $tujuan); keterangan = $ket.Text }
        $ok = $true
        foreach ($f in $req) { if ([string]::IsNullOrWhiteSpace([string]$vals[$f])) { $ok = $false; break } }
        $btn.IsEnabled = $ok
        if ($ok) { $btn.Opacity = 1.0; $hint.Text = [string]$cfg.text.hintReady }
        else { $btn.Opacity = 0.45; $hint.Text = [string]$cfg.text.hintIncomplete }
    }
    @($nama, $nim, $ket) | ForEach-Object { $_.Add_TextChanged($validate) }
    $tujuan.Add_SelectionChanged($validate); $tujuan.Add_KeyUp($validate)
    $access.Add_SelectionChanged($validate)
    & $validate

    $btn.Add_Click({
        $sessionType = (Get-ComboText $access).Trim()
        $obj = [ordered]@{
            session_id   = "preview-$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
            start_time   = (Get-Date).ToString('o')
            session_type = $sessionType
            username     = $env:USERNAME
            hostname     = $env:COMPUTERNAME
            nama         = $nama.Text.Trim(); nim = $nim.Text.Trim()
            tujuan       = (Get-ComboText $tujuan).Trim(); keterangan = $ket.Text.Trim()
        }
        $tmp = Join-Path $env:TEMP ("logix_preview_session_" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".json")
        $obj | ConvertTo-Json -Depth 4 | Out-File $tmp -Encoding UTF8
        [System.Windows.MessageBox]::Show(
            "Sesi dimulai (PRATINJAU).`n`n$($obj.nama) - $($obj.session_type)`nTujuan: $($obj.tujuan)`n`nDisimpan ke: $tmp`n`nCatatan: ini hanya pratinjau UI. Agent asli (logbook_popup.ps1) yang menulis sesi sungguhan lalu memulai timer.",
            "Logix - Sesi dimulai (pratinjau)") | Out-Null
        $window.Close()
    })
    $nama.Focus() | Out-Null
}

function Show-PreviewWindow([string]$xaml, [string]$title, [double]$w, [double]$h, [scriptblock]$after) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if ($after) { & $after $window }
    $window.WindowStyle = 'SingleBorderWindow'; $window.WindowState = 'Normal'
    $window.ResizeMode = 'CanResize'; $window.Topmost = $false; $window.ShowInTaskbar = $true
    $window.SizeToContent = 'Manual'; $window.Width = $w; $window.Height = $h
    $window.WindowStartupLocation = 'CenterScreen'; $window.Title = $title
    Write-Host "Opening: $title (close the window to continue)" -ForegroundColor Cyan
    [void]$window.ShowDialog()
}

if ($Surface -in 'popup', 'all') {
    Show-PreviewWindow (Build-LogbookPopupXaml $cfg) 'Logix - Sign-in Popup (INTERACTIVE PREVIEW)' 980 940 {
        param($window)
        $logoPath = [string]$cfg.branding.logoPath
        if (Test-Path $logoPath) {
            try {
                $mascot = New-Object System.Windows.Media.Imaging.BitmapImage
                $mascot.BeginInit(); $mascot.UriSource = New-Object System.Uri($logoPath); $mascot.CacheOption = 'OnLoad'; $mascot.EndInit(); $mascot.Freeze()
                $window.FindName('MascotImage').Source = $mascot
                $window.FindName('MascotImage').Visibility = 'Visible'
            } catch { Write-Host "Mascot load failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        Enable-PopupInteractive $window $cfg
    }
}

$sampleProfile = @{ nama = 'Dhana Pratama'; nim = '081234567'; tujuan = 'Running Data'; keterangan = 'batch DFT ~3 jam' }

if ($Surface -in 'welcome', 'all') {
    Show-PreviewWindow (Build-LogbookWelcomeBackXaml $cfg $sampleProfile 'SSH') 'Logix - Returning User Fast Path (PREVIEW)' 720 720 {
        param($window)
        $logoPath = [string]$cfg.branding.logoPath
        if (Test-Path $logoPath) {
            try {
                $m = New-Object System.Windows.Media.Imaging.BitmapImage
                $m.BeginInit(); $m.UriSource = New-Object System.Uri($logoPath); $m.CacheOption = 'OnLoad'; $m.EndInit(); $m.Freeze()
                $window.FindName('MascotImage').Source = $m; $window.FindName('MascotImage').Visibility = 'Visible'
            } catch {}
        }
        $window.FindName('StartBtn').Add_Click({ [System.Windows.MessageBox]::Show('Mulai Sesi (pratinjau) — resume dari profil tersimpan.', 'Preview') | Out-Null; $window.Close() })
        $window.FindName('ChangeBtn').Add_Click({ $window.Close() })
    }
}

if ($Surface -in 'timer', 'all') {
    $session = @{ session_type = 'SSH'; nama = 'A. Rahmawati'; tujuan = 'Simulasi DFT' }
    Show-PreviewWindow (Build-LogbookTimerXaml $cfg $session 'WS-07 - GPU-A100') 'Logix - Timer Widget + SELESAI (PREVIEW)' 320 360 {
        param($window)
        $window.FindName('ClockMain').Text = '02:14'
        $window.FindName('ClockSeconds').Text = '41'
    }
}

if ($Surface -in 'notif', 'all') {
    Show-PreviewWindow (Build-LogbookEmergencyOverlayXaml $cfg) 'Logix - Emergency Countdown Overlay (PREVIEW)' 700 640 {
        param($window)
        # Demo the 30->0 countdown so the preview shows the live behavior.
        $c = $window.FindName('CountNumber'); $script:pv = 30; $c.Text = '30'
        $et = New-Object Windows.Threading.DispatcherTimer
        $et.Interval = [TimeSpan]::FromSeconds(1)
        $et.Add_Tick({ $script:pv -= 1; if ($script:pv -le 0) { $c.Text = '0'; $et.Stop() } else { $c.Text = [string]$script:pv } })
        $window.FindName('SavedBtn').Add_Click({ $et.Stop(); $window.Close() })
        $et.Start()
    }
}

if ($Surface -in 'lock', 'all') {
    Show-PreviewWindow (Build-LogbookLockXaml $cfg 'Dhana Pratama' 'Pemeliharaan singkat GPU driver. Mohon tunggu ±10 menit.') 'Logix - Lock / Paused Overlay (PREVIEW)' 760 720 {
        param($window)
        $window.FindName('LockClock').Text = (Get-Date).ToString('HH:mm') + ' · ' + (Get-Date).ToString('dddd, dd MMM yyyy')
        $window.FindName('LockElapsed').Text = '02:21:07'
        $window.FindName('UnlockBtn').Add_Click({ $window.Close() })
    }
}

Write-Host 'Preview done.' -ForegroundColor Green
