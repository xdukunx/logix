# INTERACTIVE smoke test: opens the real sign-in popup in TestMode.
#
# This one puts a window on screen and waits for you -- it is not part of the
# automated suite. The automated client checks are test_logbook_config.ps1 and
# test_logbook_clickthrough.ps1, neither of which shows anything.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\test_logbook_popup.ps1
#   ...             ... -File windows\test_logbook_popup.ps1 -Installed
#
# Defaults to the REPO copy. It used to be hardcoded to
# 'C:\Program Files\Logix\logbook_popup.ps1', which meant a routine test run
# rendered whatever stale build happened to be installed -- and a mixed-version
# install (a popup three weeks older than its logbook_common.ps1) failed with a
# missing-function error that looked like a repo bug but was not. Test what you
# just edited by default; reach for -Installed deliberately.
param([switch]$Installed)

$popup = if ($Installed) { 'C:\Program Files\Logix\logbook_popup.ps1' }
         else { Join-Path $PSScriptRoot 'logbook_popup.ps1' }

if (-not (Test-Path $popup)) { throw "popup script not found: $popup" }
Write-Host "launching $popup" -ForegroundColor Cyan

Set-ExecutionPolicy -Scope Process Bypass -Force
& $popup -TestMode
