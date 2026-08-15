# Non-interactive checks for the popup customization layer (no WPF/GUI needed).
# Validates config defaults, cascading deep-merge, XML escaping, and that the
# generated XAML is well-formed. Exits non-zero on any failure (for CI).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'logbook_common.ps1')

$fail = 0
function Assert($cond, $msg) {
    if ($cond) { Write-Host "  ok: $msg" }
    else { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:fail++ }
}

Write-Host "default config -> XAML"
$cfg = Get-LogbookDefaultConfig
$xaml = Build-LogbookPopupXaml $cfg
$doc = [xml]$xaml
# v3: the fullscreen window is now a translucent scrim over the lock screen and
# the dialog itself is a 320px card, rather than the window being the surface.
Assert ($doc.Window.Background -eq '#D8070C15') "fullscreen popup is a dimmed scrim, not an opaque surface (v3 section 6)"
$mainCard = $doc.SelectNodes("//*[local-name()='Border']") | Where-Object { $_.Name -eq 'MainCard' }
Assert ($mainCard.Width -eq '320') "sign-in dialog is 320px wide"
Assert ($mainCard.CornerRadius -eq '22') "sign-in dialog uses radius 22, matching the pill language"
$logo = ($doc.SelectNodes("//*[local-name()='TextBlock']") | Where-Object { $_.Name -eq 'LogoText' }).Text
Assert ($logo -eq 'Logix') "default logo text Logix"
$items = $doc.SelectNodes("//*[local-name()='ComboBoxItem']")
Assert ($items.Count -eq 6) "2 access + 3 purpose + the 'Lainnya' free-text escape = 6 combo items"
$accessBox = $doc.SelectNodes("//*[local-name()='ComboBox']") | Where-Object { $_.Name -eq 'AccessBox' }
Assert ($accessBox.IsEnabled -eq 'False') "access type is auto-detected and read-only, never a user choice"
$nimBox = $doc.SelectNodes("//*[local-name()='TextBox']") | Where-Object { $_.Name -eq 'NimBox' }
Assert ($nimBox.FontFamily -eq 'Consolas') "NIM input is mono"
Assert ($xaml -match 'Tanpa perekaman layar' -or $xaml -match 'StartTimeText') "privacy line is always visible, not behind a link"

Write-Host "partial override -> deep-merge keeps sibling defaults"
$tmp = Join-Path $env:TEMP ("logix_cfgtest_" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".json")
@'
{ "branding": { "logoText": "CHEM & BIO", "colors": { "accent": "#1A7F4B" } },
  "purposes": ["Simulation","Training","Maintenance","Other"],
  "requiredFields": ["nama","keterangan"] }
