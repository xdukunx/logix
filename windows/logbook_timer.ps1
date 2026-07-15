param([string]$SessionId = '', [switch]$STAChild)
$ErrorActionPreference = 'Stop'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    if ($SessionId) { $args += @('-SessionId', $SessionId) }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args | Out-Null
    exit 0
}
. 'C:\Program Files\Logix\logbook_common.ps1'
Ensure-LogbookDirs

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
} catch {
    Write-LogbookError "Timer WPF load failed: $($_.Exception.Message)"
    throw
}

if (-not (Test-Path $Global:SessionFile)) { exit 0 }
$session = Get-Content $Global:SessionFile -Raw | ConvertFrom-Json
if ($SessionId -and $session.session_id -ne $SessionId) { exit 0 }
$start = [datetime]$session.start_time
$cfg = Get-LogbookConfig
$deviceName = Get-LogbookDeviceDisplayName

$xaml = Build-LogbookTimerXaml -cfg $cfg -session $session -deviceName $deviceName
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$shapePath = $window.FindName('ShapePath')
$contentGrid = $window.FindName('ContentGrid')
$clockMain = $window.FindName('ClockMain')
$clockSeconds = $window.FindName('ClockSeconds')
$pulse = $window.FindName('Pulse')
$infoSection = $window.FindName('InfoSection')
$messageSection = $window.FindName('MessageSection')
$messageText = $window.FindName('MessageText')
$messageIconBadge = $window.FindName('MessageIconBadge')
$messageIcon = $window.FindName('MessageIcon')
$messageTitle = $window.FindName('MessageTitle')
$selesaiBtn = $window.FindName('SelesaiBtn')

# SELESAI is a two-step control (design: LogiX Timer Widget). First press ARMS
# it (turns red, "Tekan lagi untuk selesai"); a confirming second press within
# ~3s ends the session via the unchanged Close-LogbookSessionAndLock path. If
# ignored, the clock tick auto-reverts it. Lock/sleep remain a pause, not a
# departure -- only this deliberate two-step ends a session from the widget.
$script:selesaiArmed = $false
$script:selesaiArmTick = -1
$brushConv = New-Object System.Windows.Media.BrushConverter
$theme = Get-LogbookTheme $cfg
function Reset-LogbookSelesai {
    $script:selesaiArmed = $false
    $selesaiBtn.Content = (Get-LogbookText $cfg 'timerEnd' 'SELESAI')
    $selesaiBtn.Background = $brushConv.ConvertFromString('#14FFFFFF')
    $selesaiBtn.BorderBrush = $brushConv.ConvertFromString($theme.border)
    $selesaiBtn.Foreground = $brushConv.ConvertFromString($theme.muted)
}
$selesaiBtn.Add_Click({
    if (-not $script:selesaiArmed) {
        $script:selesaiArmed = $true
        $script:selesaiArmTick = $script:tick
        $selesaiBtn.Content = (Get-LogbookText $cfg 'timerEndArmed' 'Tekan lagi untuk selesai')
        $red = $brushConv.ConvertFromString($theme.signalCritical)
        $selesaiBtn.Background = $red
        $selesaiBtn.BorderBrush = $red
        $selesaiBtn.Foreground = $brushConv.ConvertFromString('#FFFFFF')
    } else {
        try { Close-LogbookSessionAndLock } catch { Write-LogbookError "SELESAI failed: $($_.Exception.Message)" }
        $script:allowClose = $true
        $timer.Stop()
        $window.Close()
    }
})

# Smooth breathing pulse instead of a discrete character swap.
$pulseAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.25, [TimeSpan]::FromSeconds(1.1))
$pulseAnim.AutoReverse = $true
$pulseAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
$pulseAnim.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
$pulse.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulseAnim)

# Keeps the chamfered shape's Path.Data/Grid.Clip matched to the window's
# current width and height.
function Sync-LogbookTimerShape {
    $data = Get-LogbookTimerShapeData ($window.Height - 20) ($window.Width - 20)
    $geom = [System.Windows.Media.Geometry]::Parse($data)
    $shapePath.Data = $geom
    $contentGrid.Clip = $geom
}

