param([string]$SessionId = '', [switch]$STAChild)
$ErrorActionPreference = 'Stop'
# Common loaded before the STA shim so the relaunch can use
# Start-HiddenPowerShell -- see the shim comment in logbook_popup.ps1.
. 'C:\Program Files\Logix\logbook_common.ps1'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    if ($SessionId) { $args += @('-SessionId', $SessionId) }
    Start-HiddenPowerShell -ArgumentList $args | Out-Null
    exit 0
}
Ensure-LogbookDirs

# ============================================================================
# LogiX v3 timer widget -- "Pill & Strip" controller.
# Design: docs/design_handoff_logix_v3/LogiX Timer Pill & Strip.dc.html (D-02)
#
# One instrument, two postures, both pinned to the TOP EDGE of the screen.
# The full state set this file drives (README "State Management (client
# widget)"):
#   posture   pill | strip                 -- double-click toggles, persisted
#   pill      collapsed | hovered | armed
#   strip     sliver-hidden | sliver-peeking
#   message   none | unread | reading | replying | sent
#   overlay   none | countdown | broadcast
#
# Timing constants are all from the design and are named below rather than
# scattered as literals.
#
# There is exactly ONE one-second timer (the session clock) doing all periodic
# work. The only other timer is a 100ms cursor poll that runs *solely* while
# the widget is in strip posture, to measure the 300ms top-edge dwell -- a
# GetCursorPos call is a few microseconds, so idle cost stays negligible.
# ============================================================================

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
} catch {
    Write-LogbookError "Timer WPF load failed: $($_.Exception.Message)"
    throw
}

# Win32 helpers: WS_EX_TOOLWINDOW keeps the widget out of Alt-Tab; the strip
# additionally takes WS_EX_TRANSPARENT so it is click-through and never steals
# a click from the application beneath it.
if (-not ([System.Management.Automation.PSTypeName]'LogixWin').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LogixWin {
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint="GetWindowLong")] static extern int GetWindowLong32(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtr")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll", EntryPoint="SetWindowLong")] static extern int SetWindowLong32(IntPtr h, int i, int v);
    public static void AddExStyle(IntPtr hwnd, int bits) {
        // (long)(uint) rather than a bare `cur | bits`: the int operand would
        // be sign-extended, which Add-Type compiles as CS0675 -- and it treats
        // that warning as an error, so the whole type fails to build and the
        // widget never launches. Masking to uint first keeps the high bits clean.
        long widened = (long)(uint)bits;
        if (IntPtr.Size == 8) {
            long cur = GetWindowLongPtr64(hwnd, GWL_EXSTYLE).ToInt64();
            SetWindowLongPtr64(hwnd, GWL_EXSTYLE, new IntPtr(cur | widened));
        } else {
            int cur = GetWindowLong32(hwnd, GWL_EXSTYLE);
            SetWindowLong32(hwnd, GWL_EXSTYLE, (int)((uint)cur | (uint)bits));
        }
    }
}
"@
}

if (-not (Test-Path $Global:SessionFile)) { exit 0 }
$session = Get-Content $Global:SessionFile -Raw | ConvertFrom-Json
if ($SessionId -and $session.session_id -ne $SessionId) { exit 0 }
$start = [datetime]$session.start_time
$cfg = Get-LogbookConfig
$deviceName = Get-LogbookDeviceDisplayName
$theme = Get-LogbookTheme $cfg
$brushConv = New-Object System.Windows.Media.BrushConverter

# ---- Design timings ---------------------------------------------------------
$script:COLLAPSE_SECONDS   = 5     # card auto-collapses 5s after the cursor leaves
$script:DISARM_SECONDS     = 3     # SELESAI auto-disarms if not confirmed
$script:DWELL_MS           = 300   # top-edge dwell before the sliver drops
$script:AUTOPEEK_SECONDS   = 4     # sliver auto-peek on an incoming message
$script:IDLE_WARN_SECONDS  = 300   # countdown overlay opens 5 min before auto-end
$script:EDGE_POLL_MS       = 100   # cursor poll cadence (3 polls ~= 300ms dwell)
$script:EDGE_BAND_PX       = 4     # how close to the top edge counts as "at the edge"

# reduce_motion: when the OS asks for reduced motion, every state SNAPS. This
# is a hard kill, matching the web side's prefers-reduced-motion rule.
$script:reduceMotion = -not [System.Windows.SystemParameters]::ClientAreaAnimation

$prefsPath = Join-Path $Global:StateDir 'widget_prefs.json'
function Get-LogbookWidgetPrefs {
    # Posture and horizontal anchor persist across sessions (README section 5:
    # "remembered per session"). Anchor is a 0..1 fraction of the work area so
    # it survives a resolution change.
    $defaults = @{ posture = 'pill'; anchor = 0.5; pillOpacity = 0.72 }
    try {
        if (Test-Path $prefsPath) {
            $p = Get-Content $prefsPath -Raw | ConvertFrom-Json
            # 'bar' means an external status bar (YASB) is rendering this widget, so
            # the floating window draws nothing at all. It is deliberately not in
            # the double-click cycle -- that toggle stays a predictable two-state
            # thing, and bar mode is something you configure once.
            if ($p.posture -in @('pill','strip','bar')) { $defaults.posture = [string]$p.posture }
            $a = [double]$p.anchor
            if ($a -ge 0.0 -and $a -le 1.0) { $defaults.anchor = $a }
            if ($null -ne $p.pillOpacity) {
                $o = [double]$p.pillOpacity
                if ($o -ge 0.25 -and $o -le 1.0) { $defaults.pillOpacity = $o }
            }
        }
    } catch { }
    return $defaults
}
function Save-LogbookWidgetPrefs {
    try {
        @{ posture = $script:posture; anchor = $script:anchor
           pillOpacity = $script:PILL_REST_OPACITY } |
            ConvertTo-Json | Out-File -FilePath $prefsPath -Encoding UTF8 -Force
    } catch { }
}

