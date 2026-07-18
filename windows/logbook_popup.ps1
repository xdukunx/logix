param([switch]$TestMode, [switch]$ForceNew, [switch]$STAChild)
$ErrorActionPreference = 'Stop'

# Dot-sourced BEFORE the STA shim on purpose: common's top level only sets
# globals and defines functions (no window, no STA dependency), so loading it
# first lets the relaunch reuse Start-HiddenPowerShell -- the one place that
# owns the conhost --headless + argument-quoting launch contract.
. 'C:\Program Files\Logix\logbook_common.ps1'

# WPF must run in STA. If Task Scheduler/Run launches normal PowerShell, relaunch safely.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    if ($TestMode) { $args += '-TestMode' }
    if ($ForceNew) { $args += '-ForceNew' }
    # Hidden console only -- the WPF sign-in form still shows (same pattern the
    # timer uses). Avoids a stray powershell window on the desktop.
    Start-HiddenPowerShell -ArgumentList $args | Out-Null
    exit 0
}

Ensure-LogbookDirs
$cfg = Get-LogbookConfig
# Combo dropdowns render as a light control (white surface, dark text) for
# readability over the dark popup; the text uses the brand accent so it stays
# on-theme when a lab re-brands. See Set-ReadableComboBox.
$script:comboFg = (Get-LogbookTheme $cfg).accent
Write-LogbookInfo "Popup launch TestMode=$TestMode ForceNew=$ForceNew"

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
} catch {
    Write-LogbookError "WPF load failed: $($_.Exception.Message)"
    throw
}

# If a previous popup run crashed/was force-killed before it could restore
# Task Manager (see Set-TaskManagerDisabled in logbook_common.ps1), and no
# other popup instance is currently showing, clear that stale lock before
# gating it again for this run.
try {
    $staleMarker = Join-Path $Global:StateDir 'taskmgr_prev_value.txt'
    if ((Test-Path $staleMarker) -and -not (Test-LogbookPopupRunning)) {
        Set-TaskManagerDisabled -Disabled $false
    }
} catch {}

# If there is an active session and this is not an explicit new interactive unlock, only restore timer.
# If ForceNew is set, close stale previous session first so the report gets END/Auto Finish + duration.
if ((Test-Path $Global:SessionFile) -and -not $TestMode) {
    $age = Get-ActiveLogbookSessionAgeSeconds
    if ($ForceNew -and ($null -eq $age -or $age -gt 5)) {
        Close-ActiveLogbookSession -Reason 'AUTO_FINISH' | Out-Null
    } elseif (Close-OverAgeLogbookSessionIfAny) {
        # Session was left open past the max-session cap (typically locked or
        # slept across the night). It has just been closed; fall through to
        # render a fresh sign-in form instead of resuming a timer that would
        # read from yesterday.
    } else {
        $active = Get-ActiveLogbookSession
        if ($active -and $active.session_id) { Start-LogbookTimer -SessionId $active.session_id | Out-Null }
        exit 0
    }
}

function New-BlurredBackgroundImage {
    try {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bmp.Size)
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
        $ms.Position = 0
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $img.StreamSource = $ms
        $img.EndInit()
        $img.Freeze()
        $ms.Dispose()
        return $img
    } catch {
        Write-LogbookError "Screenshot blur background failed: $($_.Exception.Message)"
        return $null
    }
}

# Fade the fullscreen sign-in form out, then close, so the handoff to the
# centered timer widget reads as one smooth motion instead of a hard cut. The
# caller must have already set its close guard ($script:submitted /
# $script:fpChoice) so the window's Closing handler lets Close() through when
# the fade completes. Animates the window's CONTENT (a Grid), not the Window
# itself: Window.Opacity only takes effect with AllowsTransparency, which these
# forms don't set, whereas a child UIElement's Opacity always animates. Falls
# back to an immediate close if anything goes wrong -- never leaves the form
# stuck on screen.
function Invoke-LogbookFadeClose($win) {
    try {
        $root = $win.Content
        if (-not $root) { $win.Close(); return }
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [TimeSpan]::FromMilliseconds(300))
        $ez = New-Object System.Windows.Media.Animation.CubicEase; $ez.EasingMode = 'EaseIn'
        $fade.EasingFunction = $ez
        $fade.Add_Completed({ try { $win.Close() } catch {} })
        $root.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    } catch {
        try { $win.Close() } catch {}
    }
}

