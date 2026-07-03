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
Assert ($doc.Window.Background -eq '#741B47') "default accent on window background"
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
    Assert ($merged.branding.colors.primary -eq '#073763') "primary kept from defaults"
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

Write-Host "session timer -> XAML"
$session = [pscustomobject]@{ session_type = 'Physical'; nama = 'Nama & "Contoh"'; tujuan = 'Running Data' }
$timerXaml = Build-LogbookTimerXaml -cfg $cfg -session $session -deviceName 'LAB-PC-01 <Test>'
$timerDoc = [xml]$timerXaml
Assert ($timerDoc.Window.Width -eq '340') "timer window width 340"
$namaValue = ($timerDoc.SelectNodes("//*[local-name()='TextBlock']") | Where-Object { $_.Name -eq 'NamaValue' }).Text
Assert ($namaValue -eq 'Nama & "Contoh"') "nama with ampersand/quote escaped and round-trips"
$deviceValue = ($timerDoc.SelectNodes("//*[local-name()='TextBlock']") | Where-Object { $_.Name -eq 'DeviceValue' }).Text
Assert ($deviceValue -eq 'LAB-PC-01 <Test>') "device name with angle bracket escaped and round-trips"
$clockMain = $timerDoc.SelectNodes("//*[local-name()='TextBlock']") | Where-Object { $_.Name -eq 'ClockMain' }
Assert ($clockMain.Text -eq '00:00') "clock starts at 00:00"
$pulseEllipse = $timerDoc.SelectNodes("//*[local-name()='Ellipse']") | Where-Object { $_.Name -eq 'Pulse' }
Assert ($null -ne $pulseEllipse) "pulse is an Ellipse (animated via BeginAnimation, not a text swap)"
$shapePaths = $timerDoc.SelectNodes("//*[local-name()='Path']")
Assert ($shapePaths.Count -eq 1) "exactly one chamfered-shape Path element"
$pathData = $shapePaths[0].Data
Assert ($pathData.StartsWith('M 20,0') -and $pathData.TrimEnd().EndsWith('Z')) "shape path data starts/ends correctly (closed geometry)"
Assert ($timerDoc.Window.Height -eq '210') "window starts at a fixed 210 height (deterministic, not SizeToContent -- see logbook_timer.ps1's HEIGHT_* constants)"
$infoSection = $timerDoc.SelectNodes("//*[local-name()='StackPanel']") | Where-Object { $_.Name -eq 'InfoSection' }
Assert ($infoSection.Visibility -eq 'Visible' -or [string]::IsNullOrEmpty($infoSection.Visibility)) "info section starts visible (first 10s of a session)"
$messageSection = $timerDoc.SelectNodes("//*[local-name()='Border']") | Where-Object { $_.Name -eq 'MessageSection' }
Assert ($messageSection.Visibility -eq 'Collapsed') "message section starts collapsed (Auto row -> zero height, no reserved blank space)"
$messageIconBadge = $timerDoc.SelectNodes("//*[local-name()='Border']") | Where-Object { $_.Name -eq 'MessageIconBadge' }
Assert ($null -ne $messageIconBadge) "message has a colored icon badge (toast-style, matching the reference)"
$messageTitle = $timerDoc.SelectNodes("//*[local-name()='TextBlock']") | Where-Object { $_.Name -eq 'MessageTitle' }
Assert ($null -ne $messageTitle) "message has a bold title line separate from the body text"

Write-Host "timer shape geometry at various heights"
$shape90 = Get-LogbookTimerShapeData 50   # below the floor
Assert ($shape90 -match 'L 320,70 ') "height floor (90) applied when given a too-small content height"
$shape300 = Get-LogbookTimerShapeData 300
Assert ($shape300 -match 'L 320,280 ' -and $shape300.TrimEnd().EndsWith('Z')) "shape geometry recomputes correctly for a taller (message-extended) height"
$shapeHuge = Get-LogbookTimerShapeData 5000
Assert ($shapeHuge -match 'L 320,480 ') "height ceiling (500) applied -- guards against ever filling the screen again"

if ($fail -gt 0) { Write-Host "`n$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll popup-config checks passed." -ForegroundColor Green
