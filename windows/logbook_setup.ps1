param([switch]$STAChild)
$ErrorActionPreference = 'Stop'

# WPF must run in STA mode. If Task Scheduler or another launch is non-STA, relaunch safely.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    Start-Process powershell.exe -ArgumentList $args | Out-Null
    exit 0
}

. 'C:\lab\logbook_common.ps1'
Ensure-LogbookDirs

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
} catch {
    Write-Error "Presentation framework load failed: $($_.Exception.Message)"
    exit 1
}

# Fetch existing config options to prefill the textboxes
$serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
$serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY'

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Logix Workstation Setup" Height="420" Width="480"
        WindowStartupLocation="CenterScreen" Background="#0b0f19" ResizeMode="NoResize"
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
      <TextBlock Text="LOGIX WORKSTATION SETUP" FontSize="18" FontWeight="Bold" Foreground="#3b82f6" LetterSpacing="1"/>
      <TextBlock Text="Hubungkan workstation ini ke server administrasi pusat." FontSize="11" Foreground="#94a3b8" Margin="0,4,0,0"/>
    </StackPanel>

    <!-- Inputs -->
    <StackPanel Grid.Row="1" Margin="0,0,0,16">
      <TextBlock Text="URL SERVER ADMINISTRASI" FontSize="10" FontWeight="SemiBold" Foreground="#64748b" Margin="0,0,0,6"/>
      <TextBox Name="ServerUrlBox" Height="36" Padding="8,4" Background="#161c2d" Foreground="#f1f5f9" BorderBrush="#334155" BorderThickness="1" VerticalContentAlignment="Center" FontSize="13"/>
      
      <TextBlock Text="API KEY SERVER (OPSIONAL)" FontSize="10" FontWeight="SemiBold" Foreground="#64748b" Margin="0,16,0,6"/>
      <TextBox Name="ApiKeyBox" Height="36" Padding="8,4" Background="#161c2d" Foreground="#f1f5f9" BorderBrush="#334155" BorderThickness="1" VerticalContentAlignment="Center" FontSize="13"/>
    </StackPanel>

    <!-- Status Report Area -->
    <Border Grid.Row="2" Background="#161c2d" BorderBrush="#334155" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,0,16">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <TextBlock Name="StatusText" Text="Siap mengonfigurasi. Masukkan URL server dan klik 'Uji Koneksi' untuk memverifikasi." TextWrapping="Wrap" FontSize="12" Foreground="#94a3b8"/>
      </ScrollViewer>
    </Border>

    <!-- Footer Actions -->
    <Grid Grid.Row="3">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      
      <Button Name="TestBtn" Grid.Column="0" Content="Uji Koneksi" Height="36" Width="120" HorizontalAlignment="Left" Background="#1e293b" Foreground="#f1f5f9" BorderBrush="#475569" BorderThickness="1" FontWeight="SemiBold" Cursor="Hand"/>
      
      <Button Name="SaveBtn" Grid.Column="1" Content="Simpan &amp; Selesai" Height="36" Width="140" Margin="0,0,10,0" Background="#3b82f6" Foreground="#ffffff" BorderBrush="Transparent" FontWeight="Bold" Cursor="Hand"/>
      <Button Name="CancelBtn" Grid.Column="2" Content="Batal" Height="36" Width="80" Background="#334155" Foreground="#f1f5f9" BorderBrush="Transparent" FontWeight="SemiBold" Cursor="Hand"/>
    </Grid>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Resolve Control Handles
$urlBox = $window.FindName('ServerUrlBox')
$keyBox = $window.FindName('ApiKeyBox')
$statusText = $window.FindName('StatusText')
$testBtn = $window.FindName('TestBtn')
$saveBtn = $window.FindName('SaveBtn')
$cancelBtn = $window.FindName('CancelBtn')

# Prefill Values
$urlBox.Text = $serverUrl
$keyBox.Text = $serverKey

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
    $url = $urlBox.Text.Trim()
    $key = $keyBox.Text.Trim()
    
    if (-not $url) {
        $statusText.Text = "Error: URL Server tidak boleh kosong."
        $statusText.Foreground = [System.Windows.Media.Brushes]::Red
        return
    }
    
    try {
        $cfgPath = 'C:\ProgramData\Logix\config.env'
        $newLines = @()
        $hasUrl = $false
        $hasKey = $false
        
        if (Test-Path $cfgPath) {
            $lines = Get-Content $cfgPath
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed.StartsWith('LOGIX_SERVER_URL=') -or $trimmed.StartsWith('export LOGIX_SERVER_URL=')) {
                    $newLines += "LOGIX_SERVER_URL=$url"
                    $hasUrl = $true
                } elseif ($trimmed.StartsWith('LOGIX_SERVER_API_KEY=') -or $trimmed.StartsWith('export LOGIX_SERVER_API_KEY=')) {
                    $newLines += "LOGIX_SERVER_API_KEY=$key"
                    $hasKey = $true
                } else {
                    $newLines += $line
                }
            }
        }
        
        if (-not $hasUrl) { $newLines += "LOGIX_SERVER_URL=$url" }
        if (-not $hasKey) { $newLines += "LOGIX_SERVER_API_KEY=$key" }
        
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
