# Proves the bar status contract v1 by running it, not by reading it.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'logbook_common.ps1')

$tmp = Join-Path $env:TEMP ('barv1_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$Global:StateDir = $tmp
$Global:ErrorLog = Join-Path $tmp 'test.log'
$Global:LogbookStatusFile = Join-Path $tmp 'bar_status.json'

$fail = 0
function Check($ok, $msg) {
    if ($ok) { Write-Host "  ok: $msg" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:fail++ }
}
function Mtime { (Get-Item $Global:LogbookStatusFile).LastWriteTime }
function Load { Get-Content $Global:LogbookStatusFile -Raw | ConvertFrom-Json }

$args0 = @{
    Text = '02:34'; Alt = 'LAB-03 - 02:34:17'; Tooltip = 'LAB-03 - 02:34:17'
    State = 'active'; SessionId = 'win-x-1'; StartedAt = '2026-08-18T08:41:00+07:00'
    Title = 'DFTB Parameterization'; Station = 'LAB-03'
    SyncState = 'local_only'; PendingEvents = 0
}

Write-Host 'schema'
Write-LogbookBarStatus @args0 -Force
$p = Load
Check ($p.schema_version -eq 1) 'schema_version is 1'
Check ($p.state -eq 'active' -and $p.station -eq 'LAB-03') 'state and station present'
Check ($p.started_at -eq '2026-08-18T08:41:00+07:00') 'started_at is an instant, not a clock'
Check ($p.title -eq 'DFTB Parameterization') 'title carries tujuan'
Check ($p.sync_state -eq 'local_only') 'sync_state present'
Check ($null -ne $p.updated_at) 'updated_at present'
Check ($null -ne $p.text -and $null -ne $p.alt) 'legacy keys retained for one release'

Write-Host 'privacy'
$raw = Get-Content $Global:LogbookStatusFile -Raw
Check ($raw -notmatch 'nim') 'no nim key'
Check ($raw -notmatch '000000000') 'no student id value'
$names = ($p.PSObject.Properties.Name) -join ','
Check ($names -notmatch 'nama') 'no nama key'

Write-Host 'atomic write'
Check (-not (Test-Path ($Global:LogbookStatusFile + '.tmp'))) 'no temp file left behind'
$bytes = [System.IO.File]::ReadAllBytes($Global:LogbookStatusFile)
Check (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'no UTF-8 BOM'

Write-Host 'the write gate'
$t0 = Mtime
Start-Sleep -Milliseconds 1100
1..5 | ForEach-Object { Write-LogbookBarStatus @args0 }
Check ((Mtime) -eq $t0) 'five identical ticks wrote nothing'

$secondly = $args0.Clone()
$secondly.Alt = 'LAB-03 - 02:34:18'; $secondly.Tooltip = 'LAB-03 - 02:34:18'
Write-LogbookBarStatus @secondly
Check ((Mtime) -eq $t0) 'a tick whose only change is the SECONDS wrote nothing'

$minutely = $args0.Clone(); $minutely.Text = '02:35'
Write-LogbookBarStatus @minutely
Check ((Mtime) -ne $t0) 'a tick whose MINUTE changed did write'

$t1 = Mtime
Start-Sleep -Milliseconds 1100
$stateChange = $minutely.Clone(); $stateChange.State = 'message'
Write-LogbookBarStatus @stateChange
Check ((Mtime) -ne $t1) 'a state change writes immediately'
Check ((Load).state -eq 'message') 'and the new state is on disk'

$t2 = Mtime
Start-Sleep -Milliseconds 1100
$syncChange = $stateChange.Clone(); $syncChange.SyncState = 'pending'; $syncChange.PendingEvents = 3
Write-LogbookBarStatus @syncChange
Check ((Mtime) -ne $t2) 'a sync-state change writes immediately'
Check ((Load).pending_events -eq 3) 'pending_events reaches the bar'

Write-Host 'beacon'
Check ($Global:BAR_BEACON_SECONDS -eq 60) 'beacon interval is 60s'
Check ($Global:BAR_STALE_SECONDS -gt $Global:BAR_BEACON_SECONDS) 'stale window is wider than the beacon'
$Global:LogbookBarLastWrite = (Get-Date).AddSeconds(-($Global:BAR_BEACON_SECONDS + 5))
$t3 = Mtime
Start-Sleep -Milliseconds 1100
Write-LogbookBarStatus @syncChange
Check ((Mtime) -ne $t3) 'an unchanged tick past the beacon interval DOES write'

Write-Host 'session end'
$t4 = Mtime
Start-Sleep -Milliseconds 1100
Clear-LogbookBarStatus
Check ((Mtime) -ne $t4) 'clearing always writes, gate or no gate'
Check ((Load).state -eq 'none') 'and the ended state is on disk'

Write-Host 'malformed and missing input'
Set-Content -LiteralPath $Global:LogbookStatusFile -Value '{ not json' -Encoding ASCII
Write-LogbookBarStatus @args0 -Force
Check ((Load).schema_version -eq 1) 'a corrupt file is simply overwritten'
Remove-Item $Global:LogbookStatusFile -Force
Write-LogbookBarStatus @args0 -Force
Check (Test-Path $Global:LogbookStatusFile) 'a deleted file is recreated'

Write-Host 'consumer: staleness'
$yasbSrc = Get-Content (Join-Path $PSScriptRoot 'logix_yasb.ps1') -Raw
Check ($yasbSrc -match 'BAR_STALE_SECONDS') 'the consumer applies the stale window'
Check ($yasbSrc -match '"state":"unknown"') 'a stale file reports unknown, not active'
Check ($yasbSrc -match '(?s)catch \{.*?\$empty') 'a malformed file falls back to the empty contract'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All bar status v1 checks passed.' -ForegroundColor Green
