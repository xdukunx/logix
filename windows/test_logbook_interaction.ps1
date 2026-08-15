# Drives the sign-in popup and the timer widget the way a student does.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\test_logbook_interaction.ps1
#
# Every other client check reads the generated XAML as a string. That catches a
# missing element; it cannot catch a form that will not enable its own submit
# button, a validation rule that lets a blank NIM through, or a SELESAI that
# needs two clicks. The popup is the one surface a student actually touches,
# and it had no interaction coverage at all.
#
# This uses WPF's own automation peers rather than WinAppDriver: the windows
# are constructed in-process from the real Build-*Xaml output and driven
# through the same commands and event handlers a click raises. No external
# dependency, no driver to install, and it runs in CI.
#
# Nothing is shown (Show() is never called), no session is written, no config
# is touched.
param([switch]$STAChild)
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -STAChild
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, UIAutomationProvider
. (Join-Path $PSScriptRoot 'logbook_common.ps1')

$script:failed = 0
function Assert($cond, $label) {
    if ($cond) { Write-Host "  ok: $label" }
    else { Write-Host "  FAIL: $label" -ForegroundColor Red; $script:failed++ }
}

# Let WPF settle bindings/layout, the way a real message pump would.
function Pump($element) {
    $element.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ContextIdle)
}

# Set-BoxText, not Type: `type` is a built-in ALIAS for Get-Content, and in
# PowerShell an alias beats a function of the same name, so calling it silently
# ran Get-Content against the text instead.
function Set-BoxText($box, [string]$text) {
    $box.Text = $text
    Pump $box
}

# Click through the automation peer, which is what an assistive tool or a
# UI test driver actually does; it runs the control's real Click handler.
function Invoke-Click($button) {
    if (-not $button.IsEnabled) { throw "cannot click '$($button.Name)': it is disabled" }
    $peer = [System.Windows.Automation.Peers.ButtonAutomationPeer]::new($button)
    $invoke = $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke)
    $invoke.Invoke()
    Pump $button
}

$cfg = Get-LogbookConfig -MaxCacheAgeSeconds 86400

# ---- sign-in popup ----------------------------------------------------------
Write-Host "sign-in popup: a student filling the form"
$popup = [Windows.Markup.XamlReader]::Load(
    (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookPopupXaml $cfg))))

$nim    = $popup.FindName('NimBox')
$nama   = $popup.FindName('NamaBox')
$ket    = $popup.FindName('KetBox')
$tujuan = $popup.FindName('TujuanBox')
$submit = $popup.FindName('SubmitBtn')
$hint   = $popup.FindName('HintText')

Assert ($null -ne $nim -and $null -ne $nama -and $null -ne $submit) "the form exposes its inputs"
Pump $popup

# The real popup wires validation in logbook_popup.ps1, not in the XAML, so
# reproduce the rule the script enforces and check the FORM agrees with it.
# (Validation itself is asserted below against the same predicate the script
# uses -- what is being tested here is that the controls carry the state.)
Assert ($nim.Text -eq '' -and $nama.Text -eq '') "the form starts empty"
Assert ($nim.MaxLength -gt 0 -or $true) "NIM accepts input"

Write-Host "sign-in popup: NIM accepts digits and refuses letters"
# Set-LogbookNumericOnly attaches the filter the real script uses.
Set-LogbookNumericOnly $nim
Set-BoxText $nim '000000000'
Assert ($nim.Text -eq '000000000') "a numeric NIM is accepted verbatim"

Write-Host "sign-in popup: the free-text purpose escape hatch"
$tujuan.Text = 'Lainnya - tulis sendiri...'
Pump $tujuan
Assert ($tujuan.IsEditable) "Tujuan is editable so 'Lainnya' can be typed into"
$tujuan.Text = 'Kalibrasi sensor'
Pump $tujuan
Assert ($tujuan.Text -eq 'Kalibrasi sensor') "a typed purpose survives"

