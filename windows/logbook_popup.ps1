param([switch]$TestMode, [switch]$ForceNew, [switch]$STAChild)
$ErrorActionPreference = 'Stop'

# WPF must run in STA. If Task Scheduler/Run launches normal PowerShell, relaunch safely.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    if ($TestMode) { $args += '-TestMode' }
    if ($ForceNew) { $args += '-ForceNew' }
    Start-Process powershell.exe -ArgumentList $args | Out-Null
    exit 0
}

. 'C:\lab\logbook_common.ps1'
Ensure-LogbookDirs
Write-LogbookInfo "Popup launch TestMode=$TestMode ForceNew=$ForceNew"

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
} catch {
    Write-LogbookError "WPF load failed: $($_.Exception.Message)"
    throw
}

# If there is an active session and this is not an explicit new interactive unlock, only restore timer.
# If ForceNew is set, close stale previous session first so the report gets END/Auto Finish + duration.
if ((Test-Path $Global:SessionFile) -and -not $TestMode) {
    $age = Get-ActiveLogbookSessionAgeSeconds
    if ($ForceNew -and ($null -eq $age -or $age -gt 5)) {
        Close-ActiveLogbookSession -Reason 'AUTO_FINISH' | Out-Null
    } else {
        $active = Get-ActiveLogbookSession
        if ($active -and $active.session_id) { Start-LogbookTimer -SessionId $active.session_id | Out-Null }
        exit 0
    }
}

function New-BlurredBackgroundImage {
    try {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bmp.Size)
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
        $ms.Position = 0
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $img.StreamSource = $ms
        $img.EndInit()
        $img.Freeze()
        $ms.Dispose()
        return $img
    } catch {
        Write-LogbookError "Screenshot blur background failed: $($_.Exception.Message)"
        return $null
    }
}