# Fixed, deterministic target sizes -- no runtime measurement of WPF
# layout at all. Two earlier approaches (toggling the window's own
# SizeToContent mode, then WPF's Measure()/DesiredSize) both produced
# wrong/huge heights that only surfaced on an actual Windows run, never in
# the XML-structural tests. These constants trade a little visual slack
# (a message with unusually long text may run slightly tight) for being
# simple enough to reason about and guaranteed not to misfire.
$script:HEIGHT_COLLAPSED = 182   # status + clock + the always-visible SELESAI
                                 # button (Nama/Tujuan/Device collapsed).
                                 # Measured via ContentGrid.Measure() = 158.8
                                 # natural + 20 shape margin, +3 slack.
$script:HEIGHT_EXPANDED  = 265   # + Nama/Tujuan/Device + accent bar, on top of
                                 # SELESAI. Measured = 241.7 natural + 20 + 3.
$script:MESSAGE_EXTRA    = 110   # replaced per-message by a measured value
                                 # (see Show-LogbookPendingMessage); this is
                                 # only the pre-first-message default

# One place decides how tall the widget should be. Width is FIXED at the
# narrow clock width -- the widget only ever grows downward (info section
# on first 10s / hover, admin message), never to the right.
function Get-LogbookTimerTargetSize {
    $infoShown = $infoSection.Visibility -eq 'Visible'
    $msgShown = $messageSection.Visibility -eq 'Visible'
    $h = if ($infoShown) { $script:HEIGHT_EXPANDED } else { $script:HEIGHT_COLLAPSED }
    if ($msgShown) { $h += $script:MESSAGE_EXTRA }
    return @{ Width = $window.Width; Height = $h }
}

$script:allowClose = $false
$script:tick = 0
$script:messageHideAtTick = -1
$script:isHovering = $false
$window.Add_Closing({ param($s,$e) if (-not $script:allowClose) { $e.Cancel = $true } })
$window.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'F4') { $e.Handled = $true } })
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })

# Stepped size transition: window bounds AND shape geometry are kept in
# sync at every step, so the shape genuinely grows/shrinks rather than the
# window just cropping a static shape. Width and height animate together
# in the same steps. One persistent DispatcherTimer, reconfigured per-call
# via script-scoped state (matches the single-timer idiom the rest of this
# file already uses for the clock tick).
$script:animTimer = New-Object Windows.Threading.DispatcherTimer
$script:animTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$script:animFromH = 0.0
$script:animToH = 0.0
$script:animFromW = 0.0
$script:animToW = 0.0
$script:animStep = 0
$script:animSteps = 24
$script:animTimer.Add_Tick({
    $script:animStep += 1
    $t = $script:animStep / [double]$script:animSteps
    if ($t -ge 1) {
        $window.Height = $script:animToH
        $window.Width = $script:animToW
        Sync-LogbookTimerShape
        $script:animTimer.Stop()
        return
    }
    $eased = 1 - [Math]::Pow(1 - $t, 3)
    $window.Height = $script:animFromH + ($script:animToH - $script:animFromH) * $eased
    $window.Width = $script:animFromW + ($script:animToW - $script:animFromW) * $eased
    Sync-LogbookTimerShape
})

# Animates the window to whatever Get-LogbookTimerTargetSize currently
# says, no-op when already there.
function Update-LogbookTimerSize {
    $target = Get-LogbookTimerTargetSize
    if ([Math]::Abs($window.Height - $target.Height) -lt 0.5 -and
        [Math]::Abs($window.Width - $target.Width) -lt 0.5) { return }
    $script:animTimer.Stop()
    $script:animFromH = $window.Height
    $script:animToH = $target.Height
    $script:animFromW = $window.Width
    $script:animToW = $target.Width
    $script:animStep = 0
    $script:animTimer.Start()
}