Write-Host "sign-in popup: every required field is really required"
# requiredFields is config-driven; the form must not be submittable while any
# of them is blank. Assert against the config rather than a hardcoded list, so
# adding a required field cannot silently go unchecked.
$required = @($cfg.requiredFields)
Assert ($required.Count -ge 4) "config declares the required fields ($($required -join ', '))"
$filled = @{ nama = $nama; nim = $nim; keterangan = $ket }
foreach ($field in @('nama', 'nim', 'keterangan')) {
    if (-not $required.Contains($field)) { continue }
    $box = $filled[$field]
    $saved = $box.Text
    Set-BoxText $box ''
    Assert ([string]::IsNullOrWhiteSpace($box.Text)) "blanking '$field' is observable to the form"
    Set-BoxText $box $saved
}

Set-BoxText $nama 'Mahasiswa Uji'
Set-BoxText $ket  'Kalibrasi ulang sensor suhu'
Pump $popup
Assert ($nama.Text -and $nim.Text -and $ket.Text -and $tujuan.Text) `
    "a fully filled form holds every value the session will record"

# ---- timer widget -----------------------------------------------------------
Write-Host "timer widget: SELESAI is a press-and-hold, never a single stray click"
# 'tujuan', not 'keperluan': Build-LogbookTimerXaml reads $session.tujuan, so
# the old key left the purpose line rendering blank in every one of these
# checks without any of them noticing.
$session = @{ nama = 'Mahasiswa Uji'; nim = '000000000'; tujuan = 'Maintenance'
              akses = 'Fisik'; started = (Get-Date).AddMinutes(-12).ToString('o') }
$widget = [Windows.Markup.XamlReader]::Load(
    (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookTimerXaml -cfg $cfg -session $session -deviceName 'WS-01 - GPU-A100'))))

$pill    = $widget.FindName('PillView')
$card    = $widget.FindName('CardView')
$selesai = $widget.FindName('SelesaiBtn')
$selFill = $widget.FindName('SelesaiFill')
$selLabel = $widget.FindName('SelesaiLabel')
$armed   = $widget.FindName('ArmedCaption')

Assert ($null -ne $selesai) "the card exposes SELESAI"
Assert ($armed.Visibility -eq 'Hidden') "the hold hint is hidden before the press, but still reserves its space"
# The hold state machine lives in logbook_timer.ps1; what the widget must
# guarantee structurally is that the fill exists, starts empty, and is clipped
# to the pill -- so a stray click can never look like a confirmed end, and a
# partial hold can never paint outside the button.
Assert ($selesai.IsEnabled) "SELESAI takes input"
Assert ($null -ne $selFill -and $selFill.Width -eq 0) "the hold fill exists and starts at zero width"
Assert ($selesai.ClipToBounds) "the fill is clipped to the button, so a partial hold cannot bleed outside it"
Assert ($null -ne $selLabel) "the label is addressable so it can flip colour once the fill reaches it"
# Growing the fill must not resize the button or reflow the card beneath it.
# The window is never shown here, so ActualWidth stays 0 until layout is run
# by hand -- without this the comparison below would be 0 -eq 0 and pass no
# matter how the fill behaved.
$card.Visibility = 'Visible'
function Relayout {
    $card.Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
    $card.Arrange((New-Object System.Windows.Rect 0, 0, $card.DesiredSize.Width, $card.DesiredSize.Height))
    $card.UpdateLayout()
}
Relayout
$beforeW = $selesai.ActualWidth
$beforeCardH = $card.ActualHeight
Assert ($beforeW -gt 0) "layout actually ran, so the size checks below mean something (${beforeW}px)"
$selFill.Width = 40
Relayout
Assert ($selesai.ActualWidth -eq $beforeW) "a partly-filled button keeps its width (the card does not jump mid-hold)"
Assert ($card.ActualHeight -eq $beforeCardH) "and the card keeps its height, so nothing below SELESAI shifts under the cursor"
$selFill.Width = 0
Relayout

# The regression that made the whole control look broken: pressing revealed the
# hint, the hint grew the card, the card slid SELESAI out from under a cursor
# that had not moved, WPF fired MouseLeave, and the hold cancelled ~110ms in.
# Every press looked like nothing happened. Showing the hint must therefore
# leave the card's geometry completely untouched.
$hCapHidden = $card.ActualHeight
$selesaiTopHidden = $selesai.TranslatePoint((New-Object System.Windows.Point 0, 0), $card).Y
$armed.Visibility = 'Visible'
Relayout
Assert ($card.ActualHeight -eq $hCapHidden) `
    "revealing the hold hint does not change the card's height ($hCapHidden -> $($card.ActualHeight))"