'@ | Out-File -FilePath $tmp -Encoding UTF8
try {
    $merged = Merge-LogbookConfig (Get-LogbookDefaultConfig) (Read-LogbookConfigFile $tmp)
    Assert ($merged.branding.colors.accent -eq '#1A7F4B') "accent overridden"
    Assert ($merged.branding.colors.primary -eq '#0E1626') "primary kept from defaults"
    Assert ($merged.branding.title -eq 'Report Logbook') "title kept from defaults"
    Assert (@($merged.purposes).Count -eq 4) "purposes array replaced (4)"
    Assert (@($merged.requiredFields) -join ',' -eq 'nama,keterangan') "requiredFields replaced"

    $doc2 = [xml](Build-LogbookPopupXaml $merged)   # must still be valid XML
    $logo2 = ($doc2.SelectNodes("//*[local-name()='TextBlock']") | Where-Object { $_.Name -eq 'LogoText' }).Text
    Assert ($logo2 -eq 'CHEM & BIO') "ampersand in logo text escaped and round-trips"
    $purpose2 = $doc2.SelectNodes("//*[local-name()='ComboBox'][@Name='TujuanBox']/*")
    Assert ($purpose2.Count -eq 5) "4 configured purposes + the 'Lainnya' free-text escape hatch"
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host "v3 client token ResourceDictionary"
$res = Build-LogbookClientResources $cfg
# Wrap the fragment so it can be parsed on its own.
$resDoc = [xml]("<ResourceDictionary xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" xmlns:x=`"http://schemas.microsoft.com/winfx/2006/xaml`">$res</ResourceDictionary>")
$brushKeys = @($resDoc.SelectNodes("//*[local-name()='SolidColorBrush']") | ForEach-Object { $_.Key })
foreach ($k in @('LxSurface','LxElevated','LxHairline','LxText','LxMuted','LxAccent','LxActive','LxNotice','LxWarning','LxCritical')) {
    Assert ($brushKeys -contains $k) "resource dictionary defines $k"
}
Assert ($res -notmatch 'GradientBrush') "no gradient brush in the client token set (v3 guard rail)"

# The quiet half of the critical signal. #EF4444 at full strength is a correct
# alert colour and a wrong surface colour: on a card of deep navy, slate and a
# green dot, a control that floods solid red on press reads as belonging to a
# different application. These are DERIVED from the configured signal so a
# faculty rebrand carries them along instead of stranding three literals.
foreach ($k in @('LxCriticalWash','LxCriticalEdge','LxCriticalSoft')) {
    Assert ($brushKeys -contains $k) "resource dictionary defines $k"
}
$theme = Get-LogbookTheme $cfg
Assert ($theme.criticalWash -ne $theme.signalCritical) "the wash is not simply the raw signal colour"
# A wash has to sit nearer its surface than its signal, or it is a flood with
# a gentler name. Compared on luminance, which is what the eye actually reads.
$lum = {
    param($hex)
    $h = $hex.TrimStart('#')
    (0.2126 * [Convert]::ToInt32($h.Substring(0,2),16) +
     0.7152 * [Convert]::ToInt32($h.Substring(2,2),16) +
     0.0722 * [Convert]::ToInt32($h.Substring(4,2),16))
}
$lSurface  = & $lum $theme.surfaceWidget
$lWash     = & $lum $theme.criticalWash
$lCritical = & $lum $theme.signalCritical
Assert (([Math]::Abs($lWash - $lSurface)) -lt ([Math]::Abs($lWash - $lCritical))) `
    "the wash reads as the surface tinted, not as the signal dimmed"
# The swept label sits on that wash, so it has to be lifted off the signal.
Assert ((& $lum $theme.criticalSoft) -gt $lCritical) "the swept label colour is lighter than the raw signal, for contrast on the wash"
Assert ((Get-LogbookMixedHex '#000000' '#FFFFFF' 0.5) -eq '#808080') "the mixer is a plain linear blend"
Assert ((Get-LogbookMixedHex '#0B1017' '#EF4444' 0.0) -eq '#0B1017') "mixing nothing in returns the base untouched"
Assert ((Get-LogbookMixedHex 'nonsense' '#EF4444' 0.5) -eq 'nonsense') "a malformed override degrades to the base instead of throwing"

Write-Host "session timer -> XAML (v3 Pill & Strip)"
$session = [pscustomobject]@{ session_type = 'SSH'; nama = 'Nama & "Contoh"'; tujuan = 'Running Data' }
$timerXaml = Build-LogbookTimerXaml -cfg $cfg -session $session -deviceName 'LAB-PC-01 <Test> - GPU-A100'
$timerDoc = [xml]$timerXaml

$tb = { param($n) $timerDoc.SelectNodes("//*[local-name()='TextBlock']") | Where-Object { $_.Name -eq $n } }
$bd = { param($n) $timerDoc.SelectNodes("//*[local-name()='Border']") | Where-Object { $_.Name -eq $n } }

Assert ($timerDoc.Window.SizeToContent -eq 'WidthAndHeight') "widget sizes to content (no chamfered Path geometry to keep in sync any more)"
Assert ($timerDoc.Window.ShowInTaskbar -eq 'False') "widget stays out of the taskbar (WS_EX_TOOLWINDOW is applied at runtime too)"

$pill = & $bd 'PillView'
# The design's fixed 150x32 was walked back: the pill lives on top of whatever
# window owns the top edge (a browser tab strip, in the report that prompted
# this), so it hugs its content instead of reserving a box of mostly padding.
Assert ($null -eq $pill.Width) "pill is auto-width -- it never reserves more of the title bar than it needs"
Assert ($pill.Height -eq '26') "pill is 26px tall (trimmed from the design's 32)"
Assert ($pill.Padding -eq '11,0') "pill breathes via padding, which is what lets it auto-size"
Assert ($pill.CornerRadius -eq '13') "pill is fully rounded (half its height)"
# At rest it must be see-through: the user has to be able to read the tab
# underneath it. Anything at/above 0.9 is the bug this guards against.
Assert ([double]$pill.Opacity -ge 0.5 -and [double]$pill.Opacity -le 0.8) "pill rests semi-transparent so the window beneath stays readable"
$card = & $bd 'CardView'
Assert ($card.Width -eq '240') "expand card is 240px wide (design D-02 state 02)"
Assert ($card.CornerRadius -eq '22') "expand card uses radius 22"
Assert ($card.Visibility -eq 'Collapsed') "card starts collapsed -- the pill is the resting posture"
$sliver = & $bd 'SliverView'
Assert ($sliver.Height -eq '24') "sliver is 24px tall (design D-02 state 06)"
Assert ($sliver.Visibility -eq 'Collapsed') "sliver starts retracted"

# The station ID must survive the split: "LAB-PC-01" contains hyphens itself,
# so only a SPACED separator divides the ID from the spec.
$station = (& $tb 'CardStation').Text
Assert ($station -eq 'LAB-PC-01 <Test>') "station ID keeps its internal hyphens (split only on a spaced separator)"
$deviceValue = (& $tb 'DeviceValue').Text
Assert ($deviceValue -like 'GPU-A100*SSH') "Perangkat row shows spec + access type, not the whole display name"
$namaValue = (& $tb 'NamaValue').Text
Assert ($namaValue -eq 'Nama & "Contoh"') "nama with ampersand/quote escaped and round-trips"

$clock = & $tb 'PillClock'
Assert ($clock.Text -eq '00:00') "pill clock starts at 00:00"
Assert ((& $tb 'CardClock').Text -eq '00:00:00') "card clock carries seconds"

Assert ((& $bd 'PillBadge').Visibility -eq 'Collapsed') "unread badge hidden until a message arrives"
$cardMsg = $timerDoc.SelectNodes("//*[local-name()='StackPanel']") | Where-Object { $_.Name -eq 'CardMessage' }
Assert ($cardMsg.Visibility -eq 'Collapsed') "message block collapsed by default (never auto-expands)"
# Hidden, not Collapsed, and carrying its final text from the start: revealing
# it must not change the card's height. When it was Collapsed with empty text,
# showing it on mouse-down grew the card, slid SELESAI out from under the
# cursor and cancelled the hold ~110ms in -- the press looked like it did
# nothing, which is exactly the bug this control was meant to fix.
$armedCapNode = & $tb 'ArmedCaption'
Assert ($armedCapNode.Visibility -eq 'Hidden') "hold hint reserves its space (Hidden, never Collapsed)"
Assert (-not [string]::IsNullOrWhiteSpace($armedCapNode.Text)) "hold hint carries its text from the first layout, so revealing it cannot resize the card"
$selesaiFill = $timerDoc.SelectNodes("//*[local-name()='Border']") | Where-Object { $_.Name -eq 'SelesaiFill' }
Assert ($selesaiFill.Width -eq '0') "the hold fill starts empty -- SELESAI reads as untouched until pressed"

Write-Host "v3 anti-pattern guard rails (client)"
Assert ($timerXaml -notmatch 'GradientBrush') "no gradient anywhere in the timer widget"
Assert ($timerXaml -notmatch 'Name="Pulse"') "no pulsing element -- the status dot is static"
$mono = $timerDoc.SelectNodes("//*[local-name()='TextBlock'][@FontFamily='Consolas']")
Assert ($mono.Count -ge 4) "time / ID values render in Consolas (mono tabular)"

Write-Host "timer controller P/Invoke"
# The widget's Win32 helper is compiled at runtime by Add-Type, which treats
# warnings as errors. A sign-extended bitwise-or (CS0675) once made the whole
# type fail to build, so logbook_timer.ps1 died on launch -- with nothing
# written to logbook_error.log, because the failure happened before the
# try/catch. Compile it here so that can never ship again.
$timerSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'logbook_timer.ps1')
$pinvoke = [regex]::Match($timerSrc, '(?s)Add-Type @"(.*?)"@')
Assert ($pinvoke.Success) "timer controller still defines its Win32 helper inline"
if ($pinvoke.Success -and -not ([System.Management.Automation.PSTypeName]'LogixWin').Type) {
    $compiled = $true
    try { Add-Type -TypeDefinition $pinvoke.Groups[1].Value -ErrorAction Stop }
    catch { $compiled = $false; Write-Host "    compiler said: $($_.Exception.Message)" }
    Assert $compiled "LogixWin compiles cleanly under Add-Type (warnings are errors)"
}

Write-Host "click-through (widget must not eat clicks meant for the app below)"
# Behaviour is covered live in test_logbook_clickthrough.ps1, which shows the
# real window and reads back its real WS_EX_TRANSPARENT bit. These are only the
# wiring checks that file cannot make: that the controller opts in at all, and
# that it routes expand/collapse through the poll. The poll has to drive those
# because a click-through window receives no mouse messages, so WPF's own
# MouseEnter never fires while the pointer is approaching.
Assert ($timerSrc -match 'Register-LogbookClickThrough') "controller makes itself click-through"
Assert ($timerSrc -match '-OnPointerEnter') "expand is driven by the cursor poll, not only by WPF MouseEnter"
Assert ($timerSrc -match '-OnPointerLeave') "collapse is driven by the cursor poll too"
$commonSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'logbook_common.ps1')
Assert ($commonSrc -match 'PointToScreen') "the hit rectangle is measured off the live surface, not hard-coded"
# The mechanism must stay style-based. An HwndSourceHook answering WM_NCHITTEST
# reads correctly and does nothing: a PowerShell scriptblock cannot write to a
# delegate's `ref bool handled`, so WPF discards the result. Do not go back.
Assert ($commonSrc -notmatch 'HwndSourceHook') "click-through does not rely on a ref-parameter hook PowerShell cannot write to"

Write-Host "idle auto-end policy"
# Safety-critical: Get-LogbookIdleTimeoutSeconds returns 0 for a DISABLED
# category. A caller that compares "idle >= limit" without guarding limit > 0
# would then close every session on its first check. Assert the guard is
# present rather than trusting a comment.
$monitorSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'logbook_monitor.ps1')
Assert ($monitorSrc -match '\$limitSec -gt 0 -and \$idleSec -ge \$limitSec') "monitor treats a 0 idle limit as 'never', not 'close now'"
$commonSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'logbook_common.ps1')
Assert ($commonSrc -match 'if \(-not \$policy\.enabled\) \{ return 0 \}') "a disabled category resolves to 0 (never auto-end)"
$schema = Get-Content -Raw (Join-Path $PSScriptRoot '..\docs\config.schema.json') | ConvertFrom-Json
Assert ($null -ne $schema.properties.devices.properties.idle_auto_end) "config schema documents devices.idle_auto_end"
Assert ($null -ne $schema.properties.devices.properties.category) "config schema documents the device category the policy keys on"

Write-Host "strip posture -> XAML"
$stripDoc = [xml](Build-LogbookStripXaml $cfg)
Assert ($stripDoc.Window.Height -eq '3') "strip is a 3px line (design D-02 state 05)"
Assert ($null -ne ($stripDoc.SelectNodes("//*[local-name()='Border']") | Where-Object { $_.Name -eq 'StripBar' })) "strip exposes StripBar for status recolouring"

Write-Host "shared countdown / broadcast overlay -> XAML"
$ovDoc = [xml](Build-LogbookCountdownOverlayXaml $cfg)
$ovCard = $ovDoc.SelectNodes("//*[local-name()='Border']") | Where-Object { $_.Name -eq 'OverlayCard' }
Assert ($ovCard.Width -eq '360') "overlay card is 360px wide (design D-02 state 08)"
Assert ($ovCard.CornerRadius -eq '22') "overlay card uses radius 22, matching the expand card"
foreach ($n in @('CountNumber','OverlayTitle','OverlayBody','ExtendBtn','EndNowBtn','AckBtn')) {
    Assert ($ovDoc.InnerXml -match ('Name="' + $n + '"')) "overlay exposes $n (one component serves idle auto-end AND broadcast)"
}
$ovButtons = $ovDoc.SelectNodes("//*[local-name()='Button']")
Assert ($ovButtons.Count -eq 3) "overlay has exactly the three action buttons"
Assert ($ovDoc.InnerXml -match 'TextWrapping="NoWrap"' -or $res -match 'TextWrapping="NoWrap"') "overlay action labels never wrap"


Write-Host "installer config.env writer"
# Regression: Set-LogixConfigValue built its output with a bare foreach, which
# yields a single STRING when the file has 0 or 1 lines. The += that follows
# then concatenated text instead of appending a line, welding every key onto
# one line -- and the agent could no longer read its own LOGIX_SERVER_URL. It
# only bit on a genuinely fresh machine (empty config.env), which is exactly
# the case that matters, and it produced no error: the install "succeeded" and
# the device simply never talked to the server.
$installerSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'install_logbook_tasks.ps1')
$cfgFn = [regex]::Match($installerSrc, '(?s)function Set-LogixConfigValue \{.*?\n\}').Value
Assert ($cfgFn -ne '') "installer still defines Set-LogixConfigValue"

$probeDir = Join-Path $env:TEMP ('lxcfgtest_' + [guid]::NewGuid().ToString('N').Substring(0,8))
$cfgFn = [regex]::Replace($cfgFn, '\$cfgDir = .*', ('$cfgDir = ' + "'$probeDir'"))
Invoke-Expression $cfgFn
try {
    Set-LogixConfigValue -Key 'LOGIX_USE_WSL'        -Value '0'
    Set-LogixConfigValue -Key 'LOGIX_SERVER_URL'     -Value 'https://localhost'
    Set-LogixConfigValue -Key 'LOGIX_DEVICE_NAME'    -Value 'WS-01'
    Set-LogixConfigValue -Key 'LOGIX_SERVER_API_KEY' -Value ''
    Set-LogixConfigValue -Key 'LOGIX_SERVER_URL'     -Value 'https://logix.lab'

    $cfgLines = @(Get-Content (Join-Path $probeDir 'config.env'))
    Assert ($cfgLines.Count -eq 4) "four keys written from an empty config, one line each (got $($cfgLines.Count))"
    $dupes = @($cfgLines | Group-Object | Where-Object { $_.Count -gt 1 })
    Assert ($dupes.Count -eq 0) "no duplicated lines"
    Assert (@($cfgLines | Where-Object { $_ -eq 'LOGIX_SERVER_URL=https://logix.lab' }).Count -eq 1) "rewriting a key replaces it in place"
    Assert (-not (($cfgLines -join '') -match 'localhostLOGIX')) "keys are never welded onto one line"
} finally {
    if (Test-Path $probeDir) { [System.IO.Directory]::Delete($probeDir, $true) }
}

Write-Host "startup cost (this is the login path -- a person is waiting)"
# Add-Type shells out to csc.exe: ~370ms for the first type in a process, ~250ms
# each after. A helper compiled at FILE scope in logbook_common.ps1 charges that
# to every script that dot-sources it, including the sign-in popup, which uses
# neither of the P/Invoke helpers this file defines. That regression shipped
# once already and cost ~570ms per login. Compile on first use instead.
Assert ($commonSrc -notmatch '(?m)^\s*Add-Type\s+@"') `
    "logbook_common.ps1 compiles no C# at file scope (use Use-LogbookNativeType)"
Assert ($commonSrc -match 'function Use-LogbookNativeType') "the lazy-compile helper exists"
foreach ($t in @('LogixClickThrough', 'LogixIdle')) {
    Assert ($commonSrc -match "Use-LogbookNativeType -Name '$t'") "$t is compiled on first use"
}

# Measure it rather than trust the grep -- but measure the MARGINAL cost of
# the dot-source, not the wall time of the whole process.
#
# This used to time a single `powershell -Command ". common.ps1"` against a
# 900ms budget, most of which was powershell.exe's own startup. That makes
# the test a measurement of the MACHINE, not of this file: process creation
# here has been observed at ~250ms when the box is idle and ~670ms when it
# is not (Defender, memory pressure, an agent already running), which alone
# moves the number by more than the regression being guarded against. The
# test then fails for reasons no code change could fix, which is how a guard
# turns into noise people learn to ignore.
#
# Subtracting a bare `powershell -Command exit` isolates exactly what this
# is here to catch: a stray Add-Type at file scope charging every dot-source
# ~250-500ms of csc.exe. Best-of-3 on both halves, because a latency floor
# is the honest statistic for "how expensive is this at best" -- a single
# sample only ever measures the worst scheduling luck of that one run.
function Measure-BestOf3 {
    param([string[]]$PsArgs)
    $best = [int]::MaxValue
    foreach ($i in 1..3) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & powershell @PsArgs | Out-Null
        $sw.Stop()
        if ($sw.ElapsedMilliseconds -lt $best) { $best = [int]$sw.ElapsedMilliseconds }
    }
    return $best
}
$baselineMs = Measure-BestOf3 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'exit')
$loadedMs = Measure-BestOf3 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                              ". '$(Join-Path $PSScriptRoot 'logbook_common.ps1')'")
$dotSourceMs = $loadedMs - $baselineMs
Write-Host "  bare powershell: ${baselineMs}ms | + dot-source: ${loadedMs}ms | marginal: ${dotSourceMs}ms"
Assert ($dotSourceMs -lt 400) "dot-sourcing logbook_common.ps1 stays cheap (${dotSourceMs}ms marginal, budget 400ms)"

