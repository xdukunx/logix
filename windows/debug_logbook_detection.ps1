$ErrorActionPreference = 'Continue'
. 'C:\lab\logbook_common.ps1'
Ensure-LogbookDirs
Write-Host "=== Logix Logbook Detection Debug ==="
Write-Host "User: $env:USERDOMAIN\$env:USERNAME"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "Forced AnyDesk: $env:LOGBOOK_FORCE_ANYDESK"
Write-Host ""
Write-Host "AnyDesk processes:"
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'AnyDesk*' } | Select-Object Id,ProcessName,MainWindowTitle | Format-Table -AutoSize
Write-Host ""
$info = Get-LogbookSessionType
Write-Host "Detected session type: $($info[0])"
Write-Host "AnyDesk flag: $($info[1])"