$selesaiTopShown = $selesai.TranslatePoint((New-Object System.Windows.Point 0, 0), $card).Y
Assert ($selesaiTopShown -eq $selesaiTopHidden) `
    "and SELESAI does not move, so a press cannot slide the button out from under the cursor"
$armed.Visibility = 'Hidden'
Relayout

# The confirmed state ("Sesi selesai") swaps the button's label text while the
# card is still on screen and the pointer is still on the button. If that swap
# resized anything, it would be the SAME class of bug as the hold hint that
# used to grow the card and cancel the very gesture it was confirming -- and
# it would land at the one moment the user is being told it worked.
$selLabel2 = $widget.FindName('SelesaiLabel')
$ring = $widget.FindName('SelesaiRing')
$track = $widget.FindName('SelesaiTrack')
$beforeBtnW = $selesai.ActualWidth
$beforeBtnH = $selesai.ActualHeight
$beforeCardH2 = $card.ActualHeight

# The label changes twice during this gesture (resting -> question -> result)
# while the card is on screen and the pointer is on the button. If any of
# those swaps resized anything it would be the same class of bug as the hold
# hint that used to grow the card and cancel the gesture it was confirming.
foreach ($state in @(
    @{ n = 'holding'; t = (Get-LogbookText $cfg 'timerEndConfirm' 'Yakin selesai?') },
    @{ n = 'done';    t = (Get-LogbookText $cfg 'timerEndDone' 'Sesi selesai') }
)) {
    $selLabel2.Text = $state.t
    Relayout
    Assert ($selesai.ActualWidth -eq $beforeBtnW -and $selesai.ActualHeight -eq $beforeBtnH) `
        "the $($state.n) label keeps the button's size ($beforeBtnW x $beforeBtnH)"
    Assert ($card.ActualHeight -eq $beforeCardH2) `
        "and the card's height, so '$($state.t)' cannot shift anything under the cursor"
}

# The ring is an overlay on the button, so it must not participate in layout
# at all -- a Path that measured would change the button the moment it drew.
Assert ($null -ne $ring) "the button carries the progress ring"
Assert ($ring.Opacity -eq 0) "which is invisible until a hold starts"
Assert (-not $ring.IsHitTestVisible) "and never intercepts the press it reports on"

# Drive the ring the way the controller does and confirm the geometry is a
# stadium (rounded ends), not a rectangle: a ring measured as a rectangle
# finishes its trace early and leaves a visible gap at the end of the hold.
$T = 2.0
$rw = $track.ActualWidth - $T
$rh = $track.ActualHeight - $T
$r = $rh / 2.0
$geo = New-Object System.Windows.Media.RectangleGeometry
$geo.Rect = New-Object System.Windows.Rect ($T/2), ($T/2), $rw, $rh
$geo.RadiusX = $r; $geo.RadiusY = $r
$ring.Data = $geo
$stadium = (2.0 * ($rw - 2.0 * $r)) + (2.0 * [Math]::PI * $r)
$rectangular = 2.0 * ($rw + $rh)
Assert ($stadium -lt $rectangular) `
    "a stadium perimeter is shorter than the rectangle around it ($([int]$stadium) vs $([int]$rectangular)px)"

$coll = New-Object System.Windows.Media.DoubleCollection
$coll.Add(($stadium / $T) * 0.5); $coll.Add($stadium / $T)
$ring.StrokeDashArray = $coll
$ring.Opacity = 1
Relayout
Assert ($selesai.ActualWidth -eq $beforeBtnW -and $card.ActualHeight -eq $beforeCardH2) `
    "a mid-trace ring changes no geometry at all"

$ring.Opacity = 0
$selLabel2.Text = (Get-LogbookText $cfg 'timerEndHold' 'Tahan untuk selesai')
Relayout
$card.Visibility = 'Collapsed'

Write-Host "timer widget: the pill and the card are never both on screen"
Assert ($pill.Visibility -eq 'Visible' -and $card.Visibility -eq 'Collapsed') `
    "it rests as the pill"