$prefs = Get-LogbookWidgetPrefs
$script:posture = $prefs.posture
$script:anchor  = $prefs.anchor

# ---- Windows ----------------------------------------------------------------
$xaml = Build-LogbookTimerXaml -cfg $cfg -session $session -deviceName $deviceName
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))

$pillView    = $window.FindName('PillView')
$pillDot     = $window.FindName('PillDot')
$pillClock   = $window.FindName('PillClock')
$pillBadge   = $window.FindName('PillBadge')
$pillBadgeTx = $window.FindName('PillBadgeText')
$sliverView  = $window.FindName('SliverView')
$sliverDot   = $window.FindName('SliverDot')
$sliverText  = $window.FindName('SliverText')
$sliverBadge = $window.FindName('SliverBadge')
$sliverBadgeTx = $window.FindName('SliverBadgeText')
$cardView    = $window.FindName('CardView')
$cardDot     = $window.FindName('CardDot')
$cardClock   = $window.FindName('CardClock')
$cardInfo    = $window.FindName('CardInfo')
$cardMessage = $window.FindName('CardMessage')
$messageMeta = $window.FindName('MessageMeta')
$messageText = $window.FindName('MessageText')
$cardQuick   = $window.FindName('CardQuickReply')
$cardReplyRw = $window.FindName('CardReplyRow')
$replyInput  = $window.FindName('ReplyInput')
$replySend   = $window.FindName('ReplySendBtn')
$cardSent    = $window.FindName('CardSent')
$sentText    = $window.FindName('SentText')
$selesaiBtn  = $window.FindName('SelesaiBtn')
$armedCap    = $window.FindName('ArmedCaption')
$quickOk     = $window.FindName('QuickOkBtn')
$quickWait   = $window.FindName('QuickWaitBtn')
$quickFree   = $window.FindName('QuickFreeBtn')

$stripWindow = [Windows.Markup.XamlReader]::Load(
    (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookStripXaml $cfg))))
$stripBar = $stripWindow.FindName('StripBar')

# ---- State ------------------------------------------------------------------
$script:allowClose      = $false
$script:tick            = 0
$script:cardOpen        = $false
$script:sliverOpen      = $false
$script:selesaiArmed    = $false
$script:selesaiArmTick  = -1
$script:collapseAtTick  = -1
$script:sliverHideTick  = -1
$script:msgState        = 'none'          # none|unread|reading|replying|sent
$script:msgUnread       = 0
$script:msgCommandId    = ''
$script:msgAllowReply   = $true
$script:overlayWindow   = $null
$script:overlayMode     = 'none'          # none|countdown|broadcast
$script:isDragging      = $false
$script:dragMoved       = $false
$script:dragStartX      = 0.0
$script:dragStartAnchor = 0.5

$window.Add_Closing({ param($s,$e) if (-not $script:allowClose) { $e.Cancel = $true } })
$window.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'F4') { $e.Handled = $true } })
$stripWindow.Add_Closing({ param($s,$e) if (-not $script:allowClose) { $e.Cancel = $true } })

# ---- Geometry ---------------------------------------------------------------
# WPF Left/Top are device-independent units. SystemParameters.WorkArea is
# already in those units for the primary monitor, which is where a lab
# workstation's top edge lives. Converting through the window's own
# CompositionTarget keeps placement correct when the shell reports a scaled
# desktop; note that the PowerShell host is system-DPI aware rather than
# per-monitor-v2 (that needs an app manifest we cannot attach to powershell.exe),
# so on a mixed-DPI multi-monitor rig Windows bitmap-scales the widget on the
# secondary display instead of re-rendering it.
function Get-LogbookWorkArea { return [System.Windows.SystemParameters]::WorkArea }

# RootVisual's margin is asymmetric bleed room for the drop shadow, which falls
# straight down: "20,6,20,36". These must stay in step with that margin -- the
# window is positioned so the VISUAL (not the window) lands 10px below the top
# of the work area.
$script:BLEED_SIDE = 20
$script:BLEED_TOP  = 6

# How solid the pill looks when nothing needs the user. It has to sit on top of
# somebody's title bar all day, so at rest it fades back and lets the window
# underneath show through; hover, unread and the open card all go fully opaque.
# Clamped because a widget the user cannot see is a widget they cannot dismiss.
$script:PILL_REST_OPACITY = [Math]::Max(0.25, [Math]::Min(1.0, [double]$prefs.pillOpacity))
if ([double]::IsNaN($script:PILL_REST_OPACITY)) { $script:PILL_REST_OPACITY = 0.72 }

function Update-LogbookWidgetPosition {
    $work = Get-LogbookWorkArea
    $w = $window.ActualWidth
    if ($w -le 0) { $w = $window.Width }
    if ([double]::IsNaN($w) -or $w -le 0) { return }
    $centerX = $work.Left + ($work.Width * $script:anchor)
    $left = $centerX - ($w / 2.0)
    # Keep the visible surface on screen; the transparent bleed may hang off.
    $minL = $work.Left - $script:BLEED_SIDE
    $maxL = $work.Left + $work.Width - $w + $script:BLEED_SIDE
    if ($left -lt $minL) { $left = $minL }
    if ($left -gt $maxL) { $left = $maxL }
    $window.Left = $left
    $window.Top  = $work.Top + 10 - $script:BLEED_TOP
}
$window.Add_SizeChanged({ Update-LogbookWidgetPosition })

