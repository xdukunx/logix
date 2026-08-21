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
if ([string]::IsNullOrWhiteSpace($privacyMode)) { $privacyMode = 'local_only' }

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Logix Workstation Setup" Height="590" Width="480"
        WindowStartupLocation="CenterScreen" Background="#070C15" ResizeMode="NoResize"
        FontFamily="Segoe UI, Tahoma, Geneva, Verdana, sans-serif">
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header Title -->
    <StackPanel Grid.Row="0" Margin="0,0,0,24">
      <TextBlock Text="LOGIX WORKSTATION SETUP" FontSize="18" FontWeight="Bold" Foreground="#2563EB" LetterSpacing="1"/>
      <TextBlock Text="Hubungkan workstation ini ke server administrasi pusat." FontSize="11" Foreground="#93A1B8" Margin="0,4,0,0"/>
    </StackPanel>

    <!-- Inputs -->
    <StackPanel Grid.Row="1" Margin="0,0,0,16">
      <TextBlock Text="NAMA DEVICE (TAMPIL DI DASHBOARD ADMIN)" FontSize="10" FontWeight="SemiBold" Foreground="#93A1B8" Margin="0,0,0,6"/>
      <TextBox Name="DeviceNameBox" Height="36" Padding="8,4" Background="#0E1626" Foreground="#EEF3FB" BorderBrush="#223451" BorderThickness="1" VerticalContentAlignment="Center" FontSize="13"/>

      <TextBlock Text="URL SERVER ADMINISTRASI" FontSize="10" FontWeight="SemiBold" Foreground="#93A1B8" Margin="0,16,0,6"/>
      <TextBox Name="ServerUrlBox" Height="36" Padding="8,4" Background="#0E1626" Foreground="#EEF3FB" BorderBrush="#223451" BorderThickness="1" VerticalContentAlignment="Center" FontSize="13"/>

      <TextBlock Text="API KEY SERVER (OPSIONAL)" FontSize="10" FontWeight="SemiBold" Foreground="#93A1B8" Margin="0,16,0,6"/>
      <TextBox Name="ApiKeyBox" Height="36" Padding="8,4" Background="#0E1626" Foreground="#EEF3FB" BorderBrush="#223451" BorderThickness="1" VerticalContentAlignment="Center" FontSize="13"/>

      <TextBlock Text="KODE ENROLLMENT (OPSIONAL, DARI ADMIN)" FontSize="10" FontWeight="SemiBold" Foreground="#93A1B8" Margin="0,16,0,6"/>
      <TextBox Name="EnrollCodeBox" Height="36" Padding="8,4" Background="#0E1626" Foreground="#EEF3FB" BorderBrush="#223451" BorderThickness="1" VerticalContentAlignment="Center" FontSize="13"/>
      <TextBlock Text="Jika diisi, device ini akan didaftarkan otomatis dan mendapat API key sendiri (menggantikan API Key Server di atas)." FontSize="10" Foreground="#93A1B8" Margin="0,4,0,0" TextWrapping="Wrap"/>

      <TextBlock Text="MODE PRIVASI" FontSize="10" FontWeight="SemiBold" Foreground="#93A1B8" Margin="0,16,0,6"/>
      <ComboBox Name="PrivacyModeBox" Height="36" Padding="8,4" Background="#0E1626" Foreground="#EEF3FB" BorderBrush="#223451" BorderThickness="1" VerticalContentAlignment="Center" FontSize="13">
        <ComboBoxItem Content="local_only" Tag="Tidak ada data yang meninggalkan device ini. Paling privat (default)."/>
        <ComboBoxItem Content="redacted_sync" Tag="Hanya jam terpakai per pengguna (tersamarkan) yang dikirim -- tanpa nama, ID, atau IP. Via GSheet sync."/>
        <ComboBoxItem Content="admin_full_sync" Tag="Data sesi lengkap dikirim ke server pusat. Pengguna harus diberi tahu."/>
      </ComboBox>
      <TextBlock Name="PrivacyModeHint" FontSize="10" Foreground="#93A1B8" Margin="0,4,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <!-- Status Report Area -->
    <Border Grid.Row="2" Background="#0E1626" BorderBrush="#223451" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,0,16">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <TextBlock Name="StatusText" Text="Siap mengonfigurasi. Masukkan URL server dan klik 'Uji Koneksi' untuk memverifikasi." TextWrapping="Wrap" FontSize="12" Foreground="#93A1B8"/>
      </ScrollViewer>
    </Border>

    <!-- Footer Actions -->
    <Grid Grid.Row="3">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      
      <Button Name="TestBtn" Grid.Column="0" Content="Uji Koneksi" Height="36" Width="120" HorizontalAlignment="Left" Background="#0E1626" Foreground="#EEF3FB" BorderBrush="#223451" BorderThickness="1" FontWeight="SemiBold" Cursor="Hand"/>
      
      <Button Name="SaveBtn" Grid.Column="1" Content="Simpan &amp; Selesai" Height="36" Width="140" Margin="0,0,10,0" Background="#2563EB" Foreground="#ffffff" BorderBrush="Transparent" FontWeight="Bold" Cursor="Hand"/>
      <Button Name="CancelBtn" Grid.Column="2" Content="Batal" Height="36" Width="80" Background="#223451" Foreground="#EEF3FB" BorderBrush="Transparent" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </Grid>
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

