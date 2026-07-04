Set-ExecutionPolicy -Scope Process Bypass -Force
& (Join-Path $PSScriptRoot 'logbook_popup.ps1') -TestMode