function Update-LogbookStripPosition {
    $work = Get-LogbookWorkArea
    $stripWindow.Left = $work.Left
    $stripWindow.Top = $work.Top
    $stripWindow.Width = $work.Width
}

# ---- Status colour ----------------------------------------------------------
# Green active / blue notice / amber warning / red critical -- the four
# temperatures from the design footer. A pending message is the only thing
# that recolours the widget in normal operation.
function Get-LogbookWidgetStatusColor {
    if ($script:overlayMode -ne 'none') { return $theme.signalCritical }
    if ($script:msgState -in @('unread','reading','replying')) { return $theme.accent }
    return $theme.signalNormal
}

# The same three states as the dot, named rather than coloured, so a status bar
# can style its own slot without having to parse a hex out of the payload.
function Get-LogbookBarState {
    if ($script:overlayMode -ne 'none') { return 'critical' }
    if ($script:msgState -eq 'unread') { return 'message' }
    return 'active'
}

function Update-LogbookWidgetStatus {
    $brush = $brushConv.ConvertFromString((Get-LogbookWidgetStatusColor))
    $pillDot.Fill = $brush
    $sliverDot.Fill = $brush
    $cardDot.Fill = $brush
    $stripBar.Background = $brush
}

# ---- Motion -----------------------------------------------------------------
# Surfaces arrive from the top edge they belong to: a short slide down plus a
# fade, nothing else. Opacity and TranslateTransform only -- no size or layout
# animation, which is what made the previous widget's growth look unsteady.
#
# reduce_motion is a hard kill, not a softening: when the OS asks for it every
# surface is placed at its final position and opacity with no animation at all.
# Quintic, not cubic: a steeper departure and a much longer settle, which is
# the curve macOS uses for surfaces arriving. Cubic reads as "web easing" by
# comparison -- it arrives too evenly. Paired with slightly longer durations
# below, this is what makes the widget feel like a system component rather
# than an animated window.
$script:EASE = New-Object System.Windows.Media.Animation.QuinticEase
$script:EASE.EasingMode = 'EaseOut'

# Fade a surface out and only then collapse it. Update-LogbookWidgetView has
# already set it Collapsed by the time this runs, so it is briefly made visible
# again -- both surfaces share the same top-centre anchor and the window is
# sizing to the incoming one anyway, so nothing shifts during the overlap.
function Hide-LogbookSurface($Element, [int]$Ms = 120) {
    if (-not $Element) { return }
    if ($script:reduceMotion) { $Element.Visibility = 'Collapsed'; return }
    $Element.Visibility = 'Visible'
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [TimeSpan]::FromMilliseconds($Ms))
    $fade.EasingFunction = $script:EASE
    $fade.Add_Completed({
        $Element.Visibility = 'Collapsed'
        $Element.Opacity = 1
    }.GetNewClosure())
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
}

function Show-LogbookSurface($Element, [double]$FromY = -8, [int]$Ms = 160, [double]$FromScale = 0) {
    if (-not $Element) { return }
    $shift = $Element.RenderTransform
    if ($script:reduceMotion) {
        $Element.Opacity = 1
        if ($shift -is [System.Windows.Media.TranslateTransform]) { $shift.Y = 0 }
        if ($shift -is [System.Windows.Media.ScaleTransform]) { $shift.ScaleX = 1; $shift.ScaleY = 1 }
        return
    }
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds($Ms))
    $fade.EasingFunction = $script:EASE
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    if ($shift -is [System.Windows.Media.TranslateTransform]) {
        $slide = New-Object System.Windows.Media.Animation.DoubleAnimation($FromY, 0.0, [TimeSpan]::FromMilliseconds($Ms))
        $slide.EasingFunction = $script:EASE
        $shift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
    }
    # A macOS popover unfolds from its anchor rather than fading in place. The
    # card's origin is top-centre (set in XAML), so growing from ~96% reads as
    # the pill expanding downward into the card.
    if ($FromScale -gt 0 -and $shift -is [System.Windows.Media.ScaleTransform]) {
        $grow = New-Object System.Windows.Media.Animation.DoubleAnimation($FromScale, 1.0, [TimeSpan]::FromMilliseconds($Ms))
        $grow.EasingFunction = $script:EASE
        $shift.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $grow)
        $shift.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $grow)
    }
}

# ---- View -------------------------------------------------------------------
# Single source of truth for which of the three surfaces is showing. The window
# is Hidden outright when nothing should be visible (strip posture, sliver
# retracted) so it cannot intercept a click at the top edge.
$script:lastSurface = 'none'

