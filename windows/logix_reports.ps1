# Open this device's own session reports, with no server and no terminal.
#
#   powershell -ExecutionPolicy Bypass -File windows\logix_reports.ps1
#
# WHY THIS FILE EXISTS
#   Reporting has always worked -- as `python logbook_report.py`. That is a
#   sentence you cannot say to the person who actually uses a lab workstation,
#   so in practice the feature existed for whoever maintains Logix and for
#   nobody else. Device mode is meant to be a complete product on its own, and
#   a product does not ask you to open a terminal to see your own history.
#
#   This is the shortcut behind it: find the core, start the local report UI
#   (logix/report_server.py), wait for it to say which URL it is on, and open
#   the browser there. The URL carries a one-time token, which is why the
#   launcher has to read it back rather than guess it.
[CmdletBinding()]
param(
    # 0 lets the OS pick a free port, which is right for a desktop shortcut:
    # a fixed port is one more thing that can already be taken.
    [int]$Port = 0,
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'logbook_common.ps1')

$python = Find-LogixPython
if (-not $python) {
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    $msg = "Python tidak ditemukan di komputer ini, jadi laporan lokal tidak bisa dibuka.`n`n" +
           "Logix tetap mencatat sesi seperti biasa -- hanya tampilan laporannya yang butuh Python."
    try { [System.Windows.Forms.MessageBox]::Show($msg, 'Logix', 'OK', 'Warning') | Out-Null }
    catch { Write-Host $msg }
    exit 1
}

$core = Get-LogixCoreDir
$script = Join-Path $core 'report_server.py'
if (-not (Test-Path $script)) {
    # Dev checkout: the core sits beside this repo rather than in ProgramData.
    $devScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'logix\report_server.py'
    if (Test-Path $devScript) { $script = $devScript }
}
if (-not (Test-Path $script)) {
    Write-LogbookError "report_server.py not found (looked in $core)"
    Write-Host "Laporan lokal belum terpasang di komputer ini." -ForegroundColor Yellow
    exit 1
}

$device = ''
try { $device = Get-LogbookDeviceDisplayName } catch { }

# The URL is learned from a FILE the server writes, not from its stdout.
#
# Reading a child's stdout means holding that pipe open, and this launcher's
# whole job is to fire and forget: the server then runs for as long as someone
# is reading reports. The first version of this file did redirect and read a
# line, and it hung -- a blocking ReadLine cannot be interrupted by a deadline
# check that only runs between reads, so a server that printed nothing (or a
# parent that could not drain the pipe) froze the shortcut outright. A file is
# the same handoff this project already uses for session state and bar status,
# and it is pollable, which a pipe read is not.
Ensure-LogbookDirs
$urlFile = Join-Path $Global:StateDir 'report_url'
Remove-Item $urlFile -Force -ErrorAction SilentlyContinue

# Start-Process does NOT quote arguments containing spaces, not even in the
# array form -- 'C:\Program Files\Logix\report_server.py' would arrive as two
# broken arguments. Quote every path by hand. See ps51-startprocess-quoting.
$argList = @(
    ('"{0}"' -f $script),
    '--no-browser',
    '--port', [string]$Port,
    '--url-file', ('"{0}"' -f $urlFile)
)
if ($device) { $argList += @('--device', ('"{0}"' -f $device)) }
$proc = Start-Process -FilePath $python -ArgumentList $argList `
            -WindowStyle Hidden -PassThru

# Poll rather than block: this loop can give up, which is the entire point.
$url = ''
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $urlFile) {
        $candidate = (Get-Content $urlFile -Raw -ErrorAction SilentlyContinue)
        if ($candidate -and $candidate -match 'https?://\S+') { $url = $Matches[0]; break }
    }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 150
}

if (-not $url) {
    Write-LogbookError "Local report UI did not start (no URL after 20s; python exited=$($proc.HasExited))"
    Write-Host "Laporan lokal gagal dibuka. Detail ada di log Logix." -ForegroundColor Red
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    exit 1
}

Write-LogbookInfo "Local report UI started at $($url -replace '\?t=.*', '?t=<redacted>')"
Write-Host $url

if (-not $NoBrowser) { Start-Process $url | Out-Null }

# Deliberately NOT waiting on the process: the shortcut should return
# immediately, and report_server.py shuts itself down once nobody is looking at
# it (see IDLE_SHUTDOWN_SECONDS) so a forgotten tab does not leave an endpoint
# serving names and student IDs for the rest of the day.
exit 0
