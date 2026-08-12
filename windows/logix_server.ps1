# Join this device to a Logix Server, or leave one -- from the application.
#
#   powershell -ExecutionPolicy Bypass -File windows\logix_server.ps1
#
# WHY THIS FILE EXISTS
#   Logix Device is meant to be a complete product on its own, with the server
#   as an optional layer. That is only true if a device can be joined to a
#   server AFTER installation, and unjoined from one, by the person using it.
#   Enrolment previously existed only inside the setup wizard -- a thing you
#   run once, at install time -- and leaving a server was not possible at all:
#   it meant hand-editing config.env or reinstalling. Both are answers for a
#   maintainer, not for a user.
#
#   The transport is not new. This drives the same POST /api/enroll and the
#   same device.json this project already specifies in API_CONTRACT.md; the
#   helpers live in logbook_common.ps1 so the setup wizard and this screen
#   cannot drift into two different enrolment paths.
param([switch]$STAChild)
$ErrorActionPreference = 'Stop'

$commonInstalled = 'C:\Program Files\Logix\logbook_common.ps1'
$commonLocal = Join-Path $PSScriptRoot 'logbook_common.ps1'
if (Test-Path $commonInstalled) { . $commonInstalled } else { . $commonLocal }

# WPF needs STA; a shortcut or a scheduled task may not give us one.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $relaunch = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    Start-HiddenPowerShell -ArgumentList $relaunch | Out-Null
    exit 0
}

Ensure-LogbookDirs
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
} catch {
    Write-LogbookError "Server pairing UI failed to load WPF: $($_.Exception.Message)"
    exit 1
}

$cfg = Get-LogbookConfig -MaxCacheAgeSeconds 86400
$state = Get-LogbookPairingState

$window = [Windows.Markup.XamlReader]::Load(
    (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookServerPairingXaml $cfg $state))))

$statusDot   = $window.FindName('StatusDot')
$statusText  = $window.FindName('StatusText')
$deviceIdTxt = $window.FindName('DeviceIdText')
$serverBox   = $window.FindName('ServerBox')
$codeBox     = $window.FindName('CodeBox')
$codeRow     = $window.FindName('CodeRow')
$connectBtn  = $window.FindName('ConnectBtn')
$testBtn     = $window.FindName('TestBtn')
$disconnect  = $window.FindName('DisconnectBtn')
$messageText = $window.FindName('MessageText')
$closeBtn    = $window.FindName('CloseBtn')

$theme = Get-LogbookTheme $cfg
$brush = New-Object System.Windows.Media.BrushConverter

function Set-Message([string]$Text, [string]$Kind = 'muted') {
    $messageText.Text = $Text
    $colour = switch ($Kind) {
        'ok'    { $theme.signalNormal }
        'error' { $theme.criticalSoft }
        default { $theme.muted }
    }
    $messageText.Foreground = $brush.ConvertFromString($colour)
}

function Update-PairingView {
    $script:state = Get-LogbookPairingState
    if ($script:state.Paired) {
        $statusDot.Fill = $brush.ConvertFromString($theme.signalNormal)
        $statusText.Text = 'Terhubung ke server'
        $deviceIdTxt.Text = "ID perangkat: $($script:state.DeviceId)"
        $deviceIdTxt.Visibility = 'Visible'
        # A paired device does not need a pairing code on screen; showing an
        # empty credential field next to a working connection reads as
        # something still being required.
        $codeRow.Visibility = 'Collapsed'
        $connectBtn.Content = 'Hubungkan ulang'
        $disconnect.Visibility = 'Visible'
    } else {
        $statusDot.Fill = $brush.ConvertFromString($theme.muted)
        $statusText.Text = 'Tidak terhubung (mode perangkat saja)'
        $deviceIdTxt.Visibility = 'Collapsed'
        $codeRow.Visibility = 'Visible'
        $connectBtn.Content = 'Hubungkan'
        $disconnect.Visibility = 'Collapsed'
    }
    if ($script:state.ServerUrl -and -not $serverBox.Text) { $serverBox.Text = $script:state.ServerUrl }
}

$testBtn.Add_Click({
    Set-Message 'Menguji koneksi...' 'muted'
    # Synchronous on purpose: this window does nothing else, the call has a
    # short timeout, and a spinner over an 8-second worst case would be more
    # machinery than the wait deserves.
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $r = Test-LogbookServerReachable -Url $serverBox.Text
        Set-Message $r.Detail $(if ($r.Ok) { 'ok' } else { 'error' })
    } finally {
        $window.Cursor = $null
    }
})

$connectBtn.Add_Click({
    # Re-pairing an already-paired device needs a fresh code, so reveal the
    # field rather than silently failing against a server that will refuse.
    if ($script:state.Paired -and $codeRow.Visibility -ne 'Visible') {
        $codeRow.Visibility = 'Visible'
        Set-Message 'Masukkan kode pairing baru dari admin untuk menghubungkan ulang.' 'muted'
        return
    }
    $url = $serverBox.Text
    $code = $codeBox.Text

    Set-Message 'Memeriksa server...' 'muted'
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        # Reachability first: an invite code is single-use, so firing one at a
        # mistyped address burns it and sends the operator back to an admin.
        $reach = Test-LogbookServerReachable -Url $url
        if (-not $reach.Ok) { Set-Message $reach.Detail 'error'; return }

        Set-Message 'Mendaftarkan perangkat...' 'muted'
        $r = Invoke-LogbookServerPairing -Url $url -Code $code
        if ($r.Ok) {
            $codeBox.Text = ''
            Update-PairingView
            $cat = if ($r.Category) { " sebagai $($r.Category)" } else { '' }
            Set-Message "Berhasil terhubung$cat. Sesi berikutnya akan ikut tersinkron ke server." 'ok'
        } else {
            Set-Message $r.Error 'error'
        }
    } finally {
        $window.Cursor = $null
    }
})

$disconnect.Add_Click({
    $answer = [System.Windows.MessageBox]::Show(
        "Putuskan perangkat ini dari server?`n`nRiwayat sesi yang tersimpan di komputer ini TIDAK dihapus, dan Logix tetap mencatat sesi seperti biasa. Untuk menghubungkan lagi Anda perlu kode pairing baru dari admin.",
        'Logix', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $r = Remove-LogbookServerPairing
    Update-PairingView
    if ($r.Ok) {
        Set-Message 'Perangkat sudah tidak terhubung ke server mana pun. Pencatatan lokal tetap berjalan.' 'ok'
    } else {
        Set-Message $r.Error 'error'
    }
})

$closeBtn.Add_Click({ $window.Close() })
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })

Update-PairingView
[void]$window.ShowDialog()
exit 0
