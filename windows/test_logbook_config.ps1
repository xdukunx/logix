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
Assert ($doc.Window.Background -eq '#070C15') "default deep-navy surface on fullscreen popup background (Client Foundation)"
$logo = ($doc.SelectNodes("//*[local-name()='TextBlock']") | Where-Object { $_.Name -eq 'LogoText' }).Text
Assert ($logo -eq 'Logix') "default logo text Logix"
$items = $doc.SelectNodes("//*[local-name()='ComboBoxItem']")
Assert ($items.Count -eq 5) "2 access + 3 purpose = 5 combo items"

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
    Assert ($purpose2.Count -eq 4) "4 purpose items rendered"
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
Assert ($pill.Width -eq '150' -and $pill.Height -eq '32') "pill is 150x32 (design D-02 state 01)"
Assert ($pill.CornerRadius -eq '16') "pill is fully rounded (half its height)"
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

if ($fail -gt 0) { Write-Host "`n$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll popup-config checks passed." -ForegroundColor Green
