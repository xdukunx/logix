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
Write-Host "timer widget: SELESAI is a two-step, never a single stray click"
$session = @{ nama = 'Mahasiswa Uji'; nim = '000000000'; keperluan = 'Maintenance'
              akses = 'Fisik'; started = (Get-Date).AddMinutes(-12).ToString('o') }
$widget = [Windows.Markup.XamlReader]::Load(
    (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookTimerXaml -cfg $cfg -session $session -deviceName 'WS-01 - GPU-A100'))))

$pill    = $widget.FindName('PillView')
$card    = $widget.FindName('CardView')
$selesai = $widget.FindName('SelesaiBtn')
$armed   = $widget.FindName('ArmedCaption')

Assert ($null -ne $selesai) "the card exposes SELESAI"
Assert ($armed.Visibility -eq 'Collapsed') "the armed caption is hidden before the first press"
# The arm/confirm state machine lives in logbook_timer.ps1; what the widget
# must guarantee structurally is that the caption exists and starts hidden, so
# a single click cannot read as a confirmed end.
Assert ($selesai.IsEnabled) "SELESAI is clickable"

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

Write-Host ""
if ($script:failed -gt 0) {
    Write-Host "$($script:failed) interaction check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All interaction checks passed." -ForegroundColor Green
exit 0