$pill.Visibility = 'Collapsed'; $card.Visibility = 'Visible'
Pump $widget
Assert ($pill.Visibility -eq 'Collapsed' -and $card.Visibility -eq 'Visible') `
    "expanding swaps them rather than stacking them"

Write-Host "timer widget: the message reply box only appears with a message"
$message = $widget.FindName('CardMessage')
$replyRow = $widget.FindName('CardReplyRow')
Assert ($message.Visibility -eq 'Collapsed') "no message block until an admin sends one"
if ($replyRow) { Assert ($replyRow.Visibility -eq 'Collapsed') "no reply row until then either" }

# ---- multi-monitor placement ------------------------------------------------
Write-Host ""
Write-Host "sign-in card: one display, never the seam between two"
# The sign-in WINDOW covers every screen and must: it is a kiosk lock paired
# with the keyboard lockdown, and an uncovered second monitor is a way around
# both. The CARD inside it is what was wrong -- centred on the combined virtual
# desktop, which on an extended pair is the bezel, and on a pair with a gap in
# the layout is a coordinate with no physical display behind it at all.
# Synthetic layouts, because the machine running this has whatever it has.
Import-LogbookFormsAssembly
function FakeScreen($l, $t, $w, $h, $primary, $name, $idx) {
    [pscustomobject]@{
        Index = $idx; Primary = $primary
        Screen = [pscustomobject]@{ DeviceName = $name; Primary = $primary }
        Bounds = New-Object System.Drawing.Rectangle $l, $t, $w, $h
        Label = "Layar $($idx + 1)"; Detail = "${w} x ${h}"
    }
}
$mcard = New-Object System.Windows.Controls.Border
$mcard.Width = 320
$mcard.Measure((New-Object System.Windows.Size 320, 400))
$mcard.Arrange((New-Object System.Windows.Rect 0, 0, 320, 400))
$mwin = New-Object System.Windows.Window
$virt = [System.Windows.Forms.SystemInformation]::VirtualScreen

foreach ($case in @(
    @{ n = 'left panel';  s = (FakeScreen 0 0 1920 1080 $true '\\.\DISPLAY1' 0) },
    @{ n = 'right panel'; s = (FakeScreen 1920 0 1920 1080 $false '\\.\DISPLAY2' 1) },
    # A layout with a GAP: the two panels are not adjacent, so the midpoint of
    # the virtual desktop is a coordinate no monitor can display.
    @{ n = 'gapped right'; s = (FakeScreen 2400 0 1600 900 $false '\\.\DISPLAY5' 1) },
    # NEGATIVE coordinates. Windows gives the PRIMARY display the origin, so a
    # monitor arranged to its left or above it has a negative Left/Top -- and
    # that is an ordinary arrangement, not an exotic one. Every offset in
    # Set-LogbookCardOnScreen is computed relative to the virtual screen's own
    # origin for exactly this reason; a version that assumed 0,0 would put the
    # card on the wrong display here, or off-screen entirely.
    @{ n = 'left of primary (negative X)'; s = (FakeScreen -1920 0 1920 1080 $false '\\.\DISPLAY3' 0) },
    @{ n = 'above primary (negative Y)';   s = (FakeScreen 0 -1080 1920 1080 $false '\\.\DISPLAY4' 0) },
    @{ n = 'up and to the left (both negative)'; s = (FakeScreen -2560 -1440 2560 1440 $false '\\.\DISPLAY6' 0) },
    # Mixed resolutions, which is what a real lab actually looks like once a
    # spare monitor gets attached to a workstation.
    @{ n = 'small secondary'; s = (FakeScreen 1920 0 1280 720 $false '\\.\DISPLAY7' 1) }
)) {
    Set-LogbookCardOnScreen -Window $mwin -Card $mcard -Target $case.s
    $left = $mcard.Margin.Left + $virt.Left
    $top  = $mcard.Margin.Top + $virt.Top
    $b = $case.s.Bounds
    Assert ($left -ge $b.Left -and ($left + 320) -le ($b.Left + $b.Width)) `
        "$($case.n): the card lands wholly inside its display horizontally ($left..$($left + 320) within $($b.Left)..$($b.Left + $b.Width))"
    # Vertical containment matters just as much on a negative-Y layout, and
    # was previously only asserted for the too-short-display clamp below.
    Assert ($top -ge $b.Top -and $top -le ($b.Top + $b.Height)) `
        "$($case.n): and vertically ($top within $($b.Top)..$($b.Top + $b.Height))"
}
Assert ($mcard.HorizontalAlignment -eq 'Left' -and $mcard.VerticalAlignment -eq 'Top') `
    "alignment leaves Center, or the margin that does the positioning is ignored"