# The popup must not block on the network at login when a usable cache exists.
$popupSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'logbook_popup.ps1')
Assert ($popupSrc -match 'Get-LogbookConfig -MaxCacheAgeSeconds') `
    "the sign-in popup reads config cache-first"
Assert ($commonSrc -match '\[int\]\$MaxCacheAgeSeconds = 0') `
    "Get-LogbookConfig still defaults to always-fetch for callers that need current data"
# With no cache to fall back on the fetch is the only source of labels, so it
# keeps the longer timeout; with a cache it must not.
Assert ($commonSrc -match 'if \(\$null -ne \$cacheAge\) \{ 1 \} else \{ 2 \}') `
    "fetch timeout is shorter when a cache exists to fall back on"

Write-Host "hover intent (the pill lives where browser tabs live)"
# The pill is docked to the top edge, which is also the tab strip and the title
# bar -- the cursor crosses it on the way to something else constantly. Opening
# the card on contact turned a 72px obstacle into a 240px one at exactly the
# wrong moment. Expanding must require the pointer to REST; collapsing must not.
Assert ($timerSrc -match '\$script:HOVER_DWELL_MS\s*=\s*(\d+)') "expand is gated behind a dwell"
$dwellMs = [int]$Matches[1]
Write-Host "  dwell: ${dwellMs}ms"
Assert ($dwellMs -ge 200 -and $dwellMs -le 600) "the dwell is long enough to ignore a passing cursor, short enough to feel instant (${dwellMs}ms)"
Assert ($timerSrc -notmatch '-OnPointerEnter \{[^}]*Open-LogbookCard') `
    "the cursor poll starts the dwell rather than opening the card outright"
Assert (([regex]::Matches($timerSrc, '\$script:hoverDwell\.Stop\(\)')).Count -ge 2) `
    "every leave path cancels the dwell, so a crossed pointer never opens the card late"
# The asymmetry is deliberate and worth pinning: slow to open, instant to close.
Assert ($timerSrc -match 'Close-LogbookCard\s*\}') "collapse stays immediate"

Write-Host "status bar bridge (YASB)"
# The floating pill is an overlay, so it always covers something; a bar
# RESERVES its space and covers nothing. The widget publishes to a file the bar
# reads, rather than the bar spawning a PowerShell process every second.
Assert ($commonSrc -match 'function Write-LogbookBarStatus') "the widget can publish its state for a bar"
Assert ($timerSrc -match 'Write-LogbookBarStatus') "the 1s tick is what publishes it (no second poller)"
Assert ($timerSrc -match 'Clear-LogbookBarStatus') "the slot is cleared when the session ends"
# A partially written file read mid-poll renders as a blank slot.
Assert ($commonSrc -match 'Move-Item -LiteralPath \$tmp') "the status file is swapped in atomically, never written in place"
# A request that survived being read would re-fire every single tick.
Assert ($commonSrc -match 'Remove-Item \$path -Force') "a bar action is consumed on read"

# ---- how fast a bar CLICK turns into a card ---------------------------------
# Reported as "logix is unresponsive in YASB". It was not one slow thing, it
# was two waits stacked on a gesture that has to feel direct: the request took
# ~586ms to even be made, then sat on disk for up to another second before the
# widget looked. Both are pinned here because both are easy to reintroduce by
# accident -- one by adding a convenience dot-source, one by folding the poll
# back into the tick that already exists.
Assert ($timerSrc -match '\$script:barPollTimer\.Interval\s*=\s*\[TimeSpan\]::FromMilliseconds\(\$script:BAR_POLL_MS\)') `
    "bar requests get their own timer, not a ride on the one-second clock"
Assert ($timerSrc -match '\$script:BAR_POLL_MS\s*=\s*(\d+)') "the poll cadence is a named constant"
$barPollMs = [int]$Matches[1]
Assert ($barPollMs -le 200) "a click is picked up inside the window that still reads as direct (${barPollMs}ms)"
Assert ($timerSrc -match '\$script:barPollTimer\.Start\(\)') "the poll is actually started"
Assert ($timerSrc -match '\$script:barPollTimer\.Stop\(\)') "and stopped, so it cannot re-open a card during teardown"
$tickBody = [regex]::Match($timerSrc, '\$timer\.Add_Tick\(\{(?s).*?\n\}\)').Value
Assert ($tickBody -notmatch 'Read-LogbookBarAction') `
    "the one-second tick no longer owns bar requests (that was up to 1s of the lag)"
Assert ($timerSrc -match "\`$p\.posture -in @\('pill','strip','bar'\)") "'bar' is a real posture the widget persists"
# bar posture must draw nothing at all, or the user gets two timers.
Assert ($timerSrc -match "showPill\s+= \(-not \`$showCard\) -and \(\`$script:posture -eq 'pill'\)") `
    "the floating pill only draws in pill posture"
Assert ($timerSrc -match "stripWindow\.Visibility = if \(\`$script:posture -eq 'strip'\)") `
    "the strip line only draws in strip posture"

$yasbSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'logix_yasb.ps1')
Assert ($yasbSrc -notmatch 'run_cmd: "') "no double-quoted YAML scalar carries a path"
Assert ($yasbSrc -match "type: 'yasb\.custom\.CustomWidget'") "targets the widget class YASB actually ships"

# run_cmd itself has NO quotes and NO "cmd /c" prefix. This is not a style
# choice -- it is load-bearing. YASB's CustomWorker builds its subprocess
# argv via run_cmd.split(" "), a plain space split with zero awareness of
# quoting, then runs it with shell=True (which already wraps everything in
# its own cmd.exe layer). "cmd /c type \"path\"" split that way, re-quoted by
# Python's list2cmdline, and re-parsed by a SECOND, nested cmd.exe never
# survives intact -- the widget silently rendered the raw "{data[text]}"
# template forever, with no error anywhere. This was live and reproduced on
# this machine, not a guess from reading the source.
Assert ($yasbSrc -notmatch "run_cmd: 'cmd /c") "run_cmd does not add a second, redundant shell layer"
Assert ($yasbSrc -match "run_cmd: 'type \`$statusFile'") "run_cmd is the bare 'type <path>', unquoted"

# Live reproduction of YASB's own exec path -- split(" "), Popen(list,
# shell=True, encoding=None), json.loads(output) -- using the actual
# CustomWorker.run() logic. Confirms the fix works rather than trusting that
# it merely LOOKS unquoted. Skips gracefully if this box has no python.
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    Ensure-LogbookDirs
    Write-LogbookBarStatus -Text '00:00' -Alt 'probe' -Tooltip 'probe' -State 'active'
    $probePath = Get-LogbookStatusFile
    $probe = @"
import subprocess, json, sys
cmd = r'type $probePath'.split(' ')
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         creationflags=subprocess.CREATE_NO_WINDOW, shell=True, encoding=None)
data = json.loads(proc.stdout.read())
assert isinstance(data, dict) and 'text' in data, data
print('OK')
"@
    # Avoid 2>&1 here: $ErrorActionPreference = 'Stop' (top of this file) turns
    # ANY merged stderr line from a native command into a terminating
    # exception in PS 5.1, even from a process that exits 0 -- this is not
    # hypothetical, it took the whole test script down while writing this one.
    $result = ($probe | & $python.Source - 2>$null)
    Assert ($LASTEXITCODE -eq 0 -and "$result" -match 'OK') `
        "run_cmd survives YASB's actual split(shell=True) exec path (got: $result)"
} else {
    Write-Host "  (skipped: no python on PATH to reproduce YASB's exec path)"
}
# The icon is the literal backslash-u-f-0-1-7 escape TEXT, inside a
# DOUBLE-quoted YAML scalar -- matching how config.yaml's own wifi_icons
# already encode their glyphs -- so PowerShell (no \u string escape of its
# own) passes it through unchanged and the source file stays ASCII. A raw
# [char]0xF017 embedded directly would also be valid YAML, but it is a UTF-8
# byte sequence, which is exactly the non-ASCII windows/*.ps1 must never carry.
Assert ($yasbSrc -match '"<span>\\uf017</span>') "the icon is a YAML unicode escape in a double-quoted scalar, not a raw byte"
Assert ($yasbSrc -notmatch '\[char\]0xF017') "no raw Unicode char object -- the ASCII-safe escape text is emitted directly"

