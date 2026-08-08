# Proves the timer widget does not steal clicks meant for the window beneath it.
#
# This is a LIVE test, not a source grep. It builds the real timer XAML, shows
# the real window, installs the real Register-LogbookClickThrough, then drives
# the poll with synthetic cursor positions and reads back the window's actual
# WS_EX_TRANSPARENT bit via GetWindowLongPtr. When that bit is set every click
# falls through to whatever is underneath; when it is clear the widget takes it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\test_logbook_clickthrough.ps1
#
# Synthetic points rather than SetCursorPos, so running the suite does not
# yank the mouse out from under whoever is running it. The window is
# borderless, never activated, and closed again immediately; no session, no
# config and no state file is touched.
#
# This test exists because the first attempt at click-through -- an
# HwndSourceHook answering WM_NCHITTEST with HTTRANSPARENT -- was silently
# inert. A PowerShell scriptblock converted to a delegate cannot write to a
# `ref bool handled` parameter, so WPF ignored the hook entirely. Source
# inspection said it was fine. Only asking the live window caught it.
param([switch]$STAChild)
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -STAChild
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
. (Join-Path $PSScriptRoot 'logbook_common.ps1')

$script:failed = 0
function Assert($cond, $label) {
    if ($cond) { Write-Host "  ok: $label" }
    else { Write-Host "  FAIL: $label" -ForegroundColor Red; $script:failed++ }
}

# ---- build the real widget --------------------------------------------------
$cfg = Get-LogbookConfig
$session = @{ nama = 'Mahasiswa Uji'; nim = '000000'; keperluan = 'Uji klik-tembus'
              akses = 'Fisik'; started = (Get-Date).ToString('o') }
$xaml = Build-LogbookTimerXaml -cfg $cfg -session $session -deviceName 'WS-01 - Uji'
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))

$pillView   = $window.FindName('PillView')
$cardView   = $window.FindName('CardView')
$sliverView = $window.FindName('SliverView')

# Mirror the controller's state so -GetSurface resolves the same way it does live.
$script:cardOpen   = $false
$script:sliverOpen = $false
$script:posture    = 'pill'
$script:entered    = 0
$script:left       = 0

$window.ShowActivated = $false
$window.Show()

function Sync-Layout {
    # ActualWidth stays 0 until WPF has laid the tree out.
    $window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ContextIdle)
}
Sync-Layout

$hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
$surface = {
    if ($script:cardOpen)               { $cardView }
    elseif ($script:posture -eq 'pill') { $pillView }
    elseif ($script:sliverOpen)         { $sliverView }
    else                                { $null }
}
$timer = Register-LogbookClickThrough -Window $window -GetSurface $surface `
    -OnPointerEnter { $script:entered++ } -OnPointerLeave { $script:left++ }
# Nothing here needs the wall clock; the test drives the same logic by hand.
$timer.Stop()

# One poll iteration, with the cursor asserted to be at (x,y).
function Poll($x, $y) {
    $rect = Get-LogbookSurfaceRect (& $surface)
    $through = Test-LogbookClickThrough -Rect $rect -X $x -Y $y -Grace 3
    [LogixClickThrough]::Set($hwnd, $through)
    return $through
}
# The question that actually matters: would a click at (x,y) reach the app below?
function Passes-Through($x, $y) {
    [void](Poll $x $y)
    return [LogixClickThrough]::IsOn($hwnd)
}

try {
    Write-Host "startup"
    Assert ([LogixClickThrough]::IsOn($hwnd)) `
        "widget is click-through the instant it appears (before any poll runs)"

    Write-Host "pill posture -- the widget's own surface"
    $p = Get-LogbookSurfaceRect $pillView
    $cx = [int](($p.L + $p.R) / 2); $cy = [int](($p.T + $p.B) / 2)
    Assert (-not (Passes-Through $cx $cy))            "centre of the pill takes clicks (hover-to-expand still works)"
    Assert (-not (Passes-Through ($p.L + 2) ($p.T + 2))) "top-left corner of the pill takes clicks"
    Assert (-not (Passes-Through ($p.R - 2) ($p.B - 2))) "bottom-right corner of the pill takes clicks"

    Write-Host "pill posture -- the shadow bleed that used to eat tab clicks"
    Assert (Passes-Through ($p.L - 20) $cy)  "20px LEFT of the pill passes through"
    Assert (Passes-Through ($p.R + 20) $cy)  "20px RIGHT of the pill passes through"
    Assert (Passes-Through $cx ($p.B + 20))  "the shadow gutter BELOW the pill passes through"

    Write-Host "the 3px grace ring -- a small target must stay easy to hit"
    Assert (-not (Passes-Through ($p.L - 2) $cy)) "2px outside still counts as the pill"
    Assert (Passes-Through ($p.L - 8) $cy)        "8px outside does not"

    # The whole point of the change: how much of the user's title bar was dead.
    $wr = Get-LogbookSurfaceRect $window.Content
    $pillW = [int]($p.R - $p.L)
    Write-Host ("  window {0}x{1}, pill {2}x{3} -- {4}px of dead margin reclaimed" -f `
        [int]$window.ActualWidth, [int]$window.ActualHeight, $pillW, [int]($p.B - $p.T),
        ([int]$window.ActualWidth - $pillW))
    Assert ($pillW -lt 120) "pill is far narrower than the old fixed 150px box (got ${pillW}px)"
    Assert ($window.ActualWidth -gt $pillW) "there IS dead margin, so click-through is load-bearing not cosmetic"

    Write-Host "enter / leave callbacks (the poll, not WPF, drives expand)"
    $script:entered = 0; $script:left = 0
    $tick = { param($x, $y)
        $through = Poll $x $y
        $over = -not $through
        if ($over -ne $timerOver) { $script:timerOver = $over
            if ($over) { $script:entered++ } else { $script:left++ } } }
    $script:timerOver = $false
    & $tick ($p.L - 40) $cy;  & $tick $cx $cy;  & $tick ($p.L - 40) $cy
    Assert ($script:entered -eq 1) "arriving on the pill fires exactly one enter"
    Assert ($script:left -eq 1)    "leaving fires exactly one leave"

    Write-Host "expanded card -- the bigger surface claims its own clicks"
    $script:cardOpen = $true
    $pillView.Visibility = 'Collapsed'
    $cardView.Visibility = 'Visible'
    Sync-Layout
    $c = Get-LogbookSurfaceRect $cardView
    Assert (-not (Passes-Through ([int](($c.L + $c.R) / 2)) ([int](($c.T + $c.B) / 2)))) `
        "centre of the open card takes clicks (buttons and the reply box work)"
    Assert (Passes-Through ($c.L - 20) ([int](($c.T + $c.B) / 2))) "beside the card still passes through"
    Assert (($c.R - $c.L) -gt $pillW) "the hit area grew with the card instead of staying pill-sized"

    Write-Host "strip posture -- a 3px line must be almost entirely click-through"
    $script:cardOpen = $false
    $script:posture  = 'strip'
    $cardView.Visibility = 'Collapsed'
    Sync-Layout
    Assert (Passes-Through $cx $cy) "with nothing peeked, the whole widget window passes clicks through"

    $script:sliverOpen = $true
    $sliverView.Visibility = 'Visible'
    Sync-Layout
    $s = Get-LogbookSurfaceRect $sliverView
    Assert (-not (Passes-Through ([int](($s.L + $s.R) / 2)) ([int](($s.T + $s.B) / 2)))) `
        "the peeked sliver takes clicks so it can be expanded"

    Write-Host "other ex-styles must survive the toggling"
    # WS_EX_TOOLWINDOW (0x80) is applied by the controller; losing it would put
    # the widget back into Alt-Tab. Read-modify-write, not a blind overwrite.
    [LogixClickThrough]::Set($hwnd, $false)
    $window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ContextIdle)
    Assert (-not [LogixClickThrough]::IsOn($hwnd)) "clearing the bit actually clears it"
    [LogixClickThrough]::Set($hwnd, $true)
    Assert ([LogixClickThrough]::IsOn($hwnd)) "setting it again actually sets it"
}
finally {
    try { $timer.Stop() } catch { }
    $window.Close()
}

Write-Host ""
if ($script:failed -gt 0) {
    Write-Host "$($script:failed) click-through check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All click-through checks passed." -ForegroundColor Green
exit 0