# Cached across the fast path -> full form transition. Clicking "Bukan saya /
# ganti data" used to rebuild the full form AND recapture a fresh fullscreen
# blurred screenshot (New-BlurredBackgroundImage: CopyFromScreen + PNG
# encode/decode, a few hundred ms of blocking work) -- the visible lag on that
# button. The fast path already captured an identical desktop screenshot, so we
# reuse the frozen bitmap (safe to share across windows once Frozen) and skip
# the second capture, making the switch feel instant.
$script:cachedBg = $null
$script:cachedMascot = $null

$sessionInfo = Get-LogbookSessionType
$detectedSessionType = [string]$sessionInfo[0]
$detectedAnyDesk = [int]$sessionInfo[1]
$sessionId = "win-$($env:USERNAME)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$profileFile = Join-Path $Global:StateDir 'last_profile.json'

# Shared session-start used by BOTH the full sign-in form and the returning-
# user fast path, so the two paths can never drift. Writes the session file +
# local profile, logs START, and starts the timer.
function Invoke-LogbookStartSession {
    param([string]$Nama, [string]$Nim, [string]$Access, [string]$Tujuan, [string]$Keterangan)
    Ensure-LogbookDirs
    $sessionType = $Access.Trim()
    $sid = "win-$env:USERNAME-$([DateTimeOffset]::Now.ToUnixTimeSeconds())-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $anydeskDetected = $(if ($sessionType -eq 'AnyDesk') { 1 } else { 0 })
    $obj = [ordered]@{
        session_id       = $sid
        start_time       = (Get-Date).ToString('o')
        session_type     = $sessionType
        anydesk_detected = $anydeskDetected
        username         = $env:USERNAME
        windows_user     = "$env:USERDOMAIN\$env:USERNAME"
        hostname         = $env:COMPUTERNAME
        nama             = $Nama.Trim()
        nim              = $Nim.Trim()
        tujuan           = $Tujuan.Trim()
        keterangan       = $Keterangan.Trim()
    }
    $obj | ConvertTo-Json -Depth 4 | Out-File -FilePath $Global:SessionFile -Encoding UTF8 -Force
    # Persist locally so the fast path can resume next time (identity never
    # leaves the machine except via the normal START log).
    ([ordered]@{ nama = $obj.nama; nim = $obj.nim; tujuan = $obj.tujuan; keterangan = $obj.keterangan } |
        ConvertTo-Json -Depth 3) | Out-File -FilePath $profileFile -Encoding UTF8 -Force
    $logged = Invoke-WSLLogbook -Event 'START' -SessionType $sessionType -AnyDeskDetected $anydeskDetected -SessionId $sid -Nama $obj.nama -Nim $obj.nim -Tujuan $obj.tujuan -Keterangan $obj.keterangan
    if (-not $logged) { Write-LogbookError "START logging failed but continuing safely. sid=$sid" }
    Start-LogbookTimer -SessionId $sid | Out-Null
    return $true
}

