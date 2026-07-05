param([switch]$TestMode, [switch]$ForceNew, [switch]$STAChild)
$ErrorActionPreference = 'Stop'

# WPF must run in STA. If Task Scheduler/Run launches normal PowerShell, relaunch safely.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    if ($TestMode) { $args += '-TestMode' }
    if ($ForceNew) { $args += '-ForceNew' }
    # Hidden console only -- the WPF sign-in form still shows (same pattern the
    # timer uses). Avoids a stray powershell window on the desktop.
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args | Out-Null
    exit 0
}

. 'C:\Program Files\Logix\logbook_common.ps1'
Ensure-LogbookDirs
$cfg = Get-LogbookConfig
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

$sessionInfo = Get-LogbookSessionType
$detectedSessionType = [string]$sessionInfo[0]
$detectedAnyDesk = [int]$sessionInfo[1]
$sessionId = "win-$($env:USERNAME)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$profileFile = Join-Path $Global:StateDir 'last_profile.json'

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

$bg = New-BlurredBackgroundImage
if ($bg -ne $null) { $window.FindName('BgImage').Source = $bg }
$logoPath = [string]$cfg.branding.logoPath
if (Test-Path $logoPath) {
    try {
        $logo = New-Object System.Windows.Media.Imaging.BitmapImage
        $logo.BeginInit(); $logo.UriSource = New-Object System.Uri($logoPath); $logo.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $logo.EndInit(); $logo.Freeze()
        $window.FindName('LogoImage').Source = $logo
        $window.FindName('LogoImage').Visibility = 'Visible'
        $window.FindName('LogoText').Visibility = 'Collapsed'
    } catch { Write-LogbookError "Logo load failed: $($_.Exception.Message)" }
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
        $fg = $brushConverter.ConvertFromString('#741B47')
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
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString('#741B47')) ($bc.ConvertFromString('#FFFFFF'))
            } catch {}
        })
        $combo.Add_DropDownOpened({
            param($sender, $eventArgs)
            try {
                $bc = New-Object System.Windows.Media.BrushConverter
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString('#741B47')) ($bc.ConvertFromString('#FFFFFF'))
            } catch {}
        })
        $combo.Add_DropDownClosed({
            param($sender, $eventArgs)
            try {
                $bc = New-Object System.Windows.Media.BrushConverter
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString('#741B47')) ($bc.ConvertFromString('#FFFFFF'))
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
        $purpose = (Get-ComboText $tujuan).Trim()
        $sessionType = (Get-ComboText $access).Trim()
        $sessionId = "win-$env:USERNAME-$([DateTimeOffset]::Now.ToUnixTimeSeconds())-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $anydeskDetected = $(if ($sessionType -eq 'AnyDesk') { 1 } else { 0 })
        $startTime = Get-Date
        $obj = [ordered]@{
            session_id = $sessionId
            start_time = $startTime.ToString('o')
            session_type = $sessionType
            anydesk_detected = $anydeskDetected
            username = $env:USERNAME
            windows_user = "$env:USERDOMAIN\$env:USERNAME"
            hostname = $env:COMPUTERNAME
            nama = $nama.Text.Trim()
            nim = $nim.Text.Trim()
            tujuan = $purpose
            keterangan = $ket.Text.Trim()
        }
        $obj | ConvertTo-Json -Depth 4 | Out-File -FilePath $Global:SessionFile -Encoding UTF8 -Force
        ([ordered]@{ nama=$obj.nama; nim=$obj.nim; tujuan=$obj.tujuan } | ConvertTo-Json -Depth 3) | Out-File -FilePath $profileFile -Encoding UTF8 -Force

        $logged = Invoke-WSLLogbook -Event 'START' -SessionType $sessionType -AnyDeskDetected $anydeskDetected -SessionId $sessionId -Nama $obj.nama -Nim $obj.nim -Tujuan $obj.tujuan -Keterangan $obj.keterangan
        if (-not $logged) {
            Write-LogbookError "START logging failed but form will continue to close safely. sid=$sessionId"
        }

        Start-LogbookTimer -SessionId $sessionId | Out-Null
        $script:submitted = $true
        $window.Close()
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
    $nama.Focus() | Out-Null
    [void]$window.ShowDialog()
} finally {
    Set-TaskManagerDisabled -Disabled $false
}
