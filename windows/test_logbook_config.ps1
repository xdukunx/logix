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
Assert ((& $tb 'ArmedCaption').Visibility -eq 'Collapsed') "armed caption hidden until SELESAI is armed"

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

if ($fail -gt 0) { Write-Host "`n$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll popup-config checks passed." -ForegroundColor Green

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

# Measure it rather than trust the grep: a fresh process, dot-source only.
$sw = [Diagnostics.Stopwatch]::StartNew()
& powershell -NoProfile -ExecutionPolicy Bypass -Command `
    ". '$(Join-Path $PSScriptRoot 'logbook_common.ps1')'" | Out-Null
$dotSourceMs = [int]$sw.ElapsedMilliseconds
Write-Host "  cold process + dot-source: ${dotSourceMs}ms"
# Generous: ~250ms of that is powershell.exe itself. One stray Add-Type puts it
# over 700ms, which is what this is here to catch.
Assert ($dotSourceMs -lt 900) "dot-sourcing logbook_common.ps1 stays cheap (${dotSourceMs}ms, budget 900ms)"

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

Write-Host "SELESAI confirm window (reported as 'cannot be stopped')"
# Two-step by design: press once to arm, again to confirm. The window was 3
# seconds, which is not enough time to read a button you have never seen,
# understand it and press again -- it silently re-disarmed and the honest
# reading was that the session could not be ended at all.
Assert ($timerSrc -match '\$script:DISARM_SECONDS\s*=\s*(\d+)') "the confirm window is a named constant"
$disarm = [int]$Matches[1]
Write-Host "  confirm window: ${disarm}s"
Assert ($disarm -ge 5 -and $disarm -le 15) "long enough to read and act on, short enough not to arm by accident (${disarm}s)"
# The caption used to hardcode '3 dtk' in the XAML, so changing the constant
# would have made the countdown lie.
Assert ($timerSrc -match 'ARMED_CAPTION_FMT') "the caption text is derived from the constant, not written twice"
Assert ($commonSrc -notmatch 'batal otomatis dalam 3 dtk') "no hardcoded countdown number left in the XAML"

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
Assert ([regex]::IsMatch($timerSrc, '-OnOutsideClick\s*\{.{0,400}?Close-LogbookCard', 'Singleline')) `
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
Assert ($timerSrc -match "elseif \(\`$script:posture -ne 'bar'\)") `
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
    Assert ($hideBody -match "posture -ne 'bar'") "the carve-out is scoped to bar posture specifically"
    Assert ($hideBody -match '\$window\.Hide\(\)') "non-bar posture still hides normally when nothing is shown"
}