# Returning-user fast path (C8.1): a saved profile + not a forced fresh form
# -> offer one-tap resume before the full sign-in form. "Bukan saya / ganti
# data" falls through to the full form below.
if ((-not $ForceNew) -and (Test-Path $profileFile)) {
    try {
        $fpProfile = Get-Content $profileFile -Raw | ConvertFrom-Json
        if ($fpProfile.nama -and $fpProfile.nim) {
            $fpWindow = [Windows.Markup.XamlReader]::Load(
                (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookWelcomeBackXaml $cfg $fpProfile $detectedSessionType))))
            $fpWindow.WindowState = 'Normal'
            $fpWindow.Left = [System.Windows.Forms.SystemInformation]::VirtualScreen.Left
            $fpWindow.Top = [System.Windows.Forms.SystemInformation]::VirtualScreen.Top
            $fpWindow.Width = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
            $fpWindow.Height = [System.Windows.Forms.SystemInformation]::VirtualScreen.Height
            $fpWindow.Topmost = $true
            $fpBg = New-BlurredBackgroundImage
            if ($fpBg) { $fpWindow.FindName('BgImage').Source = $fpBg; $script:cachedBg = $fpBg }
            $fpLogo = [string]$cfg.branding.logoPath
            if (Test-Path $fpLogo) {
                try {
                    $m = New-Object System.Windows.Media.Imaging.BitmapImage
                    $m.BeginInit(); $m.UriSource = New-Object System.Uri($fpLogo); $m.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $m.EndInit(); $m.Freeze()
                    $fpWindow.FindName('MascotImage').Source = $m
                    $fpWindow.FindName('MascotImage').Visibility = 'Visible'
                    $script:cachedMascot = $m
                } catch {}
            }
            $script:fpChoice = 'pending'
            $fpWindow.Add_Closing({ param($s, $e) if ($script:fpChoice -eq 'pending') { $e.Cancel = $true } })
            $fpWindow.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'F4') { $e.Handled = $true } })
            $fpWindow.FindName('StartBtn').Add_Click({
                try {
                    $ket = [string]$fpProfile.keterangan
                    if ([string]::IsNullOrWhiteSpace($ket)) { $ket = '(lanjutan sesi)' }
                    Invoke-LogbookStartSession -Nama ([string]$fpProfile.nama) -Nim ([string]$fpProfile.nim) -Access $detectedSessionType -Tujuan ([string]$fpProfile.tujuan) -Keterangan $ket | Out-Null
                } catch { Write-LogbookError "Fast-path start failed: $($_.Exception.Message)" }
                $script:fpChoice = 'resumed'
                # Fade the form out as the timer takes over -- resume path gets
                # the same smooth handoff as a fresh sign-in.
                Invoke-LogbookFadeClose $fpWindow
            })
            # "Bukan saya / ganti data": close instantly (no fade) and fall
            # through to the full form, which now reuses the cached background
            # so it appears without the old recapture lag.
            $fpWindow.FindName('ChangeBtn').Add_Click({ $script:fpChoice = 'form'; $fpWindow.Close() })
            try {
                Set-TaskManagerDisabled -Disabled $true
                Enable-LogbookKeyboardLockdown
                [void]$fpWindow.ShowDialog()
            } finally {
                Disable-LogbookKeyboardLockdown
                Set-TaskManagerDisabled -Disabled $false
            }
            if ($script:fpChoice -eq 'resumed') { exit 0 }
            # otherwise fall through to the full sign-in form below
        }
    } catch { Write-LogbookError "Fast path skipped, showing full form: $($_.Exception.Message)" }
}

$xaml = Build-LogbookPopupXaml $cfg

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Override WindowState to normal and span all connected screens (multi-monitor coverage)
$window.WindowState = 'Normal'
$window.Left = [System.Windows.Forms.SystemInformation]::VirtualScreen.Left
$window.Top = [System.Windows.Forms.SystemInformation]::VirtualScreen.Top
$window.Width = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
$window.Height = [System.Windows.Forms.SystemInformation]::VirtualScreen.Height

$window.Add_StateChanged({
    if ($window.WindowState -ne 'Normal') {
        $window.WindowState = 'Normal'
        $window.Left = [System.Windows.Forms.SystemInformation]::VirtualScreen.Left
        $window.Top = [System.Windows.Forms.SystemInformation]::VirtualScreen.Top
        $window.Width = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
        $window.Height = [System.Windows.Forms.SystemInformation]::VirtualScreen.Height
    }
})

$window.Topmost = $true
$window.Activate() | Out-Null