$sessionInfo = Get-LogbookSessionType
$detectedSessionType = [string]$sessionInfo[0]
$detectedAnyDesk = [int]$sessionInfo[1]
$sessionId = "win-$($env:USERNAME)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$profileFile = Join-Path $Global:StateDir 'last_profile.json'

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="False" Background="#741B47"
        FontFamily="Poppins, Montserrat, Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="PrussianBlue" Color="#073763" />
    <SolidColorBrush x:Key="Silver" Color="#C0C0C0" />
    <SolidColorBrush x:Key="Pompadour" Color="#741B47" />
    <SolidColorBrush x:Key="WhiteBrush" Color="#FFFFFF" />

    <Style x:Key="LabelTextStyle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Poppins, Montserrat, Segoe UI" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="FontSize" Value="13" />
      <Setter Property="Foreground" Value="#FFFFFF" />
      <Setter Property="Margin" Value="0,0,0,7" />
    </Style>

    <Style x:Key="InputTextBoxStyle" TargetType="TextBox">
      <Setter Property="Height" Value="44" />
      <Setter Property="Padding" Value="12,8" />
      <Setter Property="FontFamily" Value="Montserrat, Poppins, Segoe UI" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="Medium" />
      <Setter Property="BorderBrush" Value="#C0C0C0" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Background" Value="#073763" />
      <Setter Property="Foreground" Value="#FFFFFF" />
      <Setter Property="CaretBrush" Value="#FFFFFF" />
      <Setter Property="SelectionBrush" Value="#741B47" />
      <Setter Property="SelectionTextBrush" Value="#FFFFFF" />
    </Style>

    <Style x:Key="ReadableComboBoxItemStyle" TargetType="ComboBoxItem">
      <Setter Property="FontFamily" Value="Poppins, Montserrat, Segoe UI" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Background" Value="#FFFFFF" />
      <Setter Property="Foreground" Value="#741B47" />
      <Setter Property="Padding" Value="10,7" />
      <Setter Property="MinHeight" Value="36" />
      <Setter Property="BorderBrush" Value="#E6E6E6" />
      <Setter Property="BorderThickness" Value="0,0,0,1" />
    </Style>

    <Style x:Key="ReadableComboBoxStyle" TargetType="ComboBox">
      <Setter Property="Height" Value="44" />
      <Setter Property="Padding" Value="8,6" />
      <Setter Property="FontFamily" Value="Poppins, Montserrat, Segoe UI" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Background" Value="#FFFFFF" />
      <Setter Property="Foreground" Value="#741B47" />
      <Setter Property="BorderBrush" Value="#C0C0C0" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="TextElement.Foreground" Value="#741B47" />
      <Setter Property="ItemContainerStyle" Value="{StaticResource ReadableComboBoxItemStyle}" />
    </Style>
  </Window.Resources>

  <Grid>
    <Image Name="BgImage" Stretch="Fill" Opacity="0.88">
      <Image.Effect><BlurEffect Radius="24" KernelType="Gaussian" /></Image.Effect>
    </Image>
    <Rectangle Fill="#B0741B47" />

    <Border Width="790" CornerRadius="18" BorderBrush="#C0C0C0" BorderThickness="1" Background="#073763"
            HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True">
      <Border.Effect><DropShadowEffect BlurRadius="32" ShadowDepth="0" Opacity="0.42" Color="#741B47" /></Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto" />
          <RowDefinition Height="*" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" CornerRadius="18,18,0,0" Padding="30,22,30,22" BorderBrush="#FFFFFF" BorderThickness="0,0,0,1">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="330" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <Image Grid.Column="0" Name="LogoImage" Width="260" Height="72" Stretch="Uniform" HorizontalAlignment="Left" VerticalAlignment="Center"
                   SnapsToDevicePixels="True" RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed" />
            <TextBlock Grid.Column="0" Name="LogoText" Text="FTMM" FontFamily="Poppins, Montserrat, Segoe UI Semibold" FontSize="30"
                       FontWeight="SemiBold" Foreground="#FFFFFF" VerticalAlignment="Center" />
            <StackPanel Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Right">
              <TextBlock Text="Report Logbook" FontFamily="Poppins, Montserrat, Segoe UI" FontSize="29" FontWeight="SemiBold"
                         Foreground="#FFFFFF" HorizontalAlignment="Right" />
              <TextBlock Text="Computational Workstation" FontFamily="Montserrat, Poppins, Segoe UI" FontSize="14" Foreground="#C0C0C0"
                         HorizontalAlignment="Right" Margin="0,2,0,0" />
            </StackPanel>
          </Grid>
        </Border>

        <StackPanel Grid.Row="1" Margin="36,28,36,34">
          <TextBlock Text="Isi data penggunaan workstation sebelum memulai sesi." FontFamily="Poppins, Montserrat, Segoe UI" FontSize="12.5"
                     FontWeight="SemiBold" Foreground="#FFFFFF" Margin="0,0,0,7" />
          <TextBlock Name="StartTimeText" Text="Waktu mulai akan dicatat saat tombol Mulai sesi ditekan." FontFamily="Montserrat, Poppins, Segoe UI"
                     FontSize="12" Foreground="#C0C0C0" Margin="0,0,0,18" />

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="18" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <TextBlock Text="Nama Pengguna" Style="{StaticResource LabelTextStyle}" />
              <TextBox Name="NamaBox" Style="{StaticResource InputTextBoxStyle}" Margin="0,0,0,15" />
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="NIM/NIP/NIK" Style="{StaticResource LabelTextStyle}" />
              <TextBox Name="NimBox" Style="{StaticResource InputTextBoxStyle}" Margin="0,0,0,15" />
            </StackPanel>
          </Grid>

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="230" />
              <ColumnDefinition Width="18" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <TextBlock Text="Tipe Akses" Style="{StaticResource LabelTextStyle}" />
              <ComboBox Name="AccessBox" Style="{StaticResource ReadableComboBoxStyle}" IsEditable="True" IsReadOnly="True" Margin="0,0,0,15">
                <ComboBoxItem Content="Physical" />
                <ComboBoxItem Content="AnyDesk" />
              </ComboBox>
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="Tujuan Penggunaan" Style="{StaticResource LabelTextStyle}" />
              <ComboBox Name="TujuanBox" Style="{StaticResource ReadableComboBoxStyle}" IsEditable="True" IsReadOnly="True" Margin="0,0,0,15">
                <ComboBoxItem Content="Visualisasi Data" />
                <ComboBoxItem Content="Running Data" />
                <ComboBoxItem Content="Maintenance" />
              </ComboBox>
            </StackPanel>
          </Grid>

          <TextBlock Text="Keterangan Kegiatan" Style="{StaticResource LabelTextStyle}" />
          <TextBox Name="KetBox" Style="{StaticResource InputTextBoxStyle}" Height="122" Padding="12,10" TextWrapping="Wrap" AcceptsReturn="True"
                   VerticalScrollBarVisibility="Auto" Margin="0,0,0,20" />

          <Grid Margin="0,0,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="18" />
              <ColumnDefinition Width="198" />
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#073763" CornerRadius="10" Padding="12,9" BorderBrush="#C0C0C0" BorderThickness="1">
              <TextBlock Name="HintText" Text="Mohon isi data dengan benar dan selengkap mungkin, apabila ada error atau kesalahan, segera hubungi admin."
                         FontFamily="Montserrat, Poppins, Segoe UI" FontSize="11.5" FontWeight="SemiBold" Foreground="#C0C0C0" TextWrapping="Wrap" />
            </Border>
            <Button Grid.Column="2" Name="SubmitBtn" Height="48" Content="Mulai Sesi" FontFamily="Poppins, Montserrat, Segoe UI"
                    FontSize="21" FontWeight="Bold" Background="#741B47" Foreground="#FFFFFF" BorderBrush="#C0C0C0"
                    BorderThickness="1" IsEnabled="False" Opacity="0.45" />
          </Grid>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Topmost = $true
