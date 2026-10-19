param([switch]$STAChild)
$ErrorActionPreference = 'Stop'

# Common loaded before the STA shim so the relaunch can use
# Start-HiddenPowerShell -- see the shim comment in logbook_popup.ps1.
. 'C:\Program Files\Logix\logbook_common.ps1'

# WPF must run in STA mode. If Task Scheduler or another launch is non-STA, relaunch safely.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    Start-HiddenPowerShell -ArgumentList $args | Out-Null
    exit 0
}

Ensure-LogbookDirs

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
} catch {
    Write-Error "Presentation framework load failed: $($_.Exception.Message)"
    exit 1
}

# Fetch existing config options to prefill the textboxes
$deviceName = Get-LogbookConfigEnv -Key 'LOGIX_DEVICE_NAME'
if ([string]::IsNullOrWhiteSpace($deviceName)) { $deviceName = $env:COMPUTERNAME }
$serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
$serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY'
$privacyMode = Get-LogbookConfigEnv -Key 'LOGIX_PRIVACY_MODE'
# Nothing chosen yet on a fresh machine: preselect sending, same as the
# "Koneksi Server" checkbox -- this screen exists to join a lab server. A
# machine that already has a server URL but no mode really IS local_only
# (paths.py's default), so show that truthfully instead.
if ([string]::IsNullOrWhiteSpace($privacyMode)) {
    $privacyMode = if ($serverUrl) { 'local_only' } else { 'admin_full_sync' }
}

$cfg = Get-LogbookConfig -MaxCacheAgeSeconds 86400
$res = Build-LogbookClientResources $cfg
$brand = Build-LogbookBrandMarkXaml ([string]$cfg.branding.logoText)
$font = $Global:LxFontFamily

# Same card, type and controls as "Koneksi Server" (logix_server.ps1), so the
# first Logix window an operator ever sees already looks like the dashboard.
# Field labels are sentence case on purpose; the old all-caps labels used a
# LetterSpacing property WPF does not have, and the window never opened.
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Logix Workstation Setup" Width="476" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" FontFamily="$font">
  <Window.Resources>
$res
    <Style x:Key="SetupLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource LxMuted}"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="SetupField" TargetType="Border">
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Background" Value="{StaticResource LxSurface}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LxHairline}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="SetupBox" TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="{StaticResource LxText}"/>
      <Setter Property="CaretBrush" Value="{StaticResource LxAccent}"/>
    </Style>
  </Window.Resources>
  <Border CornerRadius="22" Background="{StaticResource LxElevated}" Margin="18"
          BorderBrush="{StaticResource LxHairline}" BorderThickness="1" Padding="28,24,28,22">
    <Border.Effect><DropShadowEffect BlurRadius="48" ShadowDepth="14" Direction="270" Opacity="0.5" Color="#000000"/></Border.Effect>
    <StackPanel>
      <Grid Margin="0,0,0,20">