# The click path must be served before logbook_common.ps1 is loaded. Parsing
# 140KB+ of PowerShell to write four bytes was ~350ms of the 586ms a click
# spent before the widget had even been told to do anything.
$yasbActionIdx = $yasbSrc.IndexOf("if (`$PSCmdlet.ParameterSetName -eq 'Action')")
$yasbSourceIdx = $yasbSrc.IndexOf(". (Join-Path `$PSScriptRoot 'logbook_common.ps1')")
Assert ($yasbActionIdx -ge 0 -and $yasbSourceIdx -ge 0) "the callback branch and the dot-source are both present"
Assert ($yasbActionIdx -lt $yasbSourceIdx) `
    "the click callback is answered BEFORE logbook_common.ps1 is dot-sourced"
Assert ($yasbSrc -match "Join-Path \`$env:ProgramData 'MindLabLogbook'") `
    "the fast path derives the state dir the same way logbook_common.ps1 does"
# At a 100ms poll a reader really does arrive between create and write.
Assert ($yasbSrc -match 'Move-Item -LiteralPath \$tmp') "the request is renamed into place, never written in place"
Assert ($commonSrc -match '(?s)function Request-LogbookBarAction.*?Move-Item -LiteralPath \$tmp') `
    "the canonical writer is atomic too"
# Measured, not assumed: this is the number the complaint was actually about.
# Best of three, and a threshold well clear of the pass/fail line. This measures
# a process launch on a shared machine, so any single run can be starved by
# whatever else is scheduled; the FLOOR is the honest figure, and the regression
# it guards against (dot-sourcing 140KB of PowerShell first) costs ~250ms, far
# more than the noise. A tighter bound here would fail on load and teach people
# to ignore the suite.
#
# Marginal, for the same reason as the dot-source measurement above: the
# absolute number is dominated by powershell.exe starting at all (~250ms on
# an idle box, ~670ms on a busy one), and the regression this guards is the
# callback going back to dot-sourcing 140KB of logbook_common.ps1 first,
# which costs ~250ms of its OWN on top of that. Subtracting a bare process
# start measures the callback, not the machine.
$yasbSelf = Join-Path $PSScriptRoot 'logix_yasb.ps1'
$clickBaselineMs = Measure-BestOf3 @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-Command', 'exit')
$clickTotalMs = Measure-BestOf3 @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $yasbSelf, '-Action', 'open')
$clickMs = $clickTotalMs - $clickBaselineMs
Remove-Item (Join-Path $Global:StateDir 'bar_action') -Force -ErrorAction SilentlyContinue
Write-Host "  bare powershell: ${clickBaselineMs}ms | + callback: ${clickTotalMs}ms | marginal: ${clickMs}ms"
# Calibrated against the dot-source cost measured IN THIS SAME RUN rather
# than a hardcoded millisecond count, because the thing being detected is a
# step of exactly that size: if the callback ever goes back to dot-sourcing
# logbook_common.ps1, its marginal cost gains ~$dotSourceMs and lands well
# past this bound. A fixed number would instead encode how fast the machine
# that happened to write the test was.
$clickBudget = $dotSourceMs + 120
Assert ($clickMs -lt $clickBudget) `
    "a bar click does not pay the dot-source cost (${clickMs}ms marginal, budget ${clickBudget}ms = measured dot-source ${dotSourceMs}ms + 120ms headroom)"

Write-Host "status bar output has no BOM (YASB's json.loads chokes on one)"
# Out-File -Encoding UTF8 in Windows PowerShell 5.1 always writes a BOM.
# YASB reads this file's output as a decoded STRING and calls json.loads()
# on it; json.loads on a str (unlike on raw bytes) throws on a leading BOM,
# and YASB's own except-JSONDecodeError silently swallows it -- the bar just
# shows the raw unformatted template forever with no error anywhere. This
# bit real output on this machine; reproduce it live, not just by grepping
# source for Out-File.
Ensure-LogbookDirs
Write-LogbookBarStatus -Text '01:23' -Alt 'WS-01 - 01:23:45' -Tooltip 'WS-01' -State 'active'
$barBytes = [System.IO.File]::ReadAllBytes((Get-LogbookStatusFile))
Assert (-not ($barBytes.Length -ge 3 -and $barBytes[0] -eq 0xEF -and $barBytes[1] -eq 0xBB -and $barBytes[2] -eq 0xBF)) `
    "the written status file carries no UTF-8 BOM"
try {
    [void]([System.Text.Encoding]::UTF8.GetString($barBytes) | ConvertFrom-Json)
    Assert $true "the file round-trips through the exact decode+parse path YASB uses"
} catch {
    Assert $false "the file round-trips through the exact decode+parse path YASB uses: $($_.Exception.Message)"
}

Write-Host "XAML comments must be legal XML"
# '--' is illegal inside an XML comment, and this repo's prose comment style
# reaches for it constantly. Every occurrence has surfaced as a XamlReader
# cast failure at runtime with a stack trace pointing at the loader rather
# than at the comment, so it is worth naming directly.
$badComments = @()
foreach ($srcFile in @('logbook_common.ps1', 'logbook_timer.ps1')) {
    $p = Join-Path $PSScriptRoot $srcFile
    if (-not (Test-Path $p)) { continue }
    $text = [System.IO.File]::ReadAllText($p)
    foreach ($m in [regex]::Matches($text, '(?s)<!--(.*?)-->')) {
        $body = $m.Groups[1].Value
        if ($body -match '--' -or $body.EndsWith('-')) {
            $ln = ($text.Substring(0, $m.Index) -split "`n").Count
            $badComments += "${srcFile}:${ln}"
        }
    }
}
Assert ($badComments.Count -eq 0) "no XML comment contains '--' ($($badComments -join ', '))"

Write-Host "SELESAI: press-and-hold (reported as 'cannot be stopped')"
# Was tap-to-arm then tap-to-confirm. Between the two taps nothing moved, and
# a single tap -- the gesture everyone tries first -- looked like nothing had
# happened at all, so the honest reading was that the session could not be
# ended. A hold gives continuous feedback from the first millisecond, so there
# is no silent gap left to misread.
Assert ($timerSrc -match '\$script:SELESAI_HOLD_MS\s*=\s*(\d+)') "the hold duration is a named constant"
$holdMs = [int]$Matches[1]
Write-Host "  hold duration: ${holdMs}ms"
Assert ($holdMs -ge 800 -and $holdMs -le 2500) "long enough that a stray press cannot finish it, short enough not to be a chore (${holdMs}ms)"
Assert ($timerSrc -match 'Add_PreviewMouseLeftButtonDown') "the hold starts on button-down, not on a completed click"
Assert ($timerSrc -match 'Add_PreviewMouseLeftButtonUp') "releasing early cancels the hold"
# Capture, not MouseLeave. MouseLeave cancelled holds the user was still
# making whenever the anchored card shifted under the pointer; capture makes
# the release the only thing that ends a hold, and guarantees it arrives.
Assert ($timerSrc -match 'CaptureMouse\(\)') "the button captures the mouse so the release is never missed"
Assert ($timerSrc -match 'ReleaseMouseCapture\(\)') "and releases that capture again"
Assert ($timerSrc -notmatch 'selesaiBtn\.Add_MouseLeave') "a stray MouseLeave cannot cancel a hold in progress"
# Nothing else may yank the card away mid-hold either.
$collapseFn = [regex]::Match($timerSrc, 'function Start-LogbookCollapseCountdown\s*\{(?s).*?\n\}').Value
Assert ($collapseFn -match 'selesaiHolding') "the collapse countdown refuses to close the card during a hold"
Assert ($timerSrc -match 'cardOpen -and -not \$script:selesaiHolding') "a held press is never treated as an outside click"
# The fill has to be driven far finer than the widget's 1s tick or the bar
# visibly jumps, which is the same 'is this even doing anything' feeling the
# hold exists to remove.
Assert ($timerSrc -match 'selesaiHoldTimer\.Interval\s*=\s*\[TimeSpan\]::FromMilliseconds\((\d+)\)') "the fill runs on its own fast timer"
$fillMs = [int]$Matches[1]
Assert ($fillMs -le 33) "the fill animates at 30fps or better (got ${fillMs}ms/frame)"
Assert ($commonSrc -match 'Name="SelesaiFill"') "the card exposes the fill the hold grows"
Assert ($commonSrc -match 'Name="SelesaiLabel"') "the label is addressable so it can flip colour over the fill"
# Border.ClipToBounds clips to the RECTANGLE and ignores CornerRadius, so the
# rounded shape has to come from a real geometry clip. Without it a part-grown
# fill detached from the left edge into a floating lozenge, and a full fill
# painted square red corners over the pill's rounded ends.
Assert ($timerSrc -match 'selesaiBtn\.Clip\s*=') "the controller installs a real rounded clip on the button"
Assert ($timerSrc -match 'RectangleGeometry') "the clip is a geometry, not a bounds flag that ignores corner radius"
Assert ($timerSrc -match 'Add_SizeChanged') "the clip is rebuilt from the measured size, not hardcoded to one card width"
# A fill carrying its own CornerRadius is what produced the floating-lozenge
# look; it must stay square and let the clip do the rounding.
$fillTag = [regex]::Match($commonSrc, '<Border Name="SelesaiFill"[^>]*>').Value
Assert ($fillTag -notmatch 'CornerRadius') "the fill itself is square-cornered (the clip rounds it, not the fill)"
# "ngapain tiba2 ada merah, ga senada": the fill was the raw critical signal,
# which is the one thing this file's own guard rail says a status colour may
# never be used as (dot or edge only, never a tinted background).
Assert ($fillTag -notmatch 'StaticResource LxCritical\}') "the fill is never the raw alert red"