$window.Activate() | Out-Null

$bg = New-BlurredBackgroundImage
if ($bg -ne $null) { $window.FindName('BgImage').Source = $bg }
$logoPath = 'C:\lab\logo.png'
if (Test-Path $logoPath) {
    try {
        $logo = New-Object System.Windows.Media.Imaging.BitmapImage
        $logo.BeginInit(); $logo.UriSource = New-Object System.Uri($logoPath); $logo.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $logo.EndInit(); $logo.Freeze()
        $window.FindName('LogoImage').Source = $logo
        $window.FindName('LogoImage').Visibility = 'Visible'
        $window.FindName('LogoText').Visibility = 'Collapsed'
    } catch { Write-LogbookError "Logo load failed: $($_.Exception.Message)" }
}
# SessionBadge existed in the older layout, but the revamped layout removes it.
# Keep this guarded so the popup does not crash when the element is absent.
$sessionBadge = $window.FindName('SessionBadge')
if ($null -ne $sessionBadge) {
    try {
        if ($sessionBadge -is [System.Windows.Controls.ContentControl]) {
            $sessionBadge.Content = "Detected: $detectedSessionType | $env:COMPUTERNAME"
        } else {
            $sessionBadge.Text = "Detected: $detectedSessionType | $env:COMPUTERNAME"
        }
    } catch {
        Write-LogbookError "SessionBadge update skipped: $($_.Exception.Message)"
    }
}
$window.FindName('StartTimeText').Text = "Waktu mulai akan dicatat saat tombol Mulai sesi ditekan."

$nama = $window.FindName('NamaBox')
$nim = $window.FindName('NimBox')
$access = $window.FindName('AccessBox')
$tujuan = $window.FindName('TujuanBox')
$ket = $window.FindName('KetBox')
$btn = $window.FindName('SubmitBtn')