function Update-LogbookWidgetView {
    $showCard   = $script:cardOpen
    $showPill   = (-not $showCard) -and ($script:posture -eq 'pill')
    $showSliver = (-not $showCard) -and ($script:posture -eq 'strip') -and $script:sliverOpen

    $cardView.Visibility   = if ($showCard)   { 'Visible' } else { 'Collapsed' }
    $pillView.Visibility   = if ($showPill)   { 'Visible' } else { 'Collapsed' }
    $sliverView.Visibility = if ($showSliver) { 'Visible' } else { 'Collapsed' }

    if ($showCard -or $showPill -or $showSliver) {
        if (-not $window.IsVisible) { $window.Show() }
    } else {
        $window.Hide()
    }

    # Animate only on an actual transition. This function runs on every tick,
    # so replaying the entrance each time would leave the widget permanently
    # twitching.
    $surface = if ($showCard) { 'card' } elseif ($showPill) { 'pill' } elseif ($showSliver) { 'sliver' } else { 'none' }
    if ($surface -ne $script:lastSurface) {
        $previous = $script:lastSurface
        $script:lastSurface = $surface
        switch ($surface) {
            # pill <-> card is a crossfade, not a cut: both are anchored to the
            # same top-centre point, so the card reads as the pill unfolding
            # rather than one element being swapped for another.
            'card'   {
                if ($previous -eq 'pill') { Hide-LogbookSurface $pillView 130 }
                Show-LogbookSurface $cardView -FromScale 0.96 -Ms 240
            }
            'pill'   {
                if ($previous -eq 'card') { Hide-LogbookSurface $cardView 130 }
                Show-LogbookSurface $pillView -FromY -4 -Ms 200
            }
            # The sliver is the one that reads as "dropping" from the edge.
            'sliver' { Show-LogbookSurface $sliverView -FromY -14 -Ms 220 }
        }
    }

    $stripWindow.Visibility = if ($script:posture -eq 'strip') { 'Visible' } else { 'Collapsed' }

    # Card contents depend on the message state machine.
    $isArmed = $script:selesaiArmed
    $hasMsg  = $script:msgState -in @('reading','replying')
    $isSent  = $script:msgState -eq 'sent'

    $cardInfo.Visibility    = if ($isArmed -or $hasMsg -or $isSent) { 'Collapsed' } else { 'Visible' }
    $cardMessage.Visibility = if ($hasMsg) { 'Visible' } else { 'Collapsed' }
    $cardQuick.Visibility   = if ($script:msgState -eq 'reading' -and $script:msgAllowReply) { 'Visible' } else { 'Collapsed' }
    $cardReplyRw.Visibility = if ($script:msgState -eq 'replying') { 'Visible' } else { 'Collapsed' }
    $cardSent.Visibility    = if ($isSent) { 'Visible' } else { 'Collapsed' }
    $armedCap.Visibility    = if ($isArmed) { 'Visible' } else { 'Collapsed' }
    # SELESAI is out of the way while the user is answering the admin.
    $selesaiBtn.Visibility  = if ($hasMsg -or $isSent) { 'Collapsed' } else { 'Visible' }
    # A message card is the wider 260px variant (design M1-M3).
    $cardView.Width = if ($hasMsg -or $isSent) { 260 } else { 240 }

    $badgeVisible = ($script:msgState -eq 'unread' -and $script:msgUnread -gt 0)
    $pillBadge.Visibility = if ($badgeVisible) { 'Visible' } else { 'Collapsed' }
    $sliverBadge.Visibility = if ($badgeVisible) { 'Visible' } else { 'Collapsed' }
    if ($badgeVisible) {
        $pillBadgeTx.Text = [string]$script:msgUnread
        $sliverBadgeTx.Text = [string]$script:msgUnread
    }
    # The pill is auto-width: it hugs the clock, and the badge widens it by
    # exactly as much as the badge needs. A fixed 150px box was mostly padding,
    # and every one of those pixels sits on top of the user's title bar.
    $pillView.Width = [double]::NaN
    # At rest the pill is deliberately faded so it reads as ambient rather than
    # as a window. Unread is the one thing worth interrupting for, so that state
    # goes fully opaque and solid.
    $pillView.Opacity = if ($badgeVisible) { 1.0 } else { $script:PILL_REST_OPACITY }
    $pillView.Background = $brushConv.ConvertFromString($(if ($badgeVisible) { '#F50B1017' } else { '#EB0B1017' }))

    Update-LogbookWidgetStatus
    Update-LogbookWidgetPosition
}

# ---- SELESAI: armed -> confirm ----------------------------------------------
function Reset-LogbookSelesai {
    $script:selesaiArmed = $false
    $script:selesaiArmTick = -1
    $selesaiBtn.Content = (Get-LogbookText $cfg 'timerEnd' 'SELESAI')
    $selesaiBtn.Background = $brushConv.ConvertFromString('#00FFFFFF')
    $selesaiBtn.BorderBrush = $brushConv.ConvertFromString($theme.border)
    $selesaiBtn.Foreground = $brushConv.ConvertFromString($theme.text)
    Update-LogbookWidgetView
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
        Update-LogbookWidgetView
    } else {
        # Confirmed. The end-session routine is called completely unchanged.
        try { Close-LogbookSessionAndLock } catch { Write-LogbookError "SELESAI failed: $($_.Exception.Message)" }
        $script:allowClose = $true
        $timer.Stop()
        $stripWindow.Close()
        $window.Close()
    }
})

# ---- Expand / collapse ------------------------------------------------------
function Open-LogbookCard {
    $script:cardOpen = $true
    $script:collapseAtTick = -1
    if ($script:msgState -eq 'unread') {
        # Reading is what clears the badge -- not the admin sending it.
        $script:msgState = 'reading'
        $script:msgUnread = 0
    }
    Update-LogbookWidgetView
}

function Close-LogbookCard {
    $script:cardOpen = $false
    $script:collapseAtTick = -1
    if ($script:selesaiArmed) { Reset-LogbookSelesai }
    if ($script:msgState -in @('reading','sent')) { $script:msgState = 'none' }
    Update-LogbookWidgetView
}