# Progress is a stroke tracing the pill's PERIMETER, not a bar filling it.
# Two reasons this shape was chosen over the fill it replaces: an outline is
# literally the "dot or edge" this project's guard rail allows a status colour
# to be, and an outline never runs underneath the words at the moment the user
# most needs to read them.
Assert ($commonSrc -match 'Name="SelesaiRing"') "the button carries a ring for the hold to trace"
$ringTag = [regex]::Match($commonSrc, '<Path Name="SelesaiRing"(?s).*?/>').Value
Assert ($ringTag -match 'LxCriticalSoft') "the ring is the soft critical colour"
Assert ($ringTag -match 'Opacity="0"') "and starts invisible, so an untouched button shows no progress at all"
Assert ($ringTag -match 'IsHitTestVisible="False"') "the ring never eats the press it is reporting on"
Assert ($commonSrc -notmatch 'Name="SelesaiSweep"') "the old swept-label layer is gone, not merely unused"

# The trace is a dash as long as the swept fraction of the perimeter, then a
# gap longer than everything left, so it can never wrap round and meet itself.
Assert ($timerSrc -match 'function Set-LogbookRingProgress') "one function owns the trace"
$ringFn = [regex]::Match($timerSrc, '(?s)function Set-LogbookRingProgress.*?
\}').Value
Assert ($ringFn -match 'StrokeDashArray') "drawn with a dash array, not by rebuilding geometry every frame"
Assert ($ringFn -match 'StrokeDashOffset') "and offset so the trace starts at the top, where a dial starts"
Assert ($timerSrc -match 'Set-LogbookRingProgress \$frac') "the hold tick drives it"
# Perimeter of a stadium, not of a rectangle: the ends are semicircles, and a
# ring measured as a plain rectangle finishes early and leaves a visible gap.
Assert ($timerSrc -match '2\.0 \* \[Math\]::PI \* \$r') "the perimeter accounts for the rounded ends"
Assert ($timerSrc -notmatch "ConvertFromString\(\`$\(if \(\`$frac") "no threshold recolour left over from the flood version"

# The label asks the question the hold answers, and both input paths must set
# it -- a keyboard hold that showed different words would be a second design.
Assert ($commonSrc -match 'timerEndConfirm') "the holding state has its own configurable string"
Assert ($timerSrc -match 'function Enter-LogbookSelesaiHoldVisual') "one place defines what a started hold looks like"
$enterFn = [regex]::Match($timerSrc, '(?s)function Enter-LogbookSelesaiHoldVisual \{.*?
\}').Value
Assert ($enterFn -match 'timerEndConfirm') "it swaps the label to the confirm question"
$mouseDown = [regex]::Match($timerSrc, '(?s)Add_PreviewMouseLeftButtonDown\(\{.*?
\}\)').Value
$keyDown = [regex]::Match($timerSrc, '(?s)\$selesaiBtn\.Add_KeyDown\(\{.*?
\}\)').Value
Assert ($mouseDown -match 'Enter-LogbookSelesaiHoldVisual') "the pointer path uses it"
Assert ($keyDown -match 'Enter-LogbookSelesaiHoldVisual') "and so does the keyboard path"
# Letting go must restore the resting words, or a cancelled hold leaves the
# button permanently asking a question nobody is answering.
$resetFn = [regex]::Match($timerSrc, '(?s)function Reset-LogbookSelesai \{.*?
\}').Value
Assert ($resetFn -match 'timerEndHold') "cancelling restores the resting label"
Assert ($resetFn -match 'OpacityProperty') "and fades the ring rather than snapping it off mid-stroke"
Assert ($timerSrc -match 'BorderBrush = \$brushConv\.ConvertFromString\(\$theme\.criticalEdge\)') `
    "the press lands on the outline on frame one, before the fill is wide enough to see"

# A confirmation reachable only by holding a mouse button is one that some
# people cannot give at all -- and this one ends their session.
Assert ($timerSrc -match '\$selesaiBtn\.Focusable\s*=\s*\$true') "SELESAI can take keyboard focus"
Assert ($timerSrc -match '\$selesaiBtn\.Add_KeyDown') "a held key starts the same hold a held pointer does"
Assert ($timerSrc -match '\$selesaiBtn\.Add_KeyUp') "and releasing the key cancels it"
# Windows delivers a held key as a STREAM of KeyDown events. Without this
# guard each repeat restarts the hold from zero and the fill never advances
# past one repeat interval, so the gesture can never be completed by keyboard.
Assert ($timerSrc -match '\$e\.IsRepeat') "key repeats do not restart the hold"

# The workstation locks the instant a hold lands, so without a confirmation
# frame the last thing the user sees is a button mid-gesture -- about an
# action they then cannot check, because the machine is locked.
Assert ($timerSrc -match 'function Complete-LogbookSelesai') "completion has its own state, not just a teardown"
Assert ($timerSrc -match '\$script:selesaiCompleting') "completing twice is not possible (mouse and keyboard both reach it)"
# The CRLF trap: .gitattributes normalises .ps1 to CRLF on checkout, so a
# pattern that requires a bare newline after the closing brace matches
# nothing at all -- the block comes back empty and every assertion on it
# fails for a reason that has nothing to do with the code under test.
# Caught by running this suite on a fresh checkout rather than on a working
# tree whose files happened to have LF endings.
$completeFn = [regex]::Match($timerSrc, '(?s)function Complete-LogbookSelesai \{.*?\r?\n\}\r?\n').Value
Assert ($completeFn -match 'DispatcherTimer') `
    "the end routine is deferred, so WPF can paint the confirmation before Close-LogbookSessionAndLock blocks"
Assert ($commonSrc -match "timerEndDone") "the confirmed state has its own configurable string"
Assert ($timerSrc -match '\$script:SELESAI_DONE_MS\s*=\s*(\d+)') "the confirmation frame's duration is a named constant"
$doneMs = [int]$Matches[1]
# Long enough to register as a confirmation rather than a flicker, short
# enough that nobody waits on it -- the workstation locks immediately after.
Assert ($doneMs -ge 300 -and $doneMs -le 1500) "the confirmation is visible but not a delay (${doneMs}ms)"
# The lock must happen INSIDE the deferred tick, not before it -- calling it
# earlier would lock the screen before the frame confirming it ever painted,
# which is the whole reason the deferral exists.
$doneTick = [regex]::Match($timerSrc, '(?s)\$done\.Add_Tick\(\{.*?\}\.GetNewClosure\(\)\)').Value
Assert ($doneTick -match 'Close-LogbookSessionAndLock') "the session close and lock run inside the deferred tick"
Assert ($doneTick -match '\$window\.Close\(\)') "and the widget only closes after that"
# The old arm/confirm vocabulary must be gone, not merely unused -- a stale
# constant here is how a half-migrated control ends up with two state machines.
Assert ($timerSrc -notmatch 'DISARM_SECONDS|ARMED_CAPTION_FMT|selesaiArmed|selesaiArmTick') "no leftovers from the old arm/confirm state machine"
Assert ($commonSrc -notmatch 'batal otomatis dalam') "no leftover auto-cancel countdown copy in the XAML"

Write-Host "a bar-opened card must come back to the TOP of the topmost band"
# Topmost is a band, not a rank, and within it the last window inserted wins.
# This widget sets Topmost=True once at startup and then lives for the whole
# session, so any always-on-top window that appears LATER sits above it
# permanently. Electron apps do this routinely (Figma and Ferdium were both
# caught doing it on this machine). The failure is invisible from every angle
# that normally matters -- still WS_EX_TOPMOST, still visible, right size,
# right coordinates, and WPF still renders the card perfectly (PrintWindow
# returns it in full) -- it just composites underneath something else, so
# clicking the status bar looks like it did nothing at all.
Assert ($timerSrc -match 'function Assert-LogbookTopmost') "there is a single place that re-asserts z-order"
$openFn = [regex]::Match($timerSrc, '(?s)function Open-LogbookCard \{.*?\n\}').Value
Assert ($openFn -match 'Assert-LogbookTopmost') "opening the card re-asserts it"
$topFn = [regex]::Match($timerSrc, '(?s)function Assert-LogbookTopmost \{.*?\n\}').Value
# The toggle is the mechanism: setting Topmost=True on a window that is
# already topmost is a no-op, so only false-then-true forces re-insertion.
Assert ($topFn -match '\$window\.Topmost\s*=\s*\$false' -and $topFn -match '\$window\.Topmost\s*=\s*\$true') `
    "it toggles rather than re-setting True, which would be a no-op"
Assert ($topFn -notmatch 'Activate\(\)|Focus\(\)') `
    "and never activates the window -- WS_EX_NOACTIVATE exists so this cannot steal focus from the user's real work"

