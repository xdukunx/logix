# MindLab Report Logbook common helpers v5.7
$ErrorActionPreference = 'Stop'

$Global:LabDir = 'C:\lab'
$Global:StateDir = Join-Path $env:ProgramData 'MindLabLogbook'
$Global:SessionFile = Join-Path $Global:StateDir 'session.json'
$Global:ErrorLog = Join-Path $Global:LabDir 'logbook_error.log'
$Global:PopupLock = Join-Path $Global:StateDir 'popup.lock'

function Write-LogbookError {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path $Global:LabDir | Out-Null
        "$(Get-Date -Format o) $Message" | Out-File -FilePath $Global:ErrorLog -Append -Encoding UTF8
    } catch {}
}

function Write-LogbookInfo {
    param([string]$Message)
    Write-LogbookError "INFO: $Message"
}

function Ensure-LogbookDirs {
    New-Item -ItemType Directory -Force -Path $Global:LabDir | Out-Null
    New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
}

function Test-AnyDeskInteractiveWindow {
    if ($env:LOGBOOK_FORCE_ANYDESK -eq '1') { return $true }
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -like 'AnyDesk*' -and
            -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
        })
        foreach ($p in $procs) {
            $title = [string]$p.MainWindowTitle
            if ($title -match '(?i)(anydesk|session|connected|remote|incoming|desk)') {
                return $true
            }
        }
    } catch {}
    return $false
}

function Get-LogbookSessionType {
    if (Test-AnyDeskInteractiveWindow) { return @('AnyDesk', 1) }
    return @('Physical', 0)
}

function Get-ProcessByCommandPattern {
    param([string]$Pattern)
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.CommandLine -match $Pattern
        })
    } catch {
        return @()
    }
}