# Full info (nama/tujuan/device) shows for the first 10 seconds of a
# session, or on hover -- collapsed the rest of the time so the widget is
# just the clock, letting the user focus on time, not data. SELESAI lives in
# its own row (a sibling of InfoSection, not nested inside it -- see
# Build-LogbookTimerXaml), so it stays visible at all times regardless of
# this toggle. The window then animates to the matching size.
function Update-LogbookInfoVisibility {
    $elapsedSec = ((Get-Date) - $start).TotalSeconds
    $shouldShow = $script:isHovering -or ($elapsedSec -le 10)
    $isShown = $infoSection.Visibility -eq 'Visible'
    if ($shouldShow -ne $isShown) {
        $infoSection.Visibility = if ($shouldShow) { 'Visible' } else { 'Collapsed' }
    }
    Update-LogbookTimerSize
}
$window.Add_MouseEnter({ $script:isHovering = $true; Update-LogbookInfoVisibility })
$window.Add_MouseLeave({ $script:isHovering = $false; Update-LogbookInfoVisibility })

$msgPath = Join-Path $Global:StateDir 'incoming_message.json'

# Reason -> accent color for the message's left border/badge/title. Emergency
# always reads as urgent red regardless of the faculty's chosen brand accent;
# anything else (Direction Message and future reasons) uses the configured
# accent color instead.
# Three notification temperatures (design: LogiX Notifications). Emergency is
# always urgent red; a Screen View Notice uses its own calm privacy signal
# (never alarm-red); everything else uses the configured brand accent.
function Get-LogbookMessageBorderColor([string]$Reason, $Cfg) {
    $th = Get-LogbookTheme $Cfg
    if ($Reason -eq 'Emergency Alert') { return $th.signalCritical }
    if ($Reason -eq 'Screen View Notice') { return $th.signalNotice }
    return $th.accent
}

function Set-LogbookMessageContent($Msg) {
    $color = Get-LogbookMessageBorderColor $Msg.reason $cfg
    $brush = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($color)
    )
    $messageSection.BorderBrush = $brush
    $messageIconBadge.Background = $brush
    $messageTitle.Foreground = $brush
    if ($Msg.reason -eq 'Emergency Alert') {
        $messageTitle.Text = (Get-LogbookText $cfg 'emergencyTitle' 'Peringatan Sistem')
        $messageIcon.Text = '!'
    } elseif ($Msg.reason -eq 'Screen View Notice') {
        # Variant 2 -- privacy notice: dignified, calm teal, the privacy promise
        # made visible. allow_reply is false, so no reply box is offered.
        $messageTitle.Text = (Get-LogbookText $cfg 'noticePrivacyTitle' 'Pemberitahuan Privasi')
        $messageIcon.Text = 'i'
    } else {
        $messageTitle.Text = (Get-LogbookText $cfg 'msgFromAdmin' 'Pesan dari Admin')
        $messageIcon.Text = 'i'
    }
    $messageText.Text = [string]$Msg.text
}

# Variant 3 -- emergency escapes the widget to a centered, dimmed overlay with
# a live 30->0 DispatcherTimer countdown, so a pending shutdown is unmissable.
function Show-LogbookEmergencyOverlay([int]$Seconds = 30) {
    try {
        $ow = [Windows.Markup.XamlReader]::Load(
            (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookEmergencyOverlayXaml $cfg))))
        $ow.Topmost = $true
        $count = $ow.FindName('CountNumber')
        $ring = $ow.FindName('Ring')
        $script:emgRemaining = $Seconds
        $count.Text = [string]$Seconds
        $pa = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.3, [TimeSpan]::FromSeconds(0.6))
        $pa.AutoReverse = $true
        $pa.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $ring.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pa)
        $et = New-Object Windows.Threading.DispatcherTimer
        $et.Interval = [TimeSpan]::FromSeconds(1)
        $et.Add_Tick({
            $script:emgRemaining -= 1
            if ($script:emgRemaining -le 0) { $count.Text = '0'; $et.Stop(); $ow.Close(); return }
            $count.Text = [string]$script:emgRemaining
        })
        $ow.FindName('SavedBtn').Add_Click({ $et.Stop(); $ow.Close() })
        $ow.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'F4') { $e.Handled = $true } })
        $et.Start()
        [void]$ow.Show()
    } catch { Write-LogbookError "Emergency overlay failed: $($_.Exception.Message)" }
}