function Start-LogbookCollapseCountdown {
    # The card must not vanish mid-sentence while the user is typing a reply.
    if ($script:msgState -eq 'replying' -and $replyInput.IsKeyboardFocusWithin) { return }

    # Anything the user still needs to READ gets the full linger: an admin
    # message they have just opened, and the "Terkirim ke admin" confirmation.
    # Everything else collapses the instant the cursor leaves -- the widget is
    # ambient, and a card that hangs around for seconds over whatever they went
    # back to doing reads as being in the way. (The design's flat 5s linger was
    # written for the message case and felt far too slow applied to the plain
    # session card.)
    if ($script:msgState -in @('reading', 'sent')) {
        $script:collapseAtTick = $script:tick + $script:COLLAPSE_SECONDS
        return
    }
    Close-LogbookCard
}

# WPF's own enter/leave, kept as a second path to the same dwell -- the cursor
# poll in Register-LogbookClickThrough is the primary one, because a
# click-through window receives no mouse messages at all. Both must go through
# the dwell or the slower one would still expand on contact.
$window.Add_MouseEnter({
    $script:collapseAtTick = -1
    if (-not $script:cardOpen -and $script:posture -eq 'pill') { $script:hoverDwell.Start() }
})
$window.Add_MouseLeave({
    $script:hoverDwell.Stop()
    if ($script:cardOpen) { Start-LogbookCollapseCountdown }
})

# ---- Posture toggle + top-edge drag ----------------------------------------
function Set-LogbookPosture([string]$Next) {
    $script:posture = $Next
    $script:cardOpen = $false
    $script:sliverOpen = $false
    $script:sliverHideTick = -1
    Save-LogbookWidgetPrefs
    if ($Next -eq 'strip') { $script:edgeTimer.Start() } else { $script:edgeTimer.Stop() }
    Update-LogbookWidgetView
}

$dragHandler = {
    param($s, $e)
    if ($e.ClickCount -eq 2) {
        Set-LogbookPosture $(if ($script:posture -eq 'pill') { 'strip' } else { 'pill' })
        $e.Handled = $true
        return
    }
    # Top-edge-only drag: horizontal position is the single degree of freedom,
    # so the widget can never be stranded in the middle of the screen.
    $p = New-Object LogixWin+POINT
    [void][LogixWin]::GetCursorPos([ref]$p)
    $script:isDragging = $true
    $script:dragMoved = $false
    $script:dragStartX = [double]$p.X
    $script:dragStartAnchor = $script:anchor
    [void]$window.CaptureMouse()
}
$pillView.Add_MouseLeftButtonDown($dragHandler)
$sliverView.Add_MouseLeftButtonDown($dragHandler)

$window.Add_MouseMove({
    if (-not $script:isDragging) { return }
    $p = New-Object LogixWin+POINT
    [void][LogixWin]::GetCursorPos([ref]$p)
    $work = Get-LogbookWorkArea
    if ($work.Width -le 0) { return }
    $dx = [double]$p.X - $script:dragStartX
    # A few pixels of travel is a click, not a drag -- without this the sliver
    # could never be clicked open, because the button-down always arms a drag.
    if ([Math]::Abs($dx) -gt 3) { $script:dragMoved = $true }
    $delta = $dx / [double]$work.Width
    $a = $script:dragStartAnchor + $delta
    if ($a -lt 0.0) { $a = 0.0 }
    if ($a -gt 1.0) { $a = 1.0 }
    $script:anchor = $a
    Update-LogbookWidgetPosition
})

$window.Add_MouseLeftButtonUp({
    if (-not $script:isDragging) { return }
    $script:isDragging = $false
    $window.ReleaseMouseCapture()
    # Snap to the nearest quarter mark when close, so the widget lands on a
    # tidy position instead of wherever the cursor happened to stop.
    foreach ($snap in @(0.25, 0.5, 0.75)) {
        if ([Math]::Abs($script:anchor - $snap) -lt 0.05) { $script:anchor = $snap; break }
    }
    Save-LogbookWidgetPrefs
    Update-LogbookWidgetPosition
})

# Clicking the sliver opens the full card (design state 06). This fires before
# the window-level handler that clears the drag flags, so it tests dragMoved.
$sliverView.Add_MouseLeftButtonUp({
    if ($script:dragMoved) { return }
    Open-LogbookCard
})

# ---- Strip posture: 300ms top-edge dwell -----------------------------------
# Polled rather than event-driven because in strip posture there is no window
# under the cursor to raise MouseEnter -- the strip itself is click-through by
# design. Three consecutive polls at the edge is the 300ms dwell, which a quick
# cursor pass across the top of the screen will not satisfy.
$script:edgeHits = 0
$script:edgeTimer = New-Object Windows.Threading.DispatcherTimer
$script:edgeTimer.Interval = [TimeSpan]::FromMilliseconds($script:EDGE_POLL_MS)
$script:edgeTimer.Add_Tick({
    if ($script:posture -ne 'strip' -or $script:cardOpen) { return }
    $p = New-Object LogixWin+POINT
    if (-not [LogixWin]::GetCursorPos([ref]$p)) { return }
    $work = Get-LogbookWorkArea
    $atEdge = ($p.Y -le ($work.Top + $script:EDGE_BAND_PX))
    if ($atEdge) {
        $script:edgeHits += 1
        if ($script:edgeHits -ge [int]($script:DWELL_MS / $script:EDGE_POLL_MS) -and -not $script:sliverOpen) {
            $script:sliverOpen = $true
            $script:sliverHideTick = -1
            Update-LogbookWidgetView
        }
    } else {
        $script:edgeHits = 0
        # Retract once the cursor leaves, unless an auto-peek is still running.
        if ($script:sliverOpen -and $script:sliverHideTick -lt 0) {
            $script:sliverOpen = $false
            Update-LogbookWidgetView
        }
    }
})