function Stop-LogbookTimers {
    try {
        $procs = Get-ProcessByCommandPattern 'logbook_timer\.ps1'
        foreach ($p in $procs) {
            if ([int]$p.ProcessId -ne [int]$PID) {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
        $pidFile = Join-Path $Global:StateDir 'timer.pid'
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } catch { Write-LogbookError "Stop timers failed: $($_.Exception.Message)" }
}

function Test-LogbookPopupRunning {
    $procs = Get-ProcessByCommandPattern 'logbook_popup\.ps1'
    foreach ($p in $procs) {
        if ([int]$p.ProcessId -ne [int]$PID) { return $true }
    }
    return $false
}

function Start-LogbookTimer {
    param([string]$SessionId = '')
    try {
        Stop-LogbookTimers
        $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_timer.ps1')
        if ($SessionId) { $args += @('-SessionId', $SessionId) }
        $timer = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $args
        $pidFile = Join-Path $Global:StateDir 'timer.pid'
        $timer.Id | Out-File -FilePath $pidFile -Encoding ascii -Force
        return $true
    } catch {
        Write-LogbookError "Timer start failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-LogbookPopup {
    param([switch]$ForceNew, [switch]$TestMode)
    try {
        if (Test-LogbookPopupRunning) { return $true }
        $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\lab\logbook_popup.ps1')
        if ($ForceNew) { $args += '-ForceNew' }
        if ($TestMode) { $args += '-TestMode' }
        # IMPORTANT: do not use -WindowStyle Hidden here. It hides the WPF form too.
        Start-Process powershell.exe -ArgumentList $args | Out-Null
        return $true
    } catch {
        Write-LogbookError "Popup start failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-WSLLogbook {
    param(
        [Parameter(Mandatory=$true)][string]$Event,
        [string]$SessionType = '',
        [int]$AnyDeskDetected = 0,
        [string]$SessionId = '',
        [string]$Nama = '',
        [string]$Nim = '',
        [string]$Tujuan = '',
        [string]$Keterangan = ''
    )
    Ensure-LogbookDirs
    $winUser = "$env:USERDOMAIN\$env:USERNAME"
    $payloadPath = Join-Path $Global:StateDir ("payload-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $wslPayloadPath = '/mnt/c/ProgramData/MindLabLogbook/' + (Split-Path $payloadPath -Leaf)
    $payload = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        event = $Event
        username = $env:USERNAME
        windows_user = $winUser
        hostname = $env:COMPUTERNAME
        session_type = $SessionType
        source = 'windows_wpf'
        session_id = $SessionId
        nama = $Nama
        nim = $Nim
        tujuan = $Tujuan
        keterangan = $Keterangan
        anydesk_detected = $AnyDeskDetected
    }
    try {
        $payload | ConvertTo-Json -Depth 5 | Out-File -FilePath $payloadPath -Encoding UTF8 -Force
        Write-LogbookInfo "WSL payload event=$Event sid=$SessionId nama=$Nama nim=$Nim tujuan=$Tujuan"
        $output = & wsl.exe -u root -e /usr/bin/python3 /opt/software/logix/log_physical.py --json-file $wslPayloadPath 2>&1
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            Write-LogbookError "WSL root log returned exit code $rc for event $Event. Output: $output"
            $output = & wsl.exe -e /usr/bin/python3 /opt/software/logix/log_physical.py --json-file $wslPayloadPath 2>&1
            $rc = $LASTEXITCODE
            if ($rc -ne 0) {
                Write-LogbookError "WSL user log returned exit code $rc for event $Event. Output: $output"
                return $false
            }
        }
        Write-LogbookInfo "WSL log OK event=$Event sid=$SessionId Output: $output"
        return $true
    } catch {
        Write-LogbookError "WSL log error for event ${Event}: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $payloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-LogbookDefaultConfig {
    # Built-in defaults = the original FTMM faculty UI. With no config file
    # present the popup renders exactly as before.
    return @{
        branding = @{
            logoText = 'FTMM'
            logoPath = 'C:\lab\logo.png'
            title    = 'Report Logbook'
            subtitle = 'Computational Workstation'
            colors   = @{ primary = '#073763'; accent = '#741B47'; muted = '#C0C0C0'; text = '#FFFFFF' }
        }
        text = @{
            intro          = 'Isi data penggunaan workstation sebelum memulai sesi.'
            startHint      = 'Waktu mulai akan dicatat saat tombol Mulai sesi ditekan.'
            namaLabel      = 'Nama Pengguna'
            nimLabel       = 'NIM/NIP/NIK'
            accessLabel    = 'Tipe Akses'
            purposeLabel   = 'Tujuan Penggunaan'
            ketLabel       = 'Keterangan Kegiatan'
            submit         = 'Mulai Sesi'
            hint           = 'Mohon isi data dengan benar dan selengkap mungkin, apabila ada error atau kesalahan, segera hubungi admin.'
            hintIncomplete = 'Lengkapi Nama, NIM/ID, tipe akses, tujuan, dan keterangan.'
            hintReady      = 'Siap disimpan. Nama, NIM, tujuan, dan keterangan akan dikirim ke SQLite.'
        }
        accessTypes    = @('Physical', 'AnyDesk')
        purposes       = @('Visualisasi Data', 'Running Data', 'Maintenance')
        requiredFields = @('nama', 'nim', 'access', 'purpose', 'keterangan')
    }
}

function ConvertTo-LogbookHashtable($obj) {
    # JSON -> hashtable/array so config merges and member access stay uniform.
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-LogbookHashtable $p.Value }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return @($obj | ForEach-Object { ConvertTo-LogbookHashtable $_ })
    }
    return $obj
}

function Merge-LogbookConfig($base, $override) {
    # Deep-merge $override into $base. Objects merge key-by-key; arrays/scalars replace.
    if ($null -eq $override) { return $base }
    foreach ($key in @($override.Keys)) {
        if ($base.Contains($key) -and ($base[$key] -is [hashtable]) -and ($override[$key] -is [hashtable])) {
            Merge-LogbookConfig $base[$key] $override[$key]
        } else {
            $base[$key] = $override[$key]
        }
    }
    return $base
}

function Read-LogbookConfigFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content $Path -Raw -Encoding UTF8
        $raw = $raw -replace '^﻿', ''   # tolerate a leading BOM
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ConvertTo-LogbookHashtable ($raw | ConvertFrom-Json)
    } catch {
        Write-LogbookError "Config load failed for ${Path}: $($_.Exception.Message)"
        return $null
    }
}

function Get-LogbookConfig {
    # Cascading: built-in defaults <- machine config <- per-user config.
    $cfg = Get-LogbookDefaultConfig
    $machine = Join-Path $Global:LabDir 'logbook_config.json'
    $perUser = Join-Path (Join-Path $env:APPDATA 'MindLabLogbook') 'logbook_config.json'
    foreach ($path in @($machine, $perUser)) {
        $override = Read-LogbookConfigFile $path
        if ($override) {
            $cfg = Merge-LogbookConfig $cfg $override
            Write-LogbookInfo "Applied config override: $path"
        }
    }
    return $cfg
}

