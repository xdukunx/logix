param([string]$SessionId = '', [switch]$STAChild)
$ErrorActionPreference = 'Stop'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    if ($SessionId) { $args += @('-SessionId', $SessionId) }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $args | Out-Null
    exit 0
}
. 'C:\lab\logbook_common.ps1'
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
$clockMain = $window.FindName('ClockMain')
$clockSeconds = $window.FindName('ClockSeconds')
$pulse = $window.FindName('Pulse')
$messageStrip = $window.FindName('MessageStrip')
$messageText = $window.FindName('MessageText')

$script:allowClose = $false
$script:tick = 0
$script:messageHideAtTick = -1
$window.Add_Closing({ param($s,$e) if (-not $script:allowClose) { $e.Cancel = $true } })
$window.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'F4') { $e.Handled = $true } })
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })

$msgPath = Join-Path $Global:StateDir 'incoming_message.json'

# Reason -> accent color for the message strip's left border. Emergency
# always reads as urgent red regardless of the faculty's chosen brand
# accent; anything else (Direction Message and future reasons) uses the
# configured accent color instead.
function Get-LogbookMessageBorderColor([string]$Reason, $Cfg) {
    if ($Reason -eq 'Emergency Alert') { return '#EF4444' }
    return [string]$Cfg.branding.colors.accent
}

# Show a message that arrived just before this window existed (e.g. sent a
# moment before the timer finished launching) instead of silently dropping
# it -- only within a short grace window, so a stale leftover file from a
# crashed prior session doesn't resurface hours later.
function Show-LogbookPendingMessage {
    if (-not (Test-Path $msgPath)) { return }
    try {
        $msg = Get-Content $msgPath -Raw | ConvertFrom-Json
        $receivedAt = [datetime]$msg.received_at
        if (((Get-Date) - $receivedAt).TotalMinutes -gt 5) {
            Remove-Item $msgPath -Force -ErrorAction SilentlyContinue
            return
        }
        $messageText.Text = [string]$msg.text
        $messageStrip.BorderBrush = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString((Get-LogbookMessageBorderColor $msg.reason $cfg))
        )
        $messageStrip.Visibility = 'Visible'
        $script:messageHideAtTick = $script:tick + 20
    } catch {
        Write-LogbookError "Timer: failed to show pending message: $($_.Exception.Message)"
    } finally {
        Remove-Item $msgPath -Force -ErrorAction SilentlyContinue
    }
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
    if (($script:tick % 2) -eq 0) { $pulse.Text = [char]0x25CF } else { $pulse.Text = [char]0x25CB }

    Show-LogbookPendingMessage

    if ($script:messageHideAtTick -ge 0 -and $script:tick -ge $script:messageHideAtTick) {
        $messageStrip.Visibility = 'Collapsed'
        $script:messageHideAtTick = -1
    }
})

# A message sent just before this process finished launching would
# otherwise be missed until the first tick a second later -- check once
# immediately too.
Show-LogbookPendingMessage
$timer.Start()
[void]$window.ShowDialog()