$brand
        <TextBlock Text="SETUP" FontFamily="Consolas" FontSize="11" Foreground="{StaticResource LxMuted}"
                   HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
      <TextBlock Text="Siapkan workstation" FontSize="22" FontWeight="Bold" Foreground="{StaticResource LxText}"/>
      <TextBlock Text="Beri nama PC ini dan hubungkan ke dashboard lab. Semua bisa diubah lagi nanti."
                 FontSize="12.5" TextWrapping="Wrap" Foreground="{StaticResource LxMuted}" Margin="0,4,0,20"/>

      <TextBlock Text="Nama perangkat (tampil di dashboard)" Style="{StaticResource SetupLabel}"/>
      <Border Style="{StaticResource SetupField}"><TextBox Name="DeviceNameBox" Style="{StaticResource SetupBox}"/></Border>

      <TextBlock Text="Alamat server" Style="{StaticResource SetupLabel}"/>
      <Border Style="{StaticResource SetupField}"><TextBox Name="ServerUrlBox" Style="{StaticResource SetupBox}" FontFamily="Consolas"/></Border>

      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="12"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="Kode pairing" Style="{StaticResource SetupLabel}"/>
          <Border Style="{StaticResource SetupField}"><TextBox Name="EnrollCodeBox" Style="{StaticResource SetupBox}" FontFamily="Consolas"/></Border>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="atau API key server" Style="{StaticResource SetupLabel}"/>
          <Border Style="{StaticResource SetupField}"><TextBox Name="ApiKeyBox" Style="{StaticResource SetupBox}" FontFamily="Consolas"/></Border>
        </StackPanel>
      </Grid>
      <TextBlock Text="Kode pairing lebih aman: PC ini mendapat kunci sendiri. API key bersama hanya untuk server lama."
                 FontSize="11" TextWrapping="Wrap" Foreground="{StaticResource LxMuted}" Margin="0,-6,0,16"/>

      <TextBlock Text="Data sesi" Style="{StaticResource SetupLabel}"/>
      <ComboBox Name="PrivacyModeBox" Style="{StaticResource LxCombo}" Height="42">
        <ComboBoxItem Uid="admin_full_sync" Content="Kirim data sesi ke server" Tag="Kirim ke server: nama, NIM, tujuan dan jam sesi muncul di Riwayat admin. Pengguna diberi tahu di layar masuk."/>
        <ComboBoxItem Uid="redacted_sync" Content="Hanya jam pakai, disamarkan" Tag="Hanya jam pakai per pengguna yang disamarkan (tanpa nama, ID atau IP), lewat GSheet sync. Riwayat server tetap kosong."/>
        <ComboBoxItem Uid="local_only" Content="Simpan di PC ini saja" Tag="Tidak ada yang keluar dari PC ini. Server hanya melihat perangkat online; Riwayat admin kosong."/>
      </ComboBox>
      <TextBlock Name="PrivacyModeHint" FontSize="11" TextWrapping="Wrap" LineHeight="16"
                 Foreground="{StaticResource LxMuted}" Margin="0,6,0,16"/>

      <Border CornerRadius="14" Background="{StaticResource LxSurface}" BorderBrush="{StaticResource LxHairline}"
              BorderThickness="1" Padding="14,12" Margin="0,0,0,18">
        <TextBlock Name="StatusText" TextWrapping="Wrap" FontSize="12" LineHeight="17" Foreground="{StaticResource LxMuted}"
                   Text="Isi alamat server, lalu tekan Uji koneksi."/>
      </Border>

      <DockPanel LastChildFill="False">
        <Button Name="SaveBtn" Content="Simpan &amp; selesai" Style="{StaticResource LxPill}" Padding="18,9"
                FontSize="12.5" Background="{StaticResource LxAccent}" BorderBrush="{StaticResource LxAccent}"
                Foreground="{StaticResource LxOnAccent}" Margin="0,0,8,0" DockPanel.Dock="Left"/>
        <Button Name="TestBtn" Content="Uji koneksi" Style="{StaticResource LxPill}" Padding="14,9"
                FontSize="12.5" DockPanel.Dock="Left"/>
        <Button Name="CancelBtn" Content="Batal" Style="{StaticResource LxPill}" Padding="12,9" FontSize="12"
                BorderBrush="Transparent" Foreground="{StaticResource LxMuted}" DockPanel.Dock="Right"/>
      </DockPanel>
    </StackPanel>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Resolve Control Handles
$nameBox = $window.FindName('DeviceNameBox')
$urlBox = $window.FindName('ServerUrlBox')
$keyBox = $window.FindName('ApiKeyBox')
$enrollCodeBox = $window.FindName('EnrollCodeBox')
$privacyModeBox = $window.FindName('PrivacyModeBox')
$privacyModeHint = $window.FindName('PrivacyModeHint')
$statusText = $window.FindName('StatusText')
$testBtn = $window.FindName('TestBtn')
$saveBtn = $window.FindName('SaveBtn')
$cancelBtn = $window.FindName('CancelBtn')

$theme = Get-LogbookTheme $cfg
$brushConv = New-Object System.Windows.Media.BrushConverter
function Set-SetupStatus([string]$Text, [string]$Kind = 'muted') {
    $statusText.Text = $Text
    $colour = switch ($Kind) {
        'ok'    { $theme.signalNormal }
        'warn'  { $theme.signalWarning }
        'error' { $theme.criticalSoft }
        default { $theme.muted }
    }
    $statusText.Foreground = $brushConv.ConvertFromString($colour)
}
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })

# Prefill Values
$nameBox.Text = $deviceName
$urlBox.Text = $serverUrl
$keyBox.Text = $serverKey
$selectedPrivacyItem = $privacyModeBox.Items | Where-Object { $_.Uid -eq $privacyMode } | Select-Object -First 1
if ($selectedPrivacyItem) { $privacyModeBox.SelectedItem = $selectedPrivacyItem } else { $privacyModeBox.SelectedIndex = 0 }
$privacyModeHint.Text = $privacyModeBox.SelectedItem.Tag
$privacyModeBox.Add_SelectionChanged({
    if ($privacyModeBox.SelectedItem) { $privacyModeHint.Text = $privacyModeBox.SelectedItem.Tag }
})

