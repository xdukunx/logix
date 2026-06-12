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

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="286" Height="92" WindowStyle="None" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" AllowsTransparency="True" Background="Transparent" Left="18" Top="18">
  <Border CornerRadius="18" BorderBrush="#C0C0C0" BorderThickness="1" Padding="14,10">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#073763" Offset="0" />
        <GradientStop Color="#741B47" Offset="1" />
      </LinearGradientBrush>
    </Border.Background>
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.42" Color="#741B47" /></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBlock Name="Pulse" Text="●" FontFamily="Segoe UI" FontSize="12" Foreground="#C0C0C0" Margin="0,1,7,0" />
        <TextBlock Name="Label" Grid.Column="1" Text="Physical | User" FontFamily="Segoe UI Semibold" FontSize="12" Foreground="#FFFFFF" />
      </Grid>
      <TextBlock Name="Clock" Grid.Row="1" Text="00:00:00" FontFamily="Consolas" FontSize="32" Foreground="#FFFFFF" Margin="0,2,0,0" />
    </Grid>
  </Border>
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$clock = $window.FindName('Clock')
$label = $window.FindName('Label')
$pulse = $window.FindName('Pulse')
$label.Text = "$($session.session_type) | $($session.nama)"

$script:allowClose = $false
$script:tick = 0
$window.Add_Closing({ param($s,$e) if (-not $script:allowClose) { $e.Cancel = $true } })
$window.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'F4') { $e.Handled = $true } })
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })

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
    $clock.Text = ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds)
    $script:tick += 1
    if (($script:tick % 2) -eq 0) { $pulse.Text = '●' } else { $pulse.Text = '○' }
})
$timer.Start()
[void]$window.ShowDialog()
