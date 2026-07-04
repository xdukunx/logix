Set-ExecutionPolicy -Scope Process Bypass -Force
. (Join-Path $PSScriptRoot 'logbook_common.ps1')
Ensure-LogbookDirs
Close-ActiveLogbookSession -Reason AUTO_FINISH | Out-Null
$monitors = Get-ProcessByCommandPattern 'logbook_monitor\.ps1'
foreach ($p in $monitors) { if ([int]$p.ProcessId -ne [int]$PID) { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue } }
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_monitor.ps1')) | Out-Null
Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_popup.ps1'),'-TestMode') | Out-Null
Write-Host 'OK: state cleaned, monitor restarted, popup test launched.' -ForegroundColor Green
