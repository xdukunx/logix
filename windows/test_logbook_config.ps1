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