Write-Host "a card opened from the status bar must close itself"
# Collapse is normally driven by the pointer LEAVING. A card opened from the
# bar may never have had the pointer over it, so there was no enter, no
# leave, and it stayed on screen indefinitely.
Assert ($timerSrc -match 'BAR_OPEN_LINGER_SECONDS') "the bar-opened card arms its own collapse countdown"

Write-Host "opening the card from a status bar must not race-close itself"
# Reported: clicking the YASB slot opened the card and it vanished within
# ~40ms, invisibly. The card can appear far from wherever the poll last knew
# the cursor to be (a status bar is a separate process with its own click
# history), so Register-LogbookClickThrough's poll can see what looks like a
# leave on the very first tick after the card appears. The fix does not try
# to prevent every way that could fire; it guards the CLOSE ITSELF while the
# card is pinned.
Assert ($timerSrc -match '\$script:cardPinnedUntilTouched') "a pin flag exists to protect a just-opened bar card"

# Order matters, not just presence: the pin check must be the FIRST thing
# Start-LogbookCollapseCountdown does after the reply-typing guard, so it
# short-circuits before ever reaching the unconditional Close-LogbookCard
# further down. A pin check added AFTER that branch would pass a plain grep
# for its existence and do nothing.
$fnStart = $timerSrc.IndexOf('function Start-LogbookCollapseCountdown')
Assert ($fnStart -ge 0) "Start-LogbookCollapseCountdown is defined"
if ($fnStart -ge 0) {
    $fnEnd = $timerSrc.IndexOf("`nfunction ", $fnStart + 1)
    $body = if ($fnEnd -gt $fnStart) { $timerSrc.Substring($fnStart, $fnEnd - $fnStart) } else { $timerSrc.Substring($fnStart) }
    $pinAt = $body.IndexOf('cardPinnedUntilTouched')
    $closeAt = $body.IndexOf('Close-LogbookCard')
    Assert ($pinAt -ge 0 -and $closeAt -ge 0 -and $pinAt -lt $closeAt) `
        "the pin is checked before the unconditional close, not after"
}

Assert ($timerSrc -match '-OnPointerEnter') "pointer-enter clears the pin -- once genuinely touched, ordinary hover rules resume"
Assert ([regex]::IsMatch($timerSrc, '-OnPointerEnter\s*\{.{0,900}?cardPinnedUntilTouched\s*=\s*\$false', 'Singleline')) `
    "OnPointerEnter specifically un-pins the card"

Assert ($timerSrc -match '-OnOutsideClick') "a click outside the card dismisses it -- the native menu behaviour asked for"
Assert ([regex]::IsMatch($timerSrc, '-OnOutsideClick\s*\{.{0,800}?Close-LogbookCard', 'Singleline')) `
    "the outside-click handler actually closes the open card"

# Close-LogbookCard is the one function every dismissal path funnels through
# (SELESAI's own end-of-session path calls it too), so resetting both flags
# there -- rather than in every caller -- is what stops the pin or the
# borrowed cursor position from leaking into the next time the card opens.
$closeStart = $timerSrc.IndexOf('function Close-LogbookCard')
Assert ($closeStart -ge 0) "Close-LogbookCard is defined"
if ($closeStart -ge 0) {
    $closeEnd = $timerSrc.IndexOf("`nfunction ", $closeStart + 1)
    $closeBody = if ($closeEnd -gt $closeStart) { $timerSrc.Substring($closeStart, $closeEnd - $closeStart) } else { $timerSrc.Substring($closeStart) }
    Assert ($closeBody -match 'cardPinnedUntilTouched\s*=\s*\$false') "closing always clears the pin"
    Assert ($closeBody -match 'cardAnchorOverride\s*=\s*\$null') "closing always clears the borrowed cursor-anchored position"
}

Write-Host "a card opened from the bar must actually render, every time, not just once"
# The deeper bug behind "gaada menunya" surviving the FIRST fix: the window
# was fully $window.Hide()-ing between appearances in 'bar' posture (since
# nothing else -- no pill, no strip -- is ever shown there to keep it
# visible). Every reopen therefore forced a fresh native Hide()->Show() cycle,
# unlike pill/strip posture where the window stays continuously Shown() and
# only toggles WS_EX_TRANSPARENT for click-through. State (cardOpen, WPF
# Opacity/Visibility) and even raw Win32 z-order all read back correctly after
# that cycle -- nothing exceptioned, nothing logged -- the window just never
# painted a visible pixel. Confirmed live: three consecutive open -> 22s
# auto-collapse -> reopen rounds against one long-lived process; only a fix
# that survives round 2 and 3 (not just round 1, a fresh process's first-ever
# Show()) actually closes this out.
Assert ($timerSrc -match "elseif \(\`$script:posture -eq 'bar'\)") `
    "bar posture is carved out of the Hide() path"
$hideIdx = $timerSrc.IndexOf('function Update-LogbookWidgetView')
Assert ($hideIdx -ge 0) "Update-LogbookWidgetView is defined"
if ($hideIdx -ge 0) {
    $hideEnd = $timerSrc.IndexOf("`nfunction ", $hideIdx + 1)
    $hideBody = if ($hideEnd -gt $hideIdx) { $timerSrc.Substring($hideIdx, $hideEnd - $hideIdx) } else { $timerSrc.Substring($hideIdx) }
    # Both branches must exist and in the right relationship: bar posture
    # skips Hide() (falls into the elseif doing nothing), everything else
    # still gets a real Hide() -- pill/strip posture legitimately has nothing
    # to show when the sliver is retracted, and hiding there is correct.
    Assert ($hideBody -match "posture -eq 'bar'") "the carve-out is scoped to bar posture specifically"
    Assert ($hideBody -match '\$window\.Hide\(\)') "non-bar posture still hides normally when nothing is shown"
    # WHICH branch is which, not merely that both strings appear. The condition
    # shipped inverted for exactly this reason: bar posture was taking the
    # Hide() the comment above it says must never happen there, pill/strip was
    # taking the do-nothing, and a grep for the two strings passed all the same.
    # Every YASB click set cardOpen, logged, and painted nothing.
    $branch = [regex]::Match($hideBody,
        "(?s)elseif \(\`$script:posture -eq 'bar'\) \{(.*?)\} else \{(.*?)\n\s*\}")
    Assert ($branch.Success) "the two tail branches are shaped as expected"
    if ($branch.Success) {
        $barBranch  = $branch.Groups[1].Value
        $elseBranch = $branch.Groups[2].Value
        Assert ($barBranch -notmatch '\$window\.Hide\(\)') `
            "the BAR branch does not hide -- a hidden window is what never repaints on the next open"
        Assert ($elseBranch -match '\$window\.Hide\(\)') `
            "and the non-bar branch is the one that actually hides"
    }
}