function Show-LogbookPendingMessage {
    if (-not (Test-Path $msgPath)) { return }
    try {
        $msg = Get-Content $msgPath -Raw | ConvertFrom-Json
        $receivedAt = [datetime]$msg.received_at
        if (((Get-Date) - $receivedAt).TotalMinutes -gt 5) {
            Remove-Item $msgPath -Force -ErrorAction SilentlyContinue
            return
        }
        # Variant 3: emergencies escape to the centered overlay instead of the
        # inline widget message -- too important to live in a corner.
        if ([string]$msg.reason -eq 'Emergency Alert') {
            Remove-Item $msgPath -Force -ErrorAction SilentlyContinue
            Show-LogbookEmergencyOverlay 30
            return
        }
        Set-LogbookMessageContent $msg
        $messageSection.Opacity = 0
        $messageSection.Visibility = 'Visible'
        # Text wraps a lot at the fixed narrow width, so a constant height
        # can't fit every message. Measure just this one section at its
        # known available width (NOT the whole window -- whole-window
        # Measure/SizeToContent is what misfired in earlier iterations)
        # and clamp hard, mirroring Get-LogbookTimerShapeData's guard.
        $availW = ($window.Width - 20) - 28   # shape width minus section side margins
        $messageSection.Measure((New-Object System.Windows.Size $availW, ([double]::PositiveInfinity)))
        $script:MESSAGE_EXTRA = [Math]::Round(
            [Math]::Min([Math]::Max($messageSection.DesiredSize.Height + 14, 90), 220))
        Update-LogbookTimerSize
        $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(420))
        $fadeIn.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
        $messageSection.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
        $script:messageHideAtTick = $script:tick + 20
    } catch {
        Write-LogbookError "Timer: failed to show pending message: $($_.Exception.Message)"
    } finally {
        Remove-Item $msgPath -Force -ErrorAction SilentlyContinue
    }
}

function Hide-LogbookMessage {
    $messageSection.Visibility = 'Collapsed'
    Update-LogbookTimerSize
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if (-not (Test-Path $Global:SessionFile)) {
        $script:allowClose = $true
        $timer.Stop()
        $window.Close()
        return
    }
    try {
        $current = Get-Content $Global:SessionFile -Raw | ConvertFrom-Json
        if ($SessionId -and $current.session_id -ne $SessionId) {
            $script:allowClose = $true
            $timer.Stop()
            $window.Close()
            return
        }
    } catch {}

    $elapsed = (Get-Date) - $start
    $clockMain.Text = ('{0:00}:{1:00}' -f [math]::Floor($elapsed.TotalHours), $elapsed.Minutes)
    $clockSeconds.Text = ('{0:00}' -f $elapsed.Seconds)
    $script:tick += 1

    # Auto-revert an armed SELESAI that wasn't confirmed within ~3s.
    if ($script:selesaiArmed -and ($script:tick - $script:selesaiArmTick) -ge 3) { Reset-LogbookSelesai }

    Update-LogbookInfoVisibility
    Show-LogbookPendingMessage

    if ($script:messageHideAtTick -ge 0 -and $script:tick -ge $script:messageHideAtTick) {
        Hide-LogbookMessage
        $script:messageHideAtTick = -1
    }
})

# A message sent just before this process finished launching would
# otherwise be missed until the first tick a second later -- check once
# immediately too.
Show-LogbookPendingMessage
$timer.Start()
[void]$window.ShowDialog()