# Reuse the fast path's frozen screenshot when present (instant "ganti data"
# switch); only capture a fresh one when arriving at the full form directly.
$bg = if ($script:cachedBg) { $script:cachedBg } else { New-BlurredBackgroundImage }
if ($bg -ne $null) { $window.FindName('BgImage').Source = $bg }
# Mascot hero: load branding.logoPath (the mascot PNG the installer lays down
# at C:\Program Files\Logix\logo.png) into MascotImage above the wordmark. The
# LogoText wordmark stays visible beneath it, so a missing/broken image just
# leaves a clean wordmark-only header. Reuse the fast path's frozen copy if we
# already loaded it.
$logoPath = [string]$cfg.branding.logoPath
if ($script:cachedMascot) {
    $window.FindName('MascotImage').Source = $script:cachedMascot
    $window.FindName('MascotImage').Visibility = 'Visible'
} elseif (Test-Path $logoPath) {
    try {
        $mascot = New-Object System.Windows.Media.Imaging.BitmapImage
        $mascot.BeginInit(); $mascot.UriSource = New-Object System.Uri($logoPath); $mascot.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $mascot.EndInit(); $mascot.Freeze()
        $window.FindName('MascotImage').Source = $mascot
        $window.FindName('MascotImage').Visibility = 'Visible'
    } catch { Write-LogbookError "Mascot load failed: $($_.Exception.Message)" }
}
# SessionBadge existed in the older layout, but the revamped layout removes it.
# Keep this guarded so the popup does not crash when the element is absent.
$sessionBadge = $window.FindName('SessionBadge')
if ($null -ne $sessionBadge) {
    try {
        if ($sessionBadge -is [System.Windows.Controls.ContentControl]) {
            $sessionBadge.Content = "Detected: $detectedSessionType | $env:COMPUTERNAME"
        } else {
            $sessionBadge.Text = "Detected: $detectedSessionType | $env:COMPUTERNAME"
        }
    } catch {
        Write-LogbookError "SessionBadge update skipped: $($_.Exception.Message)"
    }
}
$window.FindName('StartTimeText').Text = [string]$cfg.text.startHint

$nama = $window.FindName('NamaBox')
$nim = $window.FindName('NimBox')
Set-LogbookNumericOnly $nim
$access = $window.FindName('AccessBox')
$tujuan = $window.FindName('TujuanBox')
$ket = $window.FindName('KetBox')
$btn = $window.FindName('SubmitBtn')

$hint = $window.FindName('HintText')

# Force ComboBox readability. Some WPF themes ignore XAML setters for the
# non-editable selection box and render white text on a white drop-down.
function Set-ComboVisualTreeReadable($root, $fg, $bg) {
    try {
        if ($root -is [System.Windows.Controls.TextBox]) {
            $root.Foreground = $fg
            $root.Background = $bg
            $root.CaretBrush = $fg
        } elseif ($root -is [System.Windows.Controls.TextBlock]) {
            $root.Foreground = $fg
        }
        $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
        for ($i = 0; $i -lt $count; $i++) {
            Set-ComboVisualTreeReadable ([System.Windows.Media.VisualTreeHelper]::GetChild($root, $i)) $fg $bg
        }
    } catch {}
}

function Set-ReadableComboBox($combo) {
    try {
        $brushConverter = New-Object System.Windows.Media.BrushConverter
        $fg = $brushConverter.ConvertFromString($script:comboFg)
        $bg = $brushConverter.ConvertFromString('#FFFFFF')
        $border = $brushConverter.ConvertFromString('#C0C0C0')
        $combo.IsEnabled = $true
        $combo.Background = $bg
        $combo.Foreground = $fg
        $combo.BorderBrush = $border
        [System.Windows.Documents.TextElement]::SetForeground($combo, $fg)
        foreach ($item in $combo.Items) {
            try {
                $item.Background = $bg
                $item.Foreground = $fg
                [System.Windows.Documents.TextElement]::SetForeground($item, $fg)
            } catch {}
        }
        $combo.ApplyTemplate() | Out-Null
        Set-ComboVisualTreeReadable $combo $fg $bg
        $combo.Add_Loaded({
            param($sender, $eventArgs)
            try {
                $bc = New-Object System.Windows.Media.BrushConverter
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString($script:comboFg)) ($bc.ConvertFromString('#FFFFFF'))
            } catch {}
        })
        $combo.Add_DropDownOpened({
            param($sender, $eventArgs)
            try {
                $bc = New-Object System.Windows.Media.BrushConverter
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString($script:comboFg)) ($bc.ConvertFromString('#FFFFFF'))
            } catch {}
        })
        $combo.Add_DropDownClosed({
            param($sender, $eventArgs)
            try {
                $bc = New-Object System.Windows.Media.BrushConverter
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString($script:comboFg)) ($bc.ConvertFromString('#FFFFFF'))
            } catch {}
        })
    } catch {
        Write-LogbookError "Combo readable patch failed: $($_.Exception.Message)"
    }
}
Set-ReadableComboBox $access
Set-ReadableComboBox $tujuan
$script:submitted = $false