# Link Test Connection Click
$testBtn.Add_Click({
    Set-SetupStatus "Menghubungi server..." 'muted'
    $window.UpdateLayout()
    
    $url = $urlBox.Text.Trim()
    $key = $keyBox.Text.Trim()
    
    if (-not $url) {
        Set-SetupStatus "Isi alamat server dulu." 'error'
        return
    }
    
    try {
        $headers = @{}
        if ($key) { $headers['X-API-Key'] = $key }
        $apiUrl = $url.TrimEnd('/') + '/api/config'
        
        $res = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 5 -UseBasicParsing
        if ($res -and $res.branding) {
            Set-SetupStatus "Server menjawab: $($res.branding.title). Tekan Simpan untuk menyelesaikan." 'ok'
        } else {
            Set-SetupStatus "Ada yang menjawab di alamat itu, tetapi bukan server Logix." 'warn'
        }
    } catch {
        Set-SetupStatus "Server tidak bisa dihubungi: $($_.Exception.Message)" 'error'
    }
})

# Link Save Button Click
$saveBtn.Add_Click({
    $name = $nameBox.Text.Trim()
    $url = $urlBox.Text.Trim()
    $key = $keyBox.Text.Trim()
    $enrollCode = $enrollCodeBox.Text.Trim()
    $privacy = if ($privacyModeBox.SelectedItem) { [string]$privacyModeBox.SelectedItem.Uid } else { 'local_only' }

    # Device name is required (defaults to the hostname, so this only fires
    # if the user deliberately clears it) - it's how this workstation shows
    # up on the admin dashboard, with or without a server configured yet.
    if (-not $name) {
        Set-SetupStatus "Nama perangkat tidak boleh kosong." 'error'
        return
    }

    # If an enrollment code was given, redeem it first. Its device_id/api_key
    # go to device.json (per API_CONTRACT.md), not into config.env - the
    # per-device key must survive independently of this wizard running again.
    if ($enrollCode) {
        if (-not $url) {
            Set-SetupStatus "Kode pairing butuh alamat server." 'error'
            return
        }
        try {
            $enrollUrl = $url.TrimEnd('/') + '/api/enroll'
            # device_name rides along. Without it the server created the
            # registry row under the bare $env:COMPUTERNAME and the name typed
            # into the box above only arrived on a later heartbeat -- so the
            # dashboard showed the default PC name and the typed name as two
            # separate things.
            $body = @{ invite_code = $enrollCode; hostname = $env:COMPUTERNAME; device_name = $name; os = 'windows'; os_version = [System.Environment]::OSVersion.VersionString } | ConvertTo-Json
            $enrolled = Invoke-RestMethod -Uri $enrollUrl -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 -UseBasicParsing

            $identityPath = Get-LogbookDeviceIdentityPath
            $identityParent = Split-Path $identityPath
            if (-not (Test-Path $identityParent)) {
                New-Item -ItemType Directory -Force -Path $identityParent | Out-Null
            }
            @{ device_id = $enrolled.device_id; api_key = $enrolled.api_key; category = $enrolled.category } | ConvertTo-Json | Out-File -FilePath $identityPath -Encoding UTF8 -Force
        } catch {
            Set-SetupStatus "Pairing gagal: $($_.Exception.Message)" 'error'
            return
        }
    }

    try {
        # The shared writer (Set-LogbookConfigValue): same file, same quoting,
        # same LOGIX_HOME resolution as the pairing screen and the installer.
        Set-LogbookConfigValue -Key 'LOGIX_DEVICE_NAME' -Value $name
        Set-LogbookConfigValue -Key 'LOGIX_SERVER_URL' -Value $url
        Set-LogbookConfigValue -Key 'LOGIX_SERVER_API_KEY' -Value $key
        Set-LogbookConfigValue -Key 'LOGIX_PRIVACY_MODE' -Value $privacy
        $window.Close()
    } catch {
        Set-SetupStatus "Gagal menyimpan: $($_.Exception.Message)" 'error'
    }
})

# Link Cancel Button Click
$cancelBtn.Add_Click({
    $window.Close()
})

$window.ShowDialog() | Out-Null