Write-Host "server pairing: a device can join a server, and leave one, after install"
# Isolated through the two env vars the resolution path already honours:
# LOGIX_HOME moves the core dir (so device.json and config.env are written to a
# temp folder), and LOGIX_SERVER_URL is read before config.env is opened at
# all. Nothing here may touch the real pairing on the machine running the
# suite -- a test that unpairs the developer's own workstation is a test that
# gets deleted rather than fixed.
$pairDir = Join-Path $env:TEMP ('lxpair_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$savedHome = $env:LOGIX_HOME
$savedUrl = $env:LOGIX_SERVER_URL
# The LOG has to be redirected too, not just the data files. LOGIX_HOME moves
# the core dir (device.json, config.env), but Write-LogbookInfo writes to
# $Global:ErrorLog under $Global:StateDir, which it does not touch -- so an
# earlier version of this test left "Server pairing removed on this device"
# in the REAL agent log of a machine whose pairing was never touched. Nobody
# reading that log later has any way to know it came from a test.
$savedLog = $Global:ErrorLog
try {
    New-Item -ItemType Directory -Force -Path $pairDir | Out-Null
    $env:LOGIX_HOME = $pairDir
    $env:LOGIX_SERVER_URL = ''
    $Global:ErrorLog = Join-Path $pairDir 'test.log'

    Assert ((Get-LogixCoreDir) -eq $pairDir) "the test really is pointed at a scratch core dir"

    # --- a fresh device is unpaired, and says so ---
    $st = Get-LogbookPairingState
    Assert (-not $st.Paired) "a device with no identity and no server is not paired"

    # --- half a pairing is not a pairing ---
    # A URL with no identity is a server we were never let into; an identity
    # with no URL cannot reach anything. Calling either 'connected' is how a
    # device silently stops syncing while the UI shows a green dot.
    $env:LOGIX_SERVER_URL = 'https://logix.example'
    Assert (-not (Get-LogbookPairingState).Paired) "a server URL alone is not a pairing"

    $idPath = Get-LogbookDeviceIdentityPath
    @{ device_id = 'dev_test01'; api_key = 'k'; category = 'lab_workstation' } |
        ConvertTo-Json | Out-File -FilePath $idPath -Encoding UTF8 -Force
    $st = Get-LogbookPairingState
    Assert ($st.Paired) "URL plus identity plus key is a pairing"
    Assert ($st.DeviceId -eq 'dev_test01') "the device id is surfaced for the UI"
    Assert ($st.Category -eq 'lab_workstation') "so is the category the server assigned"

    $env:LOGIX_SERVER_URL = ''
    Assert (-not (Get-LogbookPairingState).Paired) "an identity alone is not a pairing either"
    $env:LOGIX_SERVER_URL = 'https://logix.example'

    # --- leaving a server ---
    $r = Remove-LogbookServerPairing
    Assert ($r.Ok) "unpairing succeeds"
    Assert (-not (Test-Path $idPath)) "the device identity is gone"
    $cfgAfter = Get-Content (Join-Path $pairDir 'config.env') -Raw
    Assert ($cfgAfter -match 'LOGIX_SERVER_URL=\s*$|LOGIX_SERVER_URL=$') "the server address is cleared in config.env"

    # --- the address check runs before a single-use code is spent ---
    # An invite is single-use per API_CONTRACT.md, so firing one at a mistyped
    # address burns it and sends the operator back to an admin for another.
    foreach ($bad in @('', '   ', 'logix.example', 'ftp://logix.example')) {
        $probe = Test-LogbookServerReachable -Url $bad -TimeoutSec 2
        Assert (-not $probe.Ok) "'$bad' is rejected without a network call"
        Assert ($probe.Detail -ne '') "and says why ('$($probe.Detail)')"
    }

    # --- pairing refuses to spend a code it cannot use ---
    foreach ($case in @(@{ u = ''; c = 'ABC' }, @{ u = 'https://x'; c = '' })) {
        $res = Invoke-LogbookServerPairing -Url $case.u -Code $case.c
        Assert (-not $res.Ok) "pairing needs both an address and a code"
        Assert ($res.Error -ne '') "and reports which is missing"
    }

    # --- config.env round-trip, same semantics as the installer's copy ---
    Set-LogbookConfigValue -Key 'LOGIX_SERVER_URL' -Value 'https://a.example'
    Set-LogbookConfigValue -Key 'LOGIX_DEVICE_NAME' -Value 'WS-99'
    Set-LogbookConfigValue -Key 'LOGIX_SERVER_URL' -Value 'https://b.example'
    $lines = @(Get-Content (Join-Path $pairDir 'config.env'))
    Assert (@($lines | Where-Object { $_ -like 'LOGIX_SERVER_URL=*' }).Count -eq 1) "rewriting a key replaces it rather than appending"
    Assert (@($lines | Where-Object { $_ -eq 'LOGIX_SERVER_URL=https://b.example' }).Count -eq 1) "and keeps the newest value"
    Assert (@($lines | Where-Object { $_ -eq 'LOGIX_DEVICE_NAME=WS-99' }).Count -eq 1) "sibling keys survive"
} finally {
    $env:LOGIX_HOME = $savedHome
    $env:LOGIX_SERVER_URL = $savedUrl
    $Global:ErrorLog = $savedLog
    Remove-Item $pairDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "server pairing: one enrolment path, not two"
$pairUiSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'logix_server.ps1')
# The UI must drive the helpers, not speak to /api/enroll itself. A second
# enrolment path is a second thing to keep secure and a second thing to
# forget when the contract changes.
Assert ($pairUiSrc -match 'Invoke-LogbookServerPairing') "the pairing screen uses the shared enrolment helper"
# Checked on the CALL, not on the string: the file is allowed to name the
# endpoint in a comment explaining which one the helper drives.
Assert ($pairUiSrc -notmatch 'Invoke-RestMethod|Invoke-WebRequest') "and makes no HTTP call of its own"
Assert ($pairUiSrc -match 'Test-LogbookServerReachable') "it checks the address before spending the code"
Assert ($commonSrc -match "Invoke-RestMethod -Uri \(\`$trimmed \+ '/api/enroll'\)") "the helper is what talks to /api/enroll"
# Leaving a server must not touch what this device recorded locally: the
# session log is the device's own record, not the server's to take back.
$unpairFn = [regex]::Match($commonSrc, '(?s)function Remove-LogbookServerPairing \{.*?\n\}').Value
Assert ($unpairFn -ne '') "Remove-LogbookServerPairing is defined"
Assert ($unpairFn -notmatch 'logix\.db|physical_log|Remove-Item.*\.db') "unpairing never deletes local session data"

Write-Host "server pairing: the screen parses and opens on status, not on a form"
$pairXaml = [xml](Build-LogbookServerPairingXaml (Get-LogbookDefaultConfig) ([ordered]@{
    Paired = $false; ServerUrl = ''; DeviceId = ''; Category = ''; HasKey = $false }))
$named = @{}
foreach ($n in @('StatusDot','StatusText','ServerBox','CodeBox','CodeRow','ConnectBtn','TestBtn','DisconnectBtn','MessageText','DeviceIdText','CloseBtn')) {
    $hit = $pairXaml.SelectNodes("//*[@Name='$n']")
    Assert ($hit.Count -eq 1) "the pairing screen exposes $n"
}
$disc = $pairXaml.SelectNodes("//*[@Name='DisconnectBtn']")[0]
Assert ($disc.Visibility -eq 'Collapsed') "an unpaired device is not offered a Disconnect button"

Write-Host "periodic sync retry: an unattended device actually retries a failed sync"
# Before this, --sync-to-server existed ONLY as a manual CLI flag -- nothing
# in the whole codebase ever called it. A device that went idle right after
# a failed inline sync (machine locked, nobody logging in or out) would
# never retry again until the next real session event, which could be hours
# away. See Invoke-LogbookPeriodicSyncRetry's own comment in
# logbook_common.ps1.
Assert ($monitorSrc -match 'Invoke-LogbookPeriodicSyncRetry') `
    "the monitor's heartbeat loop actually calls the periodic retry"
$monitorTickIdx = $monitorSrc.IndexOf('while ($true) {')
$retryCallIdx = $monitorSrc.IndexOf('Invoke-LogbookPeriodicSyncRetry')
Assert ($monitorTickIdx -ge 0 -and $retryCallIdx -gt $monitorTickIdx) `
    "the call is inside the heartbeat loop, not just defined and forgotten"
Assert ($commonSrc -match 'function Get-LogbookSyncRetrySeconds') "the retry interval is its own named setting"
Assert ($commonSrc -match "Start-Process -FilePath \`$python") `
    "the retry launches detached (Start-Process), never runs the sync attempt inline on the heartbeat thread"
$periodicFn = [regex]::Match($commonSrc, '(?s)function Invoke-LogbookPeriodicSyncRetry \{.*?\n\}').Value
Assert ($periodicFn -ne '') "Invoke-LogbookPeriodicSyncRetry is defined"
Assert ($periodicFn -match "-not \(Get-LogbookConfigEnv 'LOGIX_SERVER_URL'\)") `
    "an unpaired (device-only) machine takes the cheap early return -- never spawns anything"
Assert ($periodicFn -notmatch '-Wait') `
    "Start-Process must not pass -Wait, or 'detached' is a lie and this blocks the loop after all"

# Isolated the same way the pairing tests above are: LOGIX_HOME points this
# whole check at a scratch core dir, so it can neither read nor affect
# whatever is actually configured on the machine running the suite.
$retryDir = Join-Path $env:TEMP ('lxretry_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$savedHome2 = $env:LOGIX_HOME
$savedUrl2 = $env:LOGIX_SERVER_URL
try {
    New-Item -ItemType Directory -Force -Path $retryDir | Out-Null
    $env:LOGIX_HOME = $retryDir
    $env:LOGIX_SERVER_URL = ''
    $script:nextSyncRetryAt = [datetime]::MinValue

    Invoke-LogbookPeriodicSyncRetry
    Assert ($script:nextSyncRetryAt -eq [datetime]::MinValue) `
        "device-only (no server configured): the schedule is untouched, proving nothing was spawned"

    # A server IS configured, and the core dir actually has log_physical.py
    # (copied from the real windows/../logix core so Test-Path passes) --
    # this really does launch a detached python process. It is pointed at a
    # closed local port, so it fails fast and exits on its own; this test
    # does not wait on it, matching the fire-and-forget contract being
    # tested. The Python-side behaviour of that process (retries, backoff,
    # idempotency) is exhaustively covered by tests/test_sync_integration.py
    # -- this layer only proves PowerShell actually launches it, once, and
    # correctly reschedules so it does not launch again immediately.
    $coreSrc = Join-Path $PSScriptRoot '..\logix'
    Copy-Item (Join-Path $coreSrc 'log_physical.py') $retryDir -Force
    Copy-Item (Join-Path $coreSrc 'paths.py') $retryDir -Force
    $env:LOGIX_SERVER_URL = 'http://127.0.0.1:1'  # port 1: never listens, fails fast
    $env:LOGIX_DB = Join-Path $retryDir 'device.db'

    $before = Get-Date
    Invoke-LogbookPeriodicSyncRetry
    Assert ($script:nextSyncRetryAt -gt $before) `
        "server configured and due: the next attempt is scheduled into the future"
    Assert ($script:nextSyncRetryAt -le $before.AddSeconds((Get-LogbookSyncRetrySeconds) + 2)) `
        "...by roughly the configured interval, not something wildly different"

    $before2 = $script:nextSyncRetryAt
    Invoke-LogbookPeriodicSyncRetry
    Assert ($script:nextSyncRetryAt -eq $before2) `
        "calling it again before the interval elapses is a no-op -- does not reschedule, does not relaunch"
} finally {
    $env:LOGIX_HOME = $savedHome2
    $env:LOGIX_SERVER_URL = $savedUrl2
    Remove-Item Env:\LOGIX_DB -ErrorAction SilentlyContinue
    Remove-Item $retryDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "session lifecycle: one explicit state, derived from facts that already existed"
# The lifecycle was real but implicit -- spread across "does session.json
# exist", "is timer_ready.flag there", "is workstation_locked.flag there",
# "is a timer alive", each checked ad hoc by whichever caller needed it.
# Get-LogbookSessionState is one named place to ask. Every state below is
# driven by REAL files here, not by mocking the function's internals.
$stateDir = Join-Path $env:TEMP ('lxstate_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$savedStateDir = $Global:StateDir
$savedSession = $Global:SessionFile
$savedEnding = $Global:SessionEndingFlag
$savedLocked = $Global:LockedFlagPath
try {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $Global:StateDir = $stateDir
    $Global:SessionFile = Join-Path $stateDir 'session.json'
    $Global:SessionEndingFlag = Join-Path $stateDir 'session_ending.flag'
    $Global:LockedFlagPath = Join-Path $stateDir 'workstation_locked.flag'
    $readyFlag = Join-Path $stateDir 'timer_ready.flag'
    $sessionJson = '{"session_id":"s1","nama":"Uji","start_time":"2026-01-01T10:00:00"}'

    Assert ((Get-LogbookSessionState).State -eq 'IDLE') "no session file at all -> IDLE"

    # A stale ending marker with no session file means the close DID work and
    # only its cleanup was interrupted. Still IDLE -- the session is over.
    Set-Content -LiteralPath $Global:SessionEndingFlag -Value 'x' -Encoding ASCII
    Assert ((Get-LogbookSessionState).State -eq 'IDLE') "stale ending marker, no session -> still IDLE"
    Remove-Item $Global:SessionEndingFlag -Force

    Set-Content -LiteralPath $Global:SessionFile -Value $sessionJson -Encoding UTF8
    Assert ((Get-LogbookSessionState).State -eq 'STARTING') "session recorded but the widget has not reached the screen -> STARTING"

    Set-Content -LiteralPath $readyFlag -Value '' -Encoding ASCII

    # Whether a timer process exists is the one input here that is NOT a file
    # under $stateDir, so it cannot be isolated by pointing the globals at a
    # scratch directory -- on a developer machine the REAL agent is usually
    # running, and the first version of this check duly reported RUNNING and
    # failed. Shadow the lookup so both branches are exercised deterministically
    # on any machine, then restore it.
    $origProcFn = (Get-Item function:Get-ProcessByCommandPattern).ScriptBlock
    try {
        Set-Item function:Get-ProcessByCommandPattern { param([string]$Pattern) return @([pscustomobject]@{ ProcessId = 4242 }) }
        Assert ((Get-LogbookSessionState).State -eq 'RUNNING') "session recorded, widget up -> RUNNING"

        Set-Item function:Get-ProcessByCommandPattern { param([string]$Pattern) return @() }
        $s = Get-LogbookSessionState
        Assert ($s.State -eq 'ERROR') "session open but its widget is gone -> ERROR (not a healthy RUNNING)"
        Assert ($s.Detail -match 'timer widget is not running') "and says so"
    } finally {
        Set-Item function:Get-ProcessByCommandPattern $origProcFn
    }

    Set-Content -LiteralPath $Global:LockedFlagPath -Value '' -Encoding ASCII
    Assert ((Get-LogbookSessionState).State -eq 'PAUSED') "workstation locked with a session open -> PAUSED (what the lock screen itself calls it)"
    Remove-Item $Global:LockedFlagPath -Force

    # A close in progress right now.
    Set-Content -LiteralPath $Global:SessionEndingFlag -Value (Get-Date).ToString('o') -Encoding ASCII
    Assert ((Get-LogbookSessionState).State -eq 'ENDING') "a close underway -> ENDING"

    # The same marker, old, with the session file STILL present: this is the
    # documented ACL/ownership failure in Close-ActiveLogbookSession, where
    # the event is logged but session.json cannot be removed. Before this it
    # looked exactly like a healthy running session, which is why "SELESAI
    # did nothing" was so hard to see.
    (Get-Item $Global:SessionEndingFlag).LastWriteTime = (Get-Date).AddSeconds(-($Global:SessionEndingGraceSeconds + 60))
    $s = Get-LogbookSessionState
    Assert ($s.State -eq 'ERROR') "a close that never finished -> ERROR, not RUNNING"
    Assert ($s.Detail -match 'still present') "and names the actual problem"
    Remove-Item $Global:SessionEndingFlag -Force

    # An unreadable session file is a real state too (truncated write, disk
    # problem) and must not throw its way out of a status check.
    Set-Content -LiteralPath $Global:SessionFile -Value '{ this is not json' -Encoding UTF8
    $s = Get-LogbookSessionState
    Assert ($s.State -eq 'ERROR') "unreadable session file -> ERROR"
    Assert ($s.Detail -match 'unreadable') "and says why"

    # Never throws, whatever it finds -- a status probe that can raise is a
    # status probe every caller has to wrap.
    Remove-Item $Global:SessionFile -Force
    $Global:StateDir = Join-Path $stateDir 'does-not-exist'
    $Global:SessionFile = Join-Path $Global:StateDir 'session.json'
    $threw = $false
    try { [void](Get-LogbookSessionState) } catch { $threw = $true }
    Assert (-not $threw) "a missing state directory is an answer, not an exception"
} finally {
    $Global:StateDir = $savedStateDir
    $Global:SessionFile = $savedSession
    $Global:SessionEndingFlag = $savedEnding
    $Global:LockedFlagPath = $savedLocked
    Remove-Item $stateDir -Recurse -Force -ErrorAction SilentlyContinue
}

# The marker has to actually be written by the close path, or ENDING is a
# state nothing can ever observe.
$closeFn = [regex]::Match($commonSrc, '(?s)function Close-ActiveLogbookSession \{.*?\n\}').Value
Assert ($closeFn -match 'SessionEndingFlag') "the close path marks ENDING"
Assert ($closeFn -match '(?s)Stop-LogbookTimers\s*\r?\n.*?Remove-Item \$Global:SessionEndingFlag') `
    "and clears it on the success path only -- the failure returns deliberately leave it, which is what makes a stuck close visible"

Write-Host "sync status: the CLI surface a future Device UI will read"
Assert ($commonSrc -notmatch 'sync_status\(') "sync status stays Python-side (log_physical.py --sync-status) -- no PowerShell reimplementation to drift out of sync with it"

Write-Host "START latency: the click handler does not block on a Python process"
# Measured cause, not a guess: the synchronous bridge cost ~251ms, of which the
# actual SQLite work was 6.6ms -- 82ms was starting a Python interpreter and
# 135ms importing the module. All of it ran on the WPF UI thread inside the
# Click handler, so the window could not repaint at the moment the user pressed
# the button. Cold end-to-end, the click blocked for ~450ms before this and
# ~100ms after.
$popupSrc = Get-Content -Raw (Join-Path $PSScriptRoot 'logbook_popup.ps1')
Assert ($popupSrc -match "Invoke-WSLLogbook -Event 'START'[^
]*-Async") `
    "START dispatches its log write asynchronously"
Assert ($commonSrc -match 'function Remove-StaleLogbookPayloads') `
    "the async path sweeps the payload files it can no longer delete inline"
$bridgeFn = [regex]::Match($commonSrc, '(?s)function Invoke-WSLLogbook \{.*?
\}').Value
Assert ($bridgeFn -match 'if \(-not \$Async\) \{ Remove-Item \$payloadPath') `
    "and the synchronous path still deletes its own payload immediately"
# A close must NOT be async: it has to know the row was really written before
# the workstation locks behind it.
Assert ($commonSrc -match "(?s)function Close-ActiveLogbookSession.*?Invoke-WSLLogbook -Event \`$Reason(?![^
]*-Async)") `
    "ending a session still waits for its write (only START is fire-and-forget)"

