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

# ---- callback fast path (served BEFORE anything is loaded) ------------------
# This branch is what a bar CLICK runs, so it sits on the critical path of
# "click -> card appears" and every millisecond in it is felt as lag. Measured:
# dot-sourcing logbook_common.ps1 first cost ~350ms of pure parse time -- it is
# 140KB+ of PowerShell -- to then write four bytes to a file. That was most of
# the reason the widget felt dead on click (586ms total, before the widget's
# own poll had even seen the request).
#
# So the write is done here from the ONE line of state that it needs, which is
# the same derivation $Global:StateDir uses in logbook_common.ps1. That is a
# deliberate, contained duplication: this path must not load that file, and the
# canonical writer (Request-LogbookBarAction) stays where it is for every other
# caller. Read-LogbookBarAction trims what it reads, so no-BOM UTF8 -- what
# File::WriteAllText emits -- is read back identically to the ASCII the
# canonical writer produces.
# Written via a temp file and a rename, for the same reason bar_status.json is
# (see Write-LogbookBarStatus). The widget now looks for this file ten times a
# second, so the window between "file exists" and "file has contents" is one it
# will land in: it would read an empty string, find no action in it, and delete
# the file -- swallowing the click entirely. A rename is atomic; there is no
# moment at which the file exists but is empty.
if ($PSCmdlet.ParameterSetName -eq 'Action') {
    $dir = Join-Path $env:ProgramData 'Logix'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $dest = Join-Path $dir 'bar_action'
    $tmp = "$dest.tmp"
    [System.IO.File]::WriteAllText($tmp, $Action)
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    exit 0
}

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

# ---- status path (fast, no output formatting) -------------------------------
# ('Action' is handled at the top of the file, before the dot-source.)
if ($PSCmdlet.ParameterSetName -eq 'Status') {
    $empty = '{"schema_version":1,"state":"none","text":"","alt":"","tooltip":"Logix: tidak ada sesi aktif"}'
    if (-not (Test-Path $statusFile)) { $empty; exit 0 }

    $raw = Get-Content $statusFile -Raw
    # STALENESS. The widget writes a beacon every BAR_BEACON_SECONDS, so a
    # file older than BAR_STALE_SECONDS means the process that was writing it
    # is gone -- the machine was cut, the widget was killed -- NOT that the
    # session is still running. A bar left showing a live-looking session for
    # a workstation nobody is at is worse than one showing nothing, which is
    # the same reasoning behind Clear-LogbookBarStatus.
    #
    # Consumers that read bar_status.json DIRECTLY (the generated YASB config
    # does, via `type`, to avoid spawning a shell on every poll) must apply
    # this rule themselves: treat now - updated_at > 150s as unknown, never
    # as active.
    try {
        $p = $raw | ConvertFrom-Json
        $stamp = if ($p.updated_at) { $p.updated_at } else { $p.updated }
        if ($stamp) {
            $age = ((Get-Date) - [datetime]$stamp).TotalSeconds
            if ($age -gt $Global:BAR_STALE_SECONDS) {
                Write-LogbookInfo "bar_status.json is ${age}s old (> $($Global:BAR_STALE_SECONDS)s); reporting unknown rather than a session nobody is running."
                '{"schema_version":1,"state":"unknown","text":"","alt":"","tooltip":"Logix: status tidak diketahui"}'
                exit 0
            }
        }
    } catch {
        # Malformed: hand back the empty contract rather than a broken one.
        # json.loads on the bar side would swallow the error and render the
        # raw template forever.
        $empty; exit 0
    }
    $raw
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
/* Give the slot the same container every other widget on the bar has. Without
   it the Logix slot is the only bare one in the row, which is most of why it
   does not read as a button you can press. Match whatever background your own
   theme gives .clock-widget .widget-container. */
.logix-widget .widget-container {
    background-color: rgba(255, 255, 255, 0.04);
    border-radius: 6px;
}
/* There is deliberately NO :hover rule. It is the obvious first answer to "the
   slot feels dead", and it does not work: measured on a live bar with the
   container painted a flat colour, hovering changes nothing, and neither does
   the .home-widget .icon:hover that ships in other people's themes. Qt only
   evaluates a pseudo-state on the LAST element of a selector, and these frames
   never get WA_Hover. The click has to BE fast rather than look pressed, which
   is what the -Action fast path and the widget's 100ms poll are for. */
.logix-widget .label {
    color: #EEF3FB;
}
/* The clock is the value; the glyph is a label for it, so it sits back a step
   rather than competing at the same weight. */
.logix-widget .icon {
    color: #93A1B8;
    font-size: 13px;
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