# ---- Admin message ----------------------------------------------------------
$msgPath = Join-Path $Global:StateDir 'incoming_message.json'

function Send-LogbookWidgetReply([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $ok = Send-LogbookReply -Text $Text -CommandId $script:msgCommandId
    $script:msgState = 'sent'
    $sentText.Text = if ($ok) {
        'Terkirim ke admin ' + [char]0x00B7 + ' ' + (Get-Date).ToString('HH:mm')
    } else {
        'Gagal terkirim -- akan dicoba lagi'
    }
    $replyInput.Text = ''
    Update-LogbookWidgetView
    Start-LogbookCollapseCountdown
}

$quickOk.Add_Click({ Send-LogbookWidgetReply 'OK' })
$quickWait.Add_Click({ Send-LogbookWidgetReply 'Butuh 10 mnt' })
$quickFree.Add_Click({
    $script:msgState = 'replying'
    Update-LogbookWidgetView
    [void]$replyInput.Focus()
})
$replySend.Add_Click({ Send-LogbookWidgetReply $replyInput.Text })
$replyInput.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') { Send-LogbookWidgetReply $replyInput.Text; $e.Handled = $true }
})

function Show-LogbookPendingMessage {
    if (-not (Test-Path $msgPath)) { return }
    try {
        $msg = Get-Content $msgPath -Raw | ConvertFrom-Json
        $receivedAt = [datetime]$msg.received_at
        if (((Get-Date) - $receivedAt).TotalMinutes -gt 5) { return }

        # An emergency escapes both postures to the centered overlay -- too
        # important to sit as a badge in the corner.
        if ([string]$msg.reason -eq 'Emergency Alert') {
            Show-LogbookOverlay -Mode 'broadcast' -Body ([string]$msg.text)
            return
        }

        $script:msgCommandId  = [string]$msg.command_id
        $script:msgAllowReply = ($msg.allow_reply -ne $false)
        $messageText.Text = [string]$msg.text
        $label = if ([string]$msg.reason -eq 'Screen View Notice') { 'PRIVASI' } else { 'ADMIN' }
        $messageMeta.Text = $label + ' ' + [char]0x00B7 + ' ' + $receivedAt.ToString('HH:mm')
        $script:msgState = 'unread'
        $script:msgUnread += 1

        # Strip posture is the ONE place a background event is allowed to
        # move: the strip turns blue and the sliver peeks for 4s, then
        # retracts. In pill posture nothing moves -- the badge just appears.
        if ($script:posture -eq 'strip') {
            $script:sliverOpen = $true
            $script:sliverHideTick = $script:tick + $script:AUTOPEEK_SECONDS
        }
        Update-LogbookWidgetView
    } catch {
        Write-LogbookError "Timer: failed to show pending message: $($_.Exception.Message)"
    } finally {
        Remove-Item $msgPath -Force -ErrorAction SilentlyContinue
    }
}