if ($detectedSessionType -eq 'AnyDesk') { $access.SelectedIndex = 1 } else { $access.SelectedIndex = 0 }
$tujuan.SelectedIndex = 0
try {
    if (Test-Path $profileFile) {
        $last = Get-Content $profileFile -Raw | ConvertFrom-Json
        if ($last.nama) { $nama.Text = [string]$last.nama }
        if ($last.nim) { $nim.Text = [string]$last.nim }
        $allowedPurpose = @($cfg.purposes)
        if ($last.tujuan -and ($allowedPurpose -contains ([string]$last.tujuan))) {
            for ($i = 0; $i -lt $tujuan.Items.Count; $i++) {
                if ([string]$tujuan.Items[$i].Content -eq [string]$last.tujuan) { $tujuan.SelectedIndex = $i; break }
            }
        }
    }
} catch { Write-LogbookError "Profile prefill failed: $($_.Exception.Message)" }

function Get-ComboText($combo) {
    $txt = ''
    try { $txt = [string]$combo.Text } catch {}
    if (-not [string]::IsNullOrWhiteSpace($txt)) { return $txt }
    try {
        if ($combo.SelectedItem -and $combo.SelectedItem.Content) { return [string]$combo.SelectedItem.Content }
    } catch {}
    return ''
}

$requiredFields = @($cfg.requiredFields)
$validate = {
    # A field counts as filled unless it is listed in requiredFields and empty.
    $values = @{
        nama       = $nama.Text
        nim        = $nim.Text
        access     = (Get-ComboText $access)
        purpose    = (Get-ComboText $tujuan)
        keterangan = $ket.Text
    }
    $ok = $true
    foreach ($field in $requiredFields) {
        if ([string]::IsNullOrWhiteSpace([string]$values[$field])) { $ok = $false; break }
    }
    $btn.IsEnabled = $ok
    if ($ok) {
        $btn.Opacity = 1.0
        $hint.Text = [string]$cfg.text.hintReady
    } else {
        $btn.Opacity = 0.45
        $hint.Text = [string]$cfg.text.hintIncomplete
    }
}
@($nama,$nim,$ket) | ForEach-Object { $_.Add_TextChanged($validate) }
$tujuan.Add_TextInput($validate)
$tujuan.Add_KeyUp($validate)
$tujuan.Add_SelectionChanged($validate)
$tujuan.Add_DropDownClosed($validate)
$access.Add_SelectionChanged($validate)
& $validate

$window.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape' -or (($e.SystemKey -eq 'F4') -and (($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0))) {
        $e.Handled = $true
    }
})
$window.Add_Closing({ param($sender, $e) if (-not $script:submitted) { $e.Cancel = $true } })

$btn.Add_Click({
    try {
        Ensure-LogbookDirs
        $btn.IsEnabled = $false
        $btn.Content = 'Menyimpan...'
        Invoke-LogbookStartSession -Nama $nama.Text -Nim $nim.Text -Access (Get-ComboText $access) -Tujuan (Get-ComboText $tujuan) -Keterangan $ket.Text | Out-Null
        $script:submitted = $true
        # Session is started and the timer process is launching; fade the form
        # out so it dissolves as the timer appears centered on screen.
        Invoke-LogbookFadeClose $window
    } catch {
        Write-LogbookError "Submit failed but form released: $($_.Exception.Message)"
        $script:submitted = $true
        try { $window.Close() } catch {}
    } finally {
        try { $btn.Content = 'Mulai sesi'; $btn.IsEnabled = $true } catch {}
    }
})

# Gate Task Manager for the duration of the sign-in prompt so the process
# can't be bypassed by killing it via Task Manager; always restored in
# `finally`, which runs on submit, on a caught exception, and on any
# unhandled exception that unwinds out of ShowDialog().
try {
    Set-TaskManagerDisabled -Disabled $true
    # Kiosk lockdown while the form is up (skipped in TestMode so a tester is
    # never trapped). Always released in the finally, whatever happens.
    if (-not $TestMode) { Enable-LogbookKeyboardLockdown }
    $nama.Focus() | Out-Null
    [void]$window.ShowDialog()
} finally {
    Disable-LogbookKeyboardLockdown
    Set-TaskManagerDisabled -Disabled $false
}
