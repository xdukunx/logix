# Render the Logix session timer inside YASB instead of as a floating pill.
#
#   powershell -ExecutionPolicy Bypass -File windows\logix_yasb.ps1 -Enable
#   powershell -ExecutionPolicy Bypass -File windows\logix_yasb.ps1 -Disable
#
# WHY
#   The floating pill is an overlay, so wherever it sits it sits ON TOP of
#   something. Docked to the top edge -- where the design puts it -- that
#   something is the browser tab strip, and no amount of click-through fixes
#   that: the pill has to take clicks on itself or hover, drag and the posture
#   toggle all stop working. A status bar does not have the problem at all,
#   because a bar RESERVES its space. Nothing is ever underneath it.
#
# HOW IT WORKS
#   The timer process already ticks once a second and already knows the
#   elapsed time, the station and the session state. It publishes that to
#   bar_status.json (see Write-LogbookBarStatus). YASB reads the file with
#   `type`, so nothing spawns a PowerShell process every second.
#
#   -Enable also switches the widget to 'bar' posture, which makes the floating
#   window draw nothing -- otherwise you would have two of them.
#
# This script deliberately does NOT edit config.yaml. That file is yours, it is
# hand-tuned, and every YAML library in existence would strip its comments and
# reflow it on a round trip. It prints exactly what to paste instead.
[CmdletBinding(DefaultParameterSetName = 'Show')]
param(
    [Parameter(ParameterSetName = 'Enable')]  [switch]$Enable,
    [Parameter(ParameterSetName = 'Disable')] [switch]$Disable,
    # Used by YASB's own callbacks, not by a person.
    [Parameter(ParameterSetName = 'Action')]
    [ValidateSet('open', 'posture')] [string]$Action,
    [Parameter(ParameterSetName = 'Status')]  [switch]$Status
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'logbook_common.ps1')
Ensure-LogbookDirs

$statusFile = Get-LogbookStatusFile
$prefsPath  = Join-Path $Global:StateDir 'widget_prefs.json'

function Set-LogbookPosturePref([string]$Posture) {
    $prefs = @{ posture = $Posture; anchor = 0.5; pillOpacity = 0.72 }
    if (Test-Path $prefsPath) {
        try {
            $existing = Get-Content $prefsPath -Raw | ConvertFrom-Json
            foreach ($k in @('anchor', 'pillOpacity')) {
                if ($null -ne $existing.$k) { $prefs[$k] = $existing.$k }
            }
        } catch { }
    }
    $prefs | ConvertTo-Json | Out-File -FilePath $prefsPath -Encoding UTF8 -Force
    Write-Host "posture -> $Posture  ($prefsPath)" -ForegroundColor Green
}

# ---- callback / status paths (fast, no output formatting) -------------------
if ($PSCmdlet.ParameterSetName -eq 'Action') {
    Request-LogbookBarAction -Action $Action
    exit 0
}
if ($PSCmdlet.ParameterSetName -eq 'Status') {
    if (Test-Path $statusFile) { Get-Content $statusFile -Raw }
    else { '{"text":"","alt":"","tooltip":"Logix: tidak ada sesi aktif","state":"none"}' }
    exit 0
}

# ---- enable / disable --------------------------------------------------------
if ($Disable) {
    Set-LogbookPosturePref 'pill'
    Write-Host ""
    Write-Host "The floating pill is back. Remove 'logix' from your YASB bar's widget list"
    Write-Host "if you do not want an empty slot."
    exit 0
}

if ($Enable) { Set-LogbookPosturePref 'bar' }

$selfPath = $PSCommandPath
$yasbConfig = Join-Path $env:USERPROFILE '.config\yasb\config.yaml'
$yasbStyles = Join-Path $env:USERPROFILE '.config\yasb\styles.css'