$hint = $window.FindName('HintText')

# Force ComboBox readability. Some WPF themes ignore XAML setters for the
# non-editable selection box and render white text on a white drop-down.
function Set-ComboVisualTreeReadable($root, $fg, $bg) {
    try {
        if ($root -is [System.Windows.Controls.TextBox]) {
            $root.Foreground = $fg
            $root.Background = $bg
            $root.CaretBrush = $fg
        } elseif ($root -is [System.Windows.Controls.TextBlock]) {
            $root.Foreground = $fg
        }
        $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
        for ($i = 0; $i -lt $count; $i++) {
            Set-ComboVisualTreeReadable ([System.Windows.Media.VisualTreeHelper]::GetChild($root, $i)) $fg $bg
        }
    } catch {}
}

function Set-ReadableComboBox($combo) {
    try {
        $brushConverter = New-Object System.Windows.Media.BrushConverter
        $fg = $brushConverter.ConvertFromString('#741B47')
        $bg = $brushConverter.ConvertFromString('#FFFFFF')
        $border = $brushConverter.ConvertFromString('#C0C0C0')
        $combo.IsEnabled = $true
        $combo.Background = $bg
        $combo.Foreground = $fg
        $combo.BorderBrush = $border
        [System.Windows.Documents.TextElement]::SetForeground($combo, $fg)
        foreach ($item in $combo.Items) {
            try {
                $item.Background = $bg
                $item.Foreground = $fg
                [System.Windows.Documents.TextElement]::SetForeground($item, $fg)
            } catch {}
        }
        $combo.ApplyTemplate() | Out-Null
        Set-ComboVisualTreeReadable $combo $fg $bg
        $combo.Add_Loaded({
            param($sender, $eventArgs)
            try {
                $bc = New-Object System.Windows.Media.BrushConverter
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString('#741B47')) ($bc.ConvertFromString('#FFFFFF'))
            } catch {}
        })
        $combo.Add_DropDownOpened({
            param($sender, $eventArgs)
            try {
                $bc = New-Object System.Windows.Media.BrushConverter
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString('#741B47')) ($bc.ConvertFromString('#FFFFFF'))
            } catch {}
        })
        $combo.Add_DropDownClosed({
            param($sender, $eventArgs)
            try {
                $bc = New-Object System.Windows.Media.BrushConverter
                Set-ComboVisualTreeReadable $sender ($bc.ConvertFromString('#741B47')) ($bc.ConvertFromString('#FFFFFF'))
            } catch {}
        })
    } catch {
        Write-LogbookError "Combo readable patch failed: $($_.Exception.Message)"
    }
}
Set-ReadableComboBox $access
Set-ReadableComboBox $tujuan
$script:submitted = $false

if ($detectedSessionType -eq 'AnyDesk') { $access.SelectedIndex = 1 } else { $access.SelectedIndex = 0 }
$tujuan.SelectedIndex = 0
try {
    if (Test-Path $profileFile) {
        $last = Get-Content $profileFile -Raw | ConvertFrom-Json
        if ($last.nama) { $nama.Text = [string]$last.nama }
        if ($last.nim) { $nim.Text = [string]$last.nim }
        $allowedPurpose = @('Visualisasi Data','Running Data','Maintenance')
        if ($last.tujuan -and ($allowedPurpose -contains ([string]$last.tujuan))) {
            for ($i = 0; $i -lt $tujuan.Items.Count; $i++) {
                if ([string]$tujuan.Items[$i].Content -eq [string]$last.tujuan) { $tujuan.SelectedIndex = $i; break }
            }
        }
    }
} catch { Write-LogbookError "Profile prefill failed: $($_.Exception.Message)" }

function Get-ComboText($combo) {
    $txt = ''
    try { $txt = [string]$combo.Text } catch {}
    if (-not [string]::IsNullOrWhiteSpace($txt)) { return $txt }
    try {
        if ($combo.SelectedItem -and $combo.SelectedItem.Content) { return [string]$combo.SelectedItem.Content }
    } catch {}
    return ''
}