Write-Host "START latency: the first-call costs are paid before the user can click"
# PowerShell loads cmdlets and .NET types lazily, so the FIRST ConvertTo-Json
# in a process costs ~160ms, the first Start-Process ~135ms, and so on. The
# popup is always a cold process, so without this every one of those landed
# inside the click handler.
Assert ($commonSrc -match 'function Initialize-LogbookStartPathWarmup') "there is a warm-up for the START path"
$warmFn = [regex]::Match($commonSrc, '(?s)function Initialize-LogbookStartPathWarmup \{.*?
\}').Value
foreach ($piece in @('Find-LogixPython', 'Test-LogbookUseWSL', 'ConvertTo-Json', 'Start-Process')) {
    Assert ($warmFn -match [regex]::Escape($piece)) "the warm-up covers $piece"
}
Assert ($popupSrc -match 'Initialize-LogbookStartPathWarmup') "the popup runs it"
# It has to run while the form is being BUILT, not from the click handler --
# otherwise it would simply move the same cost to the same place.
$warmIdx = $popupSrc.IndexOf('Initialize-LogbookStartPathWarmup')
$clickIdx = $popupSrc.IndexOf('$btn.Add_Click(')
Assert ($warmIdx -gt 0 -and $clickIdx -gt 0 -and $warmIdx -lt $clickIdx) `
    "and runs it before the click handler is even wired up"
# A warm-up that throws must never be able to stop a sign-in.
Assert ($warmFn -match 'catch') "a failed warm-up degrades to slow, never to broken"

# Both lookups it warms have to actually STAY warm, or warming them is theatre.
Assert ($commonSrc -match '\$script:logixPythonResolved') "the interpreter lookup is cached for the process"
Assert ($commonSrc -match '\$script:logixUseWslCached') "so is the WSL-vs-native decision"

# The summary lives at the END of the file, which sounds too obvious to write
# down until you notice it did not: it sat at what was once the last line, and
# every section added after it -- roughly half this suite, including the checks
# on the very bug this run was chasing -- printed FAIL and still exited 0. A
# test that cannot fail the build is documentation with a stopwatch.
if ($fail -gt 0) { Write-Host "`n$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll popup-config checks passed." -ForegroundColor Green
exit 0