# Prefill Values
$nameBox.Text = $deviceName
$urlBox.Text = $serverUrl
$keyBox.Text = $serverKey
$selectedPrivacyItem = $privacyModeBox.Items | Where-Object { $_.Content -eq $privacyMode } | Select-Object -First 1
if ($selectedPrivacyItem) { $privacyModeBox.SelectedItem = $selectedPrivacyItem } else { $privacyModeBox.SelectedIndex = 0 }
$privacyModeHint.Text = $privacyModeBox.SelectedItem.Tag
$privacyModeBox.Add_SelectionChanged({
    if ($privacyModeBox.SelectedItem) { $privacyModeHint.Text = $privacyModeBox.SelectedItem.Tag }
})

# Link Test Connection Click
$testBtn.Add_Click({
    $statusText.Text = "Menghubungi server..."
    $statusText.Foreground = [System.Windows.Media.Brushes]::Yellow
    $window.UpdateLayout()
    
    $url = $urlBox.Text.Trim()
    $key = $keyBox.Text.Trim()
    
    if (-not $url) {
        $statusText.Text = "Error: URL Server tidak boleh kosong."
        $statusText.Foreground = [System.Windows.Media.Brushes]::Red
        return
    }
    
    try {
        $headers = @{}
        if ($key) { $headers['X-API-Key'] = $key }
        $apiUrl = $url.TrimEnd('/') + '/api/config'
        
        $res = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 5 -UseBasicParsing
        if ($res -and $res.branding) {
            $statusText.Text = "Koneksi berhasil!`nJudul Branding: $($res.branding.title)`nTipe Akses: $(($res.accessTypes -join ', '))"
            $statusText.Foreground = [System.Windows.Media.Brushes]::LightGreen
        } else {
            $statusText.Text = "Koneksi berhasil tetapi format config salah."
            $statusText.Foreground = [System.Windows.Media.Brushes]::Orange
        }
    } catch {
        $statusText.Text = "Koneksi Gagal: $($_.Exception.Message)"
        $statusText.Foreground = [System.Windows.Media.Brushes]::Tomato
    }
})