$validate = {
    $purpose = Get-ComboText $tujuan
    $atype = Get-ComboText $access
    $ok = -not [string]::IsNullOrWhiteSpace($nama.Text) -and
          -not [string]::IsNullOrWhiteSpace($nim.Text) -and
          -not [string]::IsNullOrWhiteSpace($atype) -and
          -not [string]::IsNullOrWhiteSpace($purpose) -and
          -not [string]::IsNullOrWhiteSpace($ket.Text)
    $btn.IsEnabled = $ok
    if ($ok) {
        $btn.Opacity = 1.0
        $hint.Text = 'Siap disimpan. Nama, NIM, tujuan, dan keterangan akan dikirim ke SQLite.'
    } else {
        $btn.Opacity = 0.45
        $hint.Text = 'Lengkapi Nama, NIM/ID, tipe akses, tujuan, dan keterangan.'
    }
}
@($nama,$nim,$ket) | ForEach-Object { $_.Add_TextChanged($validate) }
$tujuan.Add_TextInput($validate)
$tujuan.Add_KeyUp($validate)
$tujuan.Add_SelectionChanged($validate)
$tujuan.Add_DropDownClosed($validate)
$access.Add_SelectionChanged($validate)
& $validate

$window.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape' -or (($e.SystemKey -eq 'F4') -and (($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0))) {
        $e.Handled = $true
    }
})
$window.Add_Closing({ param($sender, $e) if (-not $script:submitted) { $e.Cancel = $true } })

$btn.Add_Click({
    try {
        Ensure-LogbookDirs
        $btn.IsEnabled = $false
        $btn.Content = 'Menyimpan...'
        $purpose = (Get-ComboText $tujuan).Trim()
        $sessionType = (Get-ComboText $access).Trim()
        $sessionId = "win-$env:USERNAME-$([DateTimeOffset]::Now.ToUnixTimeSeconds())-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $anydeskDetected = $(if ($sessionType -eq 'AnyDesk') { 1 } else { 0 })
        $startTime = Get-Date
        $obj = [ordered]@{
            session_id = $sessionId
            start_time = $startTime.ToString('o')
            session_type = $sessionType
            anydesk_detected = $anydeskDetected
            username = $env:USERNAME
            windows_user = "$env:USERDOMAIN\$env:USERNAME"
            hostname = $env:COMPUTERNAME
            nama = $nama.Text.Trim()
            nim = $nim.Text.Trim()
            tujuan = $purpose
            keterangan = $ket.Text.Trim()
        }
        $obj | ConvertTo-Json -Depth 4 | Out-File -FilePath $Global:SessionFile -Encoding UTF8 -Force
        ([ordered]@{ nama=$obj.nama; nim=$obj.nim; tujuan=$obj.tujuan } | ConvertTo-Json -Depth 3) | Out-File -FilePath $profileFile -Encoding UTF8 -Force

        $logged = Invoke-WSLLogbook -Event 'START' -SessionType $sessionType -AnyDeskDetected $anydeskDetected -SessionId $sessionId -Nama $obj.nama -Nim $obj.nim -Tujuan $obj.tujuan -Keterangan $obj.keterangan
        if (-not $logged) {
            Write-LogbookError "START logging failed but form will continue to close safely. sid=$sessionId"
        }

        Start-LogbookTimer -SessionId $sessionId | Out-Null
        $script:submitted = $true
        $window.Close()
    } catch {
        Write-LogbookError "Submit failed but form released: $($_.Exception.Message)"
        $script:submitted = $true
        try { $window.Close() } catch {}
    } finally {
        try { $btn.Content = 'Mulai sesi'; $btn.IsEnabled = $true } catch {}
    }
})

$nama.Focus() | Out-Null
[void]$window.ShowDialog()
