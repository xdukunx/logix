# Safe, non-destructive preview of the sign-in popup straight from this repo
# (not the installed C:\Program Files copy). Use this to eyeball layout/branding
# changes -- e.g. the mascot hero header -- without the real popup's fullscreen
# takeover, always-on-top behaviour, Task Manager gating, or session/timer
# side effects.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\preview_popup.ps1
#
# It opens a normal, resizable, closable window. Close it with the title-bar X.
# This renders the SAME XAML the real agent uses (Build-LogbookPopupXaml), so
# what you see here is what a workstation shows -- minus the lock-down chrome.
param([switch]$STAChild)
$ErrorActionPreference = 'Stop'

# WPF needs STA. Relaunch into an STA host if we're not already in one.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -STAChild
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

. (Join-Path $PSScriptRoot 'logbook_common.ps1')

# Default config, but point the mascot at the repo copy of logo.png (the real
# agent reads C:\Program Files\Logix\logo.png, which the installer lays down).
$cfg = Get-LogbookConfig
$repoLogo = Join-Path $PSScriptRoot 'logo.png'
if (Test-Path $repoLogo) { $cfg.branding.logoPath = $repoLogo }

$xaml = Build-LogbookPopupXaml $cfg
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Inject the mascot exactly like logbook_popup.ps1 does.
$logoPath = [string]$cfg.branding.logoPath
if (Test-Path $logoPath) {
    try {
        $mascot = New-Object System.Windows.Media.Imaging.BitmapImage
        $mascot.BeginInit(); $mascot.UriSource = New-Object System.Uri($logoPath); $mascot.CacheOption = 'OnLoad'; $mascot.EndInit(); $mascot.Freeze()
        $window.FindName('MascotImage').Source = $mascot
        $window.FindName('MascotImage').Visibility = 'Visible'
    } catch { Write-Host "Mascot load failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Tame the lock-down chrome so this is a friendly preview, not a kiosk:
$window.WindowStyle   = 'SingleBorderWindow'   # gives a normal title bar + X
$window.WindowState   = 'Normal'
$window.ResizeMode    = 'CanResize'
$window.Topmost       = $false
$window.ShowInTaskbar = $true
$window.SizeToContent = 'Manual'
$window.Width         = 980
$window.Height        = 940
$window.WindowStartupLocation = 'CenterScreen'
$window.Title = 'Logix sign-in popup - PREVIEW (repo, not installed)'

Write-Host 'Opening popup preview. Close the window (X) when done.' -ForegroundColor Cyan
[void]$window.ShowDialog()