# ---- Shared countdown / broadcast overlay -----------------------------------
# One component, two modes (README: "Emergency Broadcast and idle-auto-end
# countdown share the same overlay component").
function Show-LogbookOverlay {
    param([ValidateSet('countdown','broadcast')][string]$Mode, [string]$Body = '', [int]$Seconds = 300)
    if ($script:overlayWindow) { return }   # one overlay at a time
    try {
        $ow = [Windows.Markup.XamlReader]::Load(
            (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookCountdownOverlayXaml $cfg))))
        $ow.Topmost = $true
        $script:overlayWindow = $ow
        $script:overlayMode = $Mode
        $count  = $ow.FindName('CountNumber')
        $title  = $ow.FindName('OverlayTitle')
        $bodyTb = $ow.FindName('OverlayBody')
        $extend = $ow.FindName('ExtendBtn')
        $endNow = $ow.FindName('EndNowBtn')
        $ack    = $ow.FindName('AckBtn')

        $script:overlayRemaining = $Seconds

        # The countdown numeral is driven by the main one-second tick, so
        # closing the overlay is purely a state reset -- no timer to stop.
        $closeOverlay = {
            $script:overlayWindow = $null
            $script:overlayMode = 'none'
            Update-LogbookWidgetView
            try { $ow.Close() } catch { }
        }.GetNewClosure()

        if ($Mode -eq 'broadcast') {
            $title.Text = (Get-LogbookText $cfg 'emergencyTitle' 'Pengumuman darurat')
            $count.Visibility = 'Collapsed'
            $bodyTb.Text = $Body
            $extend.Visibility = 'Collapsed'
            $endNow.Visibility = 'Collapsed'
            $ack.Visibility = 'Visible'
            $ack.Add_Click($closeOverlay)
        } else {
            $title.Text = (Get-LogbookText $cfg 'idleWarnTitle' 'Sesi berakhir dalam')
            $count.Text = ('{0:00}:{1:00}' -f [int]($Seconds / 60), ($Seconds % 60))
            $bodyTb.Text = (Get-LogbookText $cfg 'idleWarnBody' `
                'Idle terdeteksi. Gerakkan mouse atau perpanjang untuk melanjutkan.')
            $ack.Visibility = 'Collapsed'
            # Pressing "Perpanjang sesi" is itself input, so GetLastInputInfo
            # resets and the monitor's idle auto-close backs off -- dismissing
            # the overlay is all this needs to do.
            $extend.Add_Click($closeOverlay)
            $endNow.Add_Click({
                try { Close-LogbookSessionAndLock } catch { Write-LogbookError "Overlay end failed: $($_.Exception.Message)" }
                & $closeOverlay
                $script:allowClose = $true
                $timer.Stop()
                try { $stripWindow.Close() } catch { }
                $window.Close()
            }.GetNewClosure())
        }

        $ow.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'F4') { $e.Handled = $true } })
        [void]$ow.Show()

        # The overlay is the one surface that interrupts the user, so it gets a
        # slightly stronger arrival: the scrim fades up while the card settles
        # from 96%. Still no overshoot -- this is a warning, not a flourish.
        if (-not $script:reduceMotion) {
            $card = $ow.FindName('OverlayCard')
            $scrim = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(180))
            $scrim.EasingFunction = $script:EASE
            $ow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $scrim)
            if ($card -and $card.RenderTransform -is [System.Windows.Media.ScaleTransform]) {
                $pop = New-Object System.Windows.Media.Animation.DoubleAnimation(0.96, 1.0, [TimeSpan]::FromMilliseconds(200))
                $pop.EasingFunction = $script:EASE
                $card.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $pop)
                $card.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $pop)
            }
        }
        Update-LogbookWidgetView
    } catch {
        Write-LogbookError "Overlay failed: $($_.Exception.Message)"
        $script:overlayWindow = $null
        $script:overlayMode = 'none'
    }
}

# ---- The one-second session clock ------------------------------------------
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if (-not (Test-Path $Global:SessionFile)) {
        $script:allowClose = $true
        $timer.Stop()
        # A bar slot still showing a running clock after the session ended is
        # worse than an empty one: it asserts something untrue about a machine
        # nobody is watching.
        Clear-LogbookBarStatus
        try { $stripWindow.Close() } catch { }
        $window.Close()
        return
    }
    try {
        $current = Get-Content $Global:SessionFile -Raw | ConvertFrom-Json
        if ($SessionId -and $current.session_id -ne $SessionId) {
            $script:allowClose = $true
            $timer.Stop()
            Clear-LogbookBarStatus
            try { $stripWindow.Close() } catch { }
            $window.Close()
            return
        }
    } catch { }

    # Actions a status bar asked for, e.g. YASB's on_right callback. Polled
    # rather than pushed because the bar is a separate process with no handle
    # on this window; a one-shot file is the cheapest honest channel.
    $requested = Read-LogbookBarAction
    if ($requested -eq 'open') {
        # The card is posture-independent (Update-LogbookWidgetView keys it off
        # cardOpen alone), so it can appear over a bar-mode setup and vanish
        # again on collapse WITHOUT dragging the user back into pill posture.
        Open-LogbookCard
    } elseif ($requested -eq 'posture') {
        Set-LogbookPosture $(if ($script:posture -eq 'bar') { 'pill' } else { 'bar' })
    }

    $elapsed = (Get-Date) - $start
    $hh = [int][Math]::Floor($elapsed.TotalHours)
    $pillClock.Text = ('{0:00}:{1:00}' -f $hh, $elapsed.Minutes)
    $cardClock.Text = ('{0:00}:{1:00}:{2:00}' -f $hh, $elapsed.Minutes, $elapsed.Seconds)
    $sliverText.Text = $pillClock.Text + ' ' + [char]0x00B7 + ' ' + $script:stationLabel
    $script:tick += 1

    # Publish for a status bar (see Write-LogbookBarStatus). Done here rather
    # than from a separate poller because this tick already holds every value
    # a bar wants, one second fresh.
    Write-LogbookBarStatus `
        -Text $pillClock.Text `
        -Alt ($script:stationLabel + ' ' + [char]0x00B7 + ' ' + $cardClock.Text) `
        -Tooltip ("{0} {1} {2}" -f $script:stationLabel, [char]0x00B7, $cardClock.Text) `
        -State (Get-LogbookBarState)

    if ($script:selesaiArmed -and ($script:tick - $script:selesaiArmTick) -ge $script:DISARM_SECONDS) {
        Reset-LogbookSelesai
    }
    if ($script:collapseAtTick -ge 0 -and $script:tick -ge $script:collapseAtTick) {
        if ($script:msgState -eq 'replying' -and $replyInput.IsKeyboardFocusWithin) {
            $script:collapseAtTick = $script:tick + $script:COLLAPSE_SECONDS
        } else {
            Close-LogbookCard
        }
    }
    if ($script:sliverHideTick -ge 0 -and $script:tick -ge $script:sliverHideTick) {
        $script:sliverHideTick = -1
        $script:sliverOpen = $false
        Update-LogbookWidgetView
    }
    if ($script:overlayWindow -and $script:overlayMode -eq 'countdown') {
        $script:overlayRemaining -= 1
        if ($script:overlayRemaining -lt 0) { $script:overlayRemaining = 0 }
        $c = $script:overlayWindow.FindName('CountNumber')
        if ($c) { $c.Text = ('{0:00}:{1:00}' -f [int]($script:overlayRemaining / 60), ($script:overlayRemaining % 60)) }
    }

    Show-LogbookPendingMessage
    Test-LogbookIdleWarning
})

# The monitor owns the actual idle auto-close (logbook_monitor.ps1); this only
# owns the 5-minute warning the design promises the user, so the two can never
# disagree about when a session ends.
#
# The idle threshold is CACHED. Get-LogbookIdleTimeoutSeconds reads the policy
# out of Get-LogbookConfig, which refreshes from the server -- calling it on
# every one-second tick meant one HTTP round-trip per second per workstation,
# which on a full lab is a needless constant load (and it buried the agent log
# in "Fetching config from server" lines). The policy is an admin setting that
# changes rarely; once a minute is far more than enough.
$script:idleLimitSec = -1
$script:idleLimitTick = -999

function Get-LogbookCachedIdleLimit {
    if ($script:idleLimitSec -lt 0 -or ($script:tick - $script:idleLimitTick) -ge 60) {
        $script:idleLimitSec = Get-LogbookIdleTimeoutSeconds
        $script:idleLimitTick = $script:tick
    }
    return $script:idleLimitSec
}

function Test-LogbookIdleWarning {
    try {
        if ($script:overlayWindow) { return }
        if (Test-Path (Join-Path $Global:StateDir 'workstation_locked.flag')) { return }
        $idleSec = Get-LogbookIdleSeconds
        if ($null -eq $idleSec) { return }
        # Nothing to warn about until the user has actually been idle a while;
        # skip the policy lookup entirely in the common case.
        if ($idleSec -lt 60) { return }
        $limitSec = Get-LogbookCachedIdleLimit
        if ($limitSec -le 0) { return }
        $remaining = $limitSec - $idleSec
        if ($remaining -le $script:IDLE_WARN_SECONDS -and $remaining -gt 0) {
            Show-LogbookOverlay -Mode 'countdown' -Seconds ([int]$remaining)
        }
    } catch { Write-LogbookError "Idle warning check failed: $($_.Exception.Message)" }
}

# ---- Boot -------------------------------------------------------------------
# Same spaced-separator rule as Build-LogbookTimerXaml: "WS-07 - GPU-A100"
# yields the station ID "WS-07", not "WS".
$script:stationLabel = ([regex]::Split([string]$deviceName, '\s+(?:-|\u00B7)\s+'))[0].Trim()
if (-not $script:stationLabel) { $script:stationLabel = $env:COMPUTERNAME }

# How long the pointer must REST on the pill before it expands. Long enough
# that crossing the top edge on the way to a browser tab does not summon a
# 240px card over the thing you were reaching for; short enough that deliberate
# hover still feels immediate. Collapse stays instant -- the asymmetry is the
# point: opening should require intent, closing should not.
$script:HOVER_DWELL_MS = 350
$script:hoverDwell = New-Object System.Windows.Threading.DispatcherTimer
$script:hoverDwell.Interval = [TimeSpan]::FromMilliseconds($script:HOVER_DWELL_MS)
$script:hoverDwell.Add_Tick({
    $script:hoverDwell.Stop()
    if (-not $script:cardOpen -and $script:posture -eq 'pill') { Open-LogbookCard }
})

$window.Add_SourceInitialized({
    # Out of Alt-Tab, and never steals focus from the app the user is in.
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    [LogixWin]::AddExStyle($h, [LogixWin]::WS_EX_TOOLWINDOW -bor [LogixWin]::WS_EX_NOACTIVATE)

    # Clicks land on the app underneath unless the user is actually pointing at
    # the widget. See Register-LogbookClickThrough for why this is necessary.
    #
    # The enter/leave callbacks are not redundant with $window.Add_MouseEnter:
    # while the window is click-through WPF receives no mouse messages at all,
    # so this poll -- not WPF -- is what notices the pointer arriving.
    $script:clickThroughTimer = Register-LogbookClickThrough -Window $window -GetSurface {
        if ($script:cardOpen)               { $cardView }
        elseif ($script:posture -eq 'pill') { $pillView }
        elseif ($script:sliverOpen)         { $sliverView }
        else                                { $null }
    } -OnPointerEnter {
        # Arrival is not intent. The pill sits on the top edge of the screen,
        # which is also where browser tabs and title bars live, so the cursor
        # crosses it constantly on the way to something else -- and expanding
        # on contact turned a 72px pill into a 240px card exactly when the user
        # was reaching for the window underneath. Wait for them to stay.
        $script:collapseAtTick = -1
        $script:hoverDwell.Start()
    } -OnPointerLeave {
        $script:hoverDwell.Stop()
        if ($script:cardOpen) { Start-LogbookCollapseCountdown }
    }
})
$stripWindow.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $stripWindow).Handle
    [LogixWin]::AddExStyle($h,
        [LogixWin]::WS_EX_TOOLWINDOW -bor [LogixWin]::WS_EX_NOACTIVATE -bor [LogixWin]::WS_EX_TRANSPARENT)
})

$window.Add_Loaded({
    # Signals the sign-in popup (a separate process) that the widget has
    # actually reached the screen, so it can time its own close against
    # reality rather than a fixed schedule. See Invoke-LogbookHandoffToTimer
    # in logbook_popup.ps1.
    try { '' | Out-File -FilePath (Join-Path $Global:StateDir 'timer_ready.flag') -Force -Encoding UTF8 } catch { }
})

# Show() + Dispatcher.Run() rather than ShowDialog(): the widget is a
# non-modal always-on-top surface, and Update-LogbookWidgetView legitimately
# calls Hide() (strip posture with the sliver retracted) -- ShowDialog would
# fight that by forcing the window back up.
$window.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

[void]$stripWindow.Show()
Update-LogbookStripPosition
[void]$window.Show()
Update-LogbookWidgetView
if ($script:posture -eq 'strip') { $script:edgeTimer.Start() }

# A message that landed while this process was still starting would otherwise
# wait a full second for the first tick.
Show-LogbookPendingMessage
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()