function ConvertTo-LogbookXmlText([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Build-LogbookPopupXaml($cfg) {
    # Render the popup XAML from config. Pure string building (no WPF), so it is
    # unit-testable by parsing the result as [xml].
    $primary = [string]$cfg.branding.colors.primary
    $accent  = [string]$cfg.branding.colors.accent
    $muted   = [string]$cfg.branding.colors.muted
    $text    = [string]$cfg.branding.colors.text
    $overlay = "#B0" + $accent.TrimStart('#')

    $logoText = ConvertTo-LogbookXmlText ([string]$cfg.branding.logoText)
    $title    = ConvertTo-LogbookXmlText ([string]$cfg.branding.title)
    $subtitle = ConvertTo-LogbookXmlText ([string]$cfg.branding.subtitle)
    $tIntro   = ConvertTo-LogbookXmlText ([string]$cfg.text.intro)
    $tStart   = ConvertTo-LogbookXmlText ([string]$cfg.text.startHint)
    $tNama    = ConvertTo-LogbookXmlText ([string]$cfg.text.namaLabel)
    $tNim     = ConvertTo-LogbookXmlText ([string]$cfg.text.nimLabel)
    $tAccess  = ConvertTo-LogbookXmlText ([string]$cfg.text.accessLabel)
    $tPurpose = ConvertTo-LogbookXmlText ([string]$cfg.text.purposeLabel)
    $tKet     = ConvertTo-LogbookXmlText ([string]$cfg.text.ketLabel)
    $tSubmit  = ConvertTo-LogbookXmlText ([string]$cfg.text.submit)
    $tHint    = ConvertTo-LogbookXmlText ([string]$cfg.text.hint)

    $accessItems  = (@($cfg.accessTypes) | ForEach-Object { "                <ComboBoxItem Content=`"$(ConvertTo-LogbookXmlText $_)`" />" }) -join "`r`n"
    $purposeItems = (@($cfg.purposes)    | ForEach-Object { "                <ComboBoxItem Content=`"$(ConvertTo-LogbookXmlText $_)`" />" }) -join "`r`n"

    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="False" Background="$accent"
        FontFamily="Poppins, Montserrat, Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="PrussianBlue" Color="$primary" />
    <SolidColorBrush x:Key="Silver" Color="$muted" />
    <SolidColorBrush x:Key="Pompadour" Color="$accent" />
    <SolidColorBrush x:Key="WhiteBrush" Color="$text" />

    <Style x:Key="LabelTextStyle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Poppins, Montserrat, Segoe UI" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="FontSize" Value="13" />
      <Setter Property="Foreground" Value="$text" />
      <Setter Property="Margin" Value="0,0,0,7" />
    </Style>

    <Style x:Key="InputTextBoxStyle" TargetType="TextBox">
      <Setter Property="Height" Value="44" />
      <Setter Property="Padding" Value="12,8" />
      <Setter Property="FontFamily" Value="Montserrat, Poppins, Segoe UI" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="Medium" />
      <Setter Property="BorderBrush" Value="$muted" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Background" Value="$primary" />
      <Setter Property="Foreground" Value="$text" />
      <Setter Property="CaretBrush" Value="$text" />
      <Setter Property="SelectionBrush" Value="$accent" />
      <Setter Property="SelectionTextBrush" Value="$text" />
    </Style>

    <Style x:Key="ReadableComboBoxItemStyle" TargetType="ComboBoxItem">
      <Setter Property="FontFamily" Value="Poppins, Montserrat, Segoe UI" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Background" Value="$text" />
      <Setter Property="Foreground" Value="$accent" />
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
      <Setter Property="Background" Value="$text" />
      <Setter Property="Foreground" Value="$accent" />
      <Setter Property="BorderBrush" Value="$muted" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="TextElement.Foreground" Value="$accent" />
      <Setter Property="ItemContainerStyle" Value="{StaticResource ReadableComboBoxItemStyle}" />
    </Style>
  </Window.Resources>

  <Grid>
    <Image Name="BgImage" Stretch="Fill" Opacity="0.88">
      <Image.Effect><BlurEffect Radius="24" KernelType="Gaussian" /></Image.Effect>
    </Image>
    <Rectangle Fill="$overlay" />

    <Border Width="790" CornerRadius="18" BorderBrush="$muted" BorderThickness="1" Background="$primary"
            HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True">
      <Border.Effect><DropShadowEffect BlurRadius="32" ShadowDepth="0" Opacity="0.42" Color="$accent" /></Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto" />
          <RowDefinition Height="*" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" CornerRadius="18,18,0,0" Padding="30,22,30,22" BorderBrush="$text" BorderThickness="0,0,0,1">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="330" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <Image Grid.Column="0" Name="LogoImage" Width="260" Height="72" Stretch="Uniform" HorizontalAlignment="Left" VerticalAlignment="Center"
                   SnapsToDevicePixels="True" RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed" />
            <TextBlock Grid.Column="0" Name="LogoText" Text="$logoText" FontFamily="Poppins, Montserrat, Segoe UI Semibold" FontSize="30"
                       FontWeight="SemiBold" Foreground="$text" VerticalAlignment="Center" />
            <StackPanel Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Right">
              <TextBlock Text="$title" FontFamily="Poppins, Montserrat, Segoe UI" FontSize="29" FontWeight="SemiBold"
                         Foreground="$text" HorizontalAlignment="Right" />
              <TextBlock Text="$subtitle" FontFamily="Montserrat, Poppins, Segoe UI" FontSize="14" Foreground="$muted"
                         HorizontalAlignment="Right" Margin="0,2,0,0" />
            </StackPanel>
          </Grid>
        </Border>

        <StackPanel Grid.Row="1" Margin="36,28,36,34">
          <TextBlock Text="$tIntro" FontFamily="Poppins, Montserrat, Segoe UI" FontSize="12.5"
                     FontWeight="SemiBold" Foreground="$text" Margin="0,0,0,7" />
          <TextBlock Name="StartTimeText" Text="$tStart" FontFamily="Montserrat, Poppins, Segoe UI"
                     FontSize="12" Foreground="$muted" Margin="0,0,0,18" />

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="18" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <TextBlock Text="$tNama" Style="{StaticResource LabelTextStyle}" />
              <TextBox Name="NamaBox" Style="{StaticResource InputTextBoxStyle}" Margin="0,0,0,15" />
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="$tNim" Style="{StaticResource LabelTextStyle}" />
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
              <TextBlock Text="$tAccess" Style="{StaticResource LabelTextStyle}" />
              <ComboBox Name="AccessBox" Style="{StaticResource ReadableComboBoxStyle}" IsEditable="True" IsReadOnly="True" Margin="0,0,0,15">
$accessItems
              </ComboBox>
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="$tPurpose" Style="{StaticResource LabelTextStyle}" />
              <ComboBox Name="TujuanBox" Style="{StaticResource ReadableComboBoxStyle}" IsEditable="True" IsReadOnly="True" Margin="0,0,0,15">
$purposeItems
              </ComboBox>
            </StackPanel>
          </Grid>

          <TextBlock Text="$tKet" Style="{StaticResource LabelTextStyle}" />
          <TextBox Name="KetBox" Style="{StaticResource InputTextBoxStyle}" Height="122" Padding="12,10" TextWrapping="Wrap" AcceptsReturn="True"
                   VerticalScrollBarVisibility="Auto" Margin="0,0,0,20" />

          <Grid Margin="0,0,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="18" />
              <ColumnDefinition Width="198" />
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="$primary" CornerRadius="10" Padding="12,9" BorderBrush="$muted" BorderThickness="1">
              <TextBlock Name="HintText" Text="$tHint"
                         FontFamily="Montserrat, Poppins, Segoe UI" FontSize="11.5" FontWeight="SemiBold" Foreground="$muted" TextWrapping="Wrap" />
            </Border>
            <Button Grid.Column="2" Name="SubmitBtn" Height="48" Content="$tSubmit" FontFamily="Poppins, Montserrat, Segoe UI"
                    FontSize="21" FontWeight="Bold" Background="$accent" Foreground="$text" BorderBrush="$muted"
                    BorderThickness="1" IsEnabled="False" Opacity="0.45" />
          </Grid>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
"@
}

function Get-ActiveLogbookSession {
    try {
        if (Test-Path $Global:SessionFile) {
            return (Get-Content $Global:SessionFile -Raw | ConvertFrom-Json)
        }
    } catch { Write-LogbookError "Read active session failed: $($_.Exception.Message)" }
    return $null
}

function Get-ActiveLogbookSessionAgeSeconds {
    $session = Get-ActiveLogbookSession
    if ($null -eq $session -or -not $session.start_time) { return $null }
    try {
        $start = [datetime]$session.start_time
        return [int]((Get-Date) - $start).TotalSeconds
    } catch { return $null }
}

function Close-ActiveLogbookSession {
    param([string]$Reason = 'END')
    Ensure-LogbookDirs
    try {
        if (Test-Path $Global:SessionFile) {
            $session = Get-Content $Global:SessionFile -Raw | ConvertFrom-Json
            [void](Invoke-WSLLogbook -Event $Reason -SessionType $session.session_type -AnyDeskDetected ([int]$session.anydesk_detected) -SessionId $session.session_id -Nama $session.nama -Nim $session.nim -Tujuan $session.tujuan -Keterangan $session.keterangan)
            Remove-Item $Global:SessionFile -Force -ErrorAction SilentlyContinue
            Write-LogbookInfo "Closed active session sid=$($session.session_id) reason=$Reason"
        }
        Stop-LogbookTimers
        return $true
    } catch {
        Write-LogbookError "Close active session failed: $($_.Exception.Message)"
        Stop-LogbookTimers
        return $false
    }
}