# Link Save Button Click
$saveBtn.Add_Click({
    $name = $nameBox.Text.Trim()
    $url = $urlBox.Text.Trim()
    $key = $keyBox.Text.Trim()
    $enrollCode = $enrollCodeBox.Text.Trim()
    $privacy = if ($privacyModeBox.SelectedItem) { [string]$privacyModeBox.SelectedItem.Content } else { 'local_only' }

    # Device name is required (defaults to the hostname, so this only fires
    # if the user deliberately clears it) - it's how this workstation shows
    # up on the admin dashboard, with or without a server configured yet.
    if (-not $name) {
        $statusText.Text = "Error: Nama Device tidak boleh kosong."
        $statusText.Foreground = [System.Windows.Media.Brushes]::Red
        return
    }

    # If an enrollment code was given, redeem it first. Its device_id/api_key
    # go to device.json (per API_CONTRACT.md), not into config.env - the
    # per-device key must survive independently of this wizard running again.
    if ($enrollCode) {
        if (-not $url) {
            $statusText.Text = "Error: URL Server wajib diisi untuk enrollment."
            $statusText.Foreground = [System.Windows.Media.Brushes]::Red
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

            $identityPath = 'C:\ProgramData\Logix\device.json'
            $identityParent = Split-Path $identityPath
            if (-not (Test-Path $identityParent)) {
                New-Item -ItemType Directory -Force -Path $identityParent | Out-Null
            }
            @{ device_id = $enrolled.device_id; api_key = $enrolled.api_key; category = $enrolled.category } | ConvertTo-Json | Out-File -FilePath $identityPath -Encoding UTF8 -Force
        } catch {
            $statusText.Text = "Enrollment gagal: $($_.Exception.Message)"
            $statusText.Foreground = [System.Windows.Media.Brushes]::Tomato
            return
        }
    }

    try {
        $cfgPath = 'C:\ProgramData\Logix\config.env'
        $newLines = @()
        $hasName = $false
        $hasUrl = $false
        $hasKey = $false
        $hasPrivacy = $false

        if (Test-Path $cfgPath) {
            $lines = Get-Content $cfgPath
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed.StartsWith('LOGIX_DEVICE_NAME=') -or $trimmed.StartsWith('export LOGIX_DEVICE_NAME=')) {
                    $newLines += "LOGIX_DEVICE_NAME=$name"
                    $hasName = $true
                } elseif ($trimmed.StartsWith('LOGIX_SERVER_URL=') -or $trimmed.StartsWith('export LOGIX_SERVER_URL=')) {
                    $newLines += "LOGIX_SERVER_URL=$url"
                    $hasUrl = $true
                } elseif ($trimmed.StartsWith('LOGIX_SERVER_API_KEY=') -or $trimmed.StartsWith('export LOGIX_SERVER_API_KEY=')) {
                    $newLines += "LOGIX_SERVER_API_KEY=$key"
                    $hasKey = $true
                } elseif ($trimmed.StartsWith('LOGIX_PRIVACY_MODE=') -or $trimmed.StartsWith('export LOGIX_PRIVACY_MODE=')) {
                    $newLines += "LOGIX_PRIVACY_MODE=$privacy"
                    $hasPrivacy = $true
                } else {
                    $newLines += $line
                }
            }
        }

        if (-not $hasName) { $newLines += "LOGIX_DEVICE_NAME=$name" }
        if (-not $hasUrl) { $newLines += "LOGIX_SERVER_URL=$url" }
        if (-not $hasKey) { $newLines += "LOGIX_SERVER_API_KEY=$key" }
        if (-not $hasPrivacy) { $newLines += "LOGIX_PRIVACY_MODE=$privacy" }

        $parent = Split-Path $cfgPath
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }

        $newLines | Out-File -FilePath $cfgPath -Encoding UTF8 -Force
        $window.Close()
    } catch {
        $statusText.Text = "Gagal menyimpan: $($_.Exception.Message)"
        $statusText.Foreground = [System.Windows.Media.Brushes]::Tomato
    }
})

# Link Cancel Button Click
$cancelBtn.Add_Click({
    $window.Close()
})

$window.ShowDialog() | Out-Null