# Two quoting styles in one YAML block, matching how config.yaml already
# quotes its OWN icon widgets (see wifi_icons above it: "\udb82\udd2e" etc.) --
# not a style choice, a YAML requirement:
#   - label/label_alt are DOUBLE-quoted with a \uXXXX escape, because a
#     single-quoted YAML scalar has no escapes at all, so typing the literal
#     text \uf017 there would render as that literal text, not the glyph.
#   - run_cmd/on_right are SINGLE-quoted, because inside a double-quoted YAML
#     scalar a backslash IS an escape character, so "C:\ProgramData\..." is
#     not a path there, it's a parse error on an unknown escape \M.
# This is the exact mistake made hand-editing config.yaml the first time --
# get either one backwards and it is a parse error, not a wrong icon.
$widgetYaml = @"
  # --- Logix session timer ---------------------------------------------------
  # Reads a file the Logix agent already writes once a second; nothing heavy
  # runs on the interval. Shows nothing at all when no session is open.
  logix:
    type: 'yasb.custom.CustomWidget'
    options:
      label: "<span>\uf017</span> {data[text]}"
      label_alt: "{data[alt]}"
      class_name: 'logix-widget'
      exec_options:
        # YASB splits run_cmd on plain spaces (str.split(" "), not shlex) --
        # it does not understand quoting at all. "cmd /c type \"path\"" broke
        # because that split, re-quoted through Python's list2cmdline, then
        # re-parsed by a NESTED cmd.exe (shell=True already wraps everything
        # in one cmd.exe /c layer, and this added a second), never survives
        # intact -- it renders as raw "{data[text]}" with no error anywhere.
        # The fix is not smarter quoting; it is not needing any. `type` is a
        # cmd.exe builtin, which shell=True (the default) already runs under,
        # so the extra `cmd /c` was redundant -- and C:\ProgramData never
        # contains a space, so the bare path never needs quoting to begin with.
        run_cmd: 'type $statusFile'
        run_interval: 1000
        return_format: 'json'
      callbacks:
        # Left click opens the session card (details + SELESAI). YASB's
        # default for a custom widget is toggle_label on left, but here that
        # buries the ONLY way to end a session behind a right click nobody
        # discovers -- the first question after switching to bar posture was
        # "where did the SELESAI button go?". Primary action, primary button.
        on_left: 'exec powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$selfPath" -Action open'
        on_middle: 'do_nothing'
        on_right: 'toggle_label'
"@

$cssSnippet = @"
/* --- Logix session timer -------------------------------------------------- */
/* Mono for the clock, matching the v3 rule that every time value is tabular. */
.logix-widget {
    padding: 0 8px 0 6px;
    font-family: "JetBrainsMono NFP", Consolas, monospace;
}
.logix-widget .label {
    color: #EEF3FB;
}
/* Empty payload = no session. Collapse the slot rather than leave a gap. */
.logix-widget .label:empty {
    padding: 0;
    margin: 0;
}
"@

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host " 1. Add this to the 'widgets:' section of" -ForegroundColor Cyan
Write-Host "    $yasbConfig" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host $widgetYaml
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host " 2. Add 'logix' to a bar's widget list, e.g." -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host '    right: ["logix", "pomodoro", "media", "volume", "clock"]'
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host " 3. Append to $yasbStyles" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host $cssSnippet
Write-Host "============================================================="
Write-Host ""
Write-Host "watch_config/watch_stylesheet pick both up without restarting YASB."
Write-Host ""
Write-Host "Left click  : swap the clock for 'station - hh:mm:ss'"
Write-Host "Right click : open the full Logix card (details + SELESAI)"
Write-Host ""
if (-not $Enable) {
    Write-Host "Nothing was changed. Re-run with -Enable to also hide the floating pill." -ForegroundColor Yellow
}

# Written to disk too, because copying multi-line YAML out of a console is a
# good way to lose the indentation that YAML cares about.
$out = Join-Path $env:TEMP 'logix-yasb-snippet.txt'
@("# 1. paste into the widgets: section of $yasbConfig", $widgetYaml, "",
  "# 2. add 'logix' to a bar's widget list", "",
  "# 3. append to $yasbStyles", $cssSnippet) -join "`r`n" |
    Out-File -FilePath $out -Encoding UTF8 -Force
Write-Host "Also written to: $out" -ForegroundColor DarkGray
exit 0