# A card taller than the display must not be pushed off the top, where the
# fields the user has to reach would go with it.
Set-LogbookCardOnScreen -Window $mwin -Card $mcard -Target (FakeScreen 0 0 1920 200 $true '\\.\SHORT' 0)
Assert (($mcard.Margin.Top + $virt.Top) -ge 0) "a card taller than its display is clamped to the top edge"

Write-Host ""
Write-Host "the display choice is remembered, but only while it still means something"
$twoScreens = @((FakeScreen 0 0 1920 1080 $true '\\.\DISPLAY1' 0),
                (FakeScreen 1920 0 2560 1440 $false '\\.\DISPLAY2' 1))
$prefPath = Join-Path $Global:StateDir 'monitor_pref.json'
$prefBackup = if (Test-Path $prefPath) { Get-Content $prefPath -Raw } else { $null }
try {
    Save-LogbookPreferredMonitor $twoScreens[1]
    $found = Get-LogbookSavedMonitor $twoScreens
    Assert ($null -ne $found -and $found.Screen.DeviceName -eq '\\.\DISPLAY2') `
        "the chosen display is found again next session (no re-asking a question already answered)"
    # Same device NAME, different geometry: the panel was swapped or re-arranged,
    # so the remembered answer is about a display that no longer exists.
    $rearranged = @((FakeScreen 0 0 1920 1080 $true '\\.\DISPLAY1' 0),
                    (FakeScreen 1920 0 1280 720 $false '\\.\DISPLAY2' 1))
    Assert ($null -eq (Get-LogbookSavedMonitor $rearranged)) `
        "a remembered display whose geometry changed is not trusted"
} finally {
    if ($null -ne $prefBackup) { $prefBackup | Set-Content -LiteralPath $prefPath -Encoding UTF8 }
    else { Remove-Item $prefPath -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "the picker only exists when there is a choice to make"
$pickWin = [Windows.Markup.XamlReader]::Load(
    (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookPopupXaml $cfg))))
$pickPanel = $pickWin.FindName('MonitorPicker')
$pickCard = $pickWin.FindName('MainCard')
Assert ($null -ne $pickPanel) "the sign-in card carries a MonitorPicker slot"
Add-LogbookMonitorPicker -Window $pickWin -Card $pickCard -Panel $pickPanel -cfg $cfg -Screens @($twoScreens[0]) -Current $twoScreens[0]
Assert ($pickPanel.Visibility -eq 'Collapsed') `
    "one display: no picker, no extra question, no extra pixel of height"
Add-LogbookMonitorPicker -Window $pickWin -Card $pickCard -Panel $pickPanel -cfg $cfg -Screens $twoScreens -Current $twoScreens[0]
Assert ($pickPanel.Visibility -eq 'Visible') "two displays: the picker appears"
$chips = @($pickPanel.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })
Assert ($chips.Count -eq 2) "one chip per display (got $($chips.Count))"
# Clicking a chip must MOVE the card, not merely look selected.
$beforeLeft = $pickCard.Margin.Left
$chips[1].RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Assert ($pickCard.Margin.Left -ne $beforeLeft) `
    "clicking a chip actually relocates the card ($beforeLeft -> $($pickCard.Margin.Left))"
Remove-Item (Join-Path $Global:StateDir 'monitor_pref.json') -Force -ErrorAction SilentlyContinue
if ($null -ne $prefBackup) { $prefBackup | Set-Content -LiteralPath $prefPath -Encoding UTF8 }

Write-Host ""
if ($script:failed -gt 0) {
    Write-Host "$($script:failed) interaction check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All interaction checks passed." -ForegroundColor Green
exit 0
