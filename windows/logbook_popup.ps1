param([switch]$TestMode, [switch]$ForceNew, [switch]$STAChild)
$ErrorActionPreference = 'Stop'

# Dot-sourced BEFORE the STA shim on purpose: common's top level only sets
# globals and defines functions (no window, no STA dependency), so loading it
# first lets the relaunch reuse Start-HiddenPowerShell -- the one place that
# owns the conhost --headless + argument-quoting launch contract.
. 'C:\Program Files\Logix\logbook_common.ps1'

# WPF must run in STA. If Task Scheduler/Run launches normal PowerShell, relaunch safely.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-STAChild')
    if ($TestMode) { $args += '-TestMode' }
    if ($ForceNew) { $args += '-ForceNew' }
    # Hidden console only -- the WPF sign-in form still shows (same pattern the
    # timer uses). Avoids a stray powershell window on the desktop.
    Start-HiddenPowerShell -ArgumentList $args | Out-Null
    exit 0
}

Ensure-LogbookDirs
# Cache-first: this is the login path, and a person is watching a blank screen
# until it renders. The timer refreshes this cache once a minute for the whole
# life of a session (see Get-LogbookCachedIdleLimit), so in practice it is
# seconds old. Only a genuinely cold box pays for the round-trip.
$cfg = Get-LogbookConfig -MaxCacheAgeSeconds 300
Write-LogbookInfo "Popup launch TestMode=$TestMode ForceNew=$ForceNew"

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
} catch {
    Write-LogbookError "WPF load failed: $($_.Exception.Message)"
    throw
}

# If a previous popup run crashed/was force-killed before it could restore
# Task Manager (see Set-TaskManagerDisabled in logbook_common.ps1), and no
# other popup instance is currently showing, clear that stale lock before
# gating it again for this run.
try {
    $staleMarker = Join-Path $Global:StateDir 'taskmgr_prev_value.txt'
    if ((Test-Path $staleMarker) -and -not (Test-LogbookPopupRunning)) {
        Set-TaskManagerDisabled -Disabled $false
    }
} catch {}

# If there is an active session and this is not an explicit new interactive unlock, only restore timer.
# If ForceNew is set, close stale previous session first so the report gets END/Auto Finish + duration.
if ((Test-Path $Global:SessionFile) -and -not $TestMode) {
    $age = Get-ActiveLogbookSessionAgeSeconds
    if ($ForceNew -and ($null -eq $age -or $age -gt 5)) {
        Close-ActiveLogbookSession -Reason 'AUTO_FINISH' | Out-Null
    } elseif (Close-OverAgeLogbookSessionIfAny) {
        # Session was left open past the max-session cap (typically locked or
        # slept across the night). It has just been closed; fall through to
        # render a fresh sign-in form instead of resuming a timer that would
        # read from yesterday.
    } else {
        $active = Get-ActiveLogbookSession
        if ($active -and $active.session_id) { Start-LogbookTimer -SessionId $active.session_id | Out-Null }
        exit 0
    }
}

function New-BlurredBackgroundImage {
    try {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bmp.Size)
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
        $ms.Position = 0
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $img.StreamSource = $ms
        $img.EndInit()
        $img.Freeze()
        $ms.Dispose()
        return $img
    } catch {
        Write-LogbookError "Screenshot blur background failed: $($_.Exception.Message)"
        return $null
    }
}

# "Card implosion" close: the backdrop (blurred desktop screenshot + scrim --
# everything in the root Grid except MainCard) fades on its own, slightly
# longer timeline as a soft lingering vignette, while MainCard (the actual
# sign-in panel) gets the dramatic exit -- a quick confirm "pop", then an
# accelerating shrink + twist + blur + fade into the exact SCREEN CENTER
# (MainCard is itself screen-centered, so its own RenderTransformOrigin
# 0.5,0.5 IS the screen center -- the same point the timer's entrance grows
# FROM, so the handoff between the two windows still reads as one continuous
# motion, just richer than a flat whole-window shrink). Manual per-frame
# DispatcherTimer easing rather than WPF Storyboards/KeyFrames, matching how
# every other custom-eased animation in this codebase is built (see
# $script:animTimer / $script:slideTimer in logbook_timer.ps1) -- easier to
# reason about and to verify by sampling live property values mid-flight.
#
# The close itself does NOT depend on any of these animations or their
# Completed events at all -- it is a plain DispatcherTimer fired a little
# after the total animation duration. This is deliberate: a WPF animation's
# Completed event can go unheard for reasons that have nothing to do with
# whether the animation itself is running fine (GC of the delegate, an
# exception earlier in the handler chain, a dispatcher priority mismatch) --
# and unlike a timer, there is no way to add a "close after N ms no matter
# what" fallback AROUND an event that might just never fire. A fullscreen,
# Topmost, kiosk-locked window that fails to close is far worse than a
# cosmetic animation glitch, so the guaranteed-fire path is the one thing
# that is allowed to be load-bearing here. (The window's own XAML still sets
# AllowsTransparency="True" from the earlier stuck-window fix -- unused by
# this version directly, but cheap insurance: if MainCard or the backdrop
# children are ever missing/renamed, an unanimated but still-transparent
# window is a far less alarming failure mode than an opaque one.)
function Invoke-LogbookFadeClose($win, [double]$DurationMs = 380) {
    $root = $win.Content
    $card = $null
    try { $card = $win.FindName('MainCard') } catch {}

    # Backdrop: every direct child of the root Grid except the card (BgImage,
    # the scrim Rectangle) -- found structurally rather than by name, so this
    # works unchanged for both window layouts that share this Image+
    # Rectangle+Border pattern (the main sign-in form and the returning-user
    # welcome-back card) without hardcoding either one's exact child list.
    try {
        if ($root -and $card) {
            foreach ($child in @($root.Children)) {
                if ($child -ne $card -and $child -is [System.Windows.UIElement]) {
                    $bgFade = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [TimeSpan]::FromMilliseconds($DurationMs + 80))
                    $bgEase = New-Object System.Windows.Media.Animation.CubicEase; $bgEase.EasingMode = 'EaseIn'
                    $bgFade.EasingFunction = $bgEase
                    $child.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $bgFade)
                }
            }
        }
    } catch { Write-LogbookError "Fade-close backdrop animation failed (non-fatal): $($_.Exception.Message)" }

    if ($card) {
        try {
            $card.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
            $group = New-Object System.Windows.Media.TransformGroup
            $scale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
            $rotate = New-Object System.Windows.Media.RotateTransform(0.0)
            [void]$group.Children.Add($scale)
            [void]$group.Children.Add($rotate)
            $card.RenderTransform = $group
            # Swaps out the card's resting drop shadow for the duration of the
            # close: an element carries only one Effect at a time, and the
            # shadow stops reading the instant the card is mid-shrink anyway
            # -- the blur is what actually sells "dissolving", not just
            # "shrinking".
            $blur = New-Object System.Windows.Media.Effects.BlurEffect
            $blur.Radius = 0
            $card.Effect = $blur

            # Timing rebalanced against Material Design's Container Transform
            # spec (the exact "one element hands off to another at the same
            # screen point" pattern this is): its outgoing duration (250ms) is
            # SHORTER than its incoming duration (300ms), and outgoing content
            # opacity only fades in the FINAL portion of the transition (its
            # documented enter/return fade thresholds sit at the START or END
            # of the timeline, never spread across the whole thing) -- staying
            # fully opaque while it shrinks/rotates/blurs keeps it visually
            # PRESENT for the outgoing element's own overlap with the incoming
            # one. The previous version fought both of these: a slower ~460ms
            # outgoing animation with opacity fading across its ENTIRE length
            # meant the card was already faint well before the timer (a
            # separate process, entrance ~420ms) had time to become visibly
            # recognizable -- read as "form closes, THEN timer appears"
            # instead of one continuous handoff.
            $popMs = 90.0
            $implodeMs = [Math]::Max($DurationMs - $popMs, 100.0)
            # Opacity holds at 1.0 through this fraction of the implode phase
            # (matching Material's "content stays opaque, then fades" idea),
            # THEN fades over the remainder -- so the card stays visually
            # present, mid-shrink, for most of the motion instead of fading
            # out in lockstep with it.
            $opacityHoldFrac = 0.65
            # $script: scope, NOT .GetNewClosure(): PowerShell's
            # GetNewClosure() snapshots a scriptblock's captured variables
            # ONCE, and a mutation made to a plain scalar inside one
            # invocation (e.g. "$cardStep += 1") does NOT persist into the
            # NEXT invocation of that same delegate -- confirmed directly
            # (an isolated counter that should reach 5 across 5 ticks
            # instead read 1 on every single tick, forever). Reference-type
            # mutations (calling a method on a captured object, like the
            # close timer's own "$win.Close()") are unaffected -- only a
            # rebinding scalar accumulator like this step counter is. The
            # rest of this codebase's own custom-eased animations
            # ($script:animStep in Update-LogbookTimerSize,
            # $script:slideStep in the center-to-dock glide, both in
            # logbook_timer.ps1) already use $script: scope for exactly
            # this reason -- matching that here instead of GetNewClosure().
            #
            # Progress is driven by a Stopwatch's actual elapsed time, NOT
            # by counting ticks and assuming each one represents exactly
            # 16ms: a DispatcherTimer's real firing interval is only a
            # request, not a guarantee, and drifts under load or (measured
            # directly while building this) when the window isn't the
            # foreground/focused one -- ticks landing every 60-100ms+
            # instead of 16ms is well within normal Windows behavior, not a
            # bug. Counting ticks would make the WHOLE animation run in
            # slow motion whenever that happens; reading elapsed wall-clock
            # time on every tick keeps the total duration correct
            # regardless -- fewer intermediate frames on a busy system, but
            # never a stuck-looking crawl, and it always finishes on time
            # (which the independent close-guarantee timer below assumes).
            $script:cardStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $script:cardScale = $scale
            $script:cardRotate = $rotate
            $script:cardBlur = $blur
            $script:cardEl = $card
            $script:cardPopMs = $popMs
            $script:cardImplodeMs = $implodeMs
            $script:cardOpacityHoldFrac = $opacityHoldFrac
            $script:cardTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:cardTimer.Interval = [TimeSpan]::FromMilliseconds(16)
            $script:cardTimer.Add_Tick({
                $elapsedMs = $script:cardStopwatch.Elapsed.TotalMilliseconds
                if ($elapsedMs -le $script:cardPopMs) {
                    # Phase 1 (~110ms): a small confirm "pop" -- 1.0 -> 1.03,
                    # ease-out -- acknowledges the click before the card
                    # commits to leaving.
                    $t = $elapsedMs / $script:cardPopMs
                    $eased = 1.0 - (1.0 - $t) * (1.0 - $t)
                    $s = 1.0 + 0.03 * $eased
                    $script:cardScale.ScaleX = $s; $script:cardScale.ScaleY = $s
                } elseif ($elapsedMs -ge ($script:cardPopMs + $script:cardImplodeMs)) {
                    $script:cardScale.ScaleX = 0.03; $script:cardScale.ScaleY = 0.03
                    $script:cardRotate.Angle = 7.0
                    $script:cardEl.Opacity = 0.0
                    $script:cardBlur.Radius = 16.0
                    $script:cardTimer.Stop()
                } else {
                    # Phase 2 (~260ms): accelerating shrink + twist + blur
                    # toward the screen center, ease-in cubic -- reads as
                    # being pulled into the point rather than just deflating
                    # in place. Opacity does NOT track $eased directly: it
                    # holds at 1.0 through cardOpacityHoldFrac of this phase,
                    # then fades over the remainder, so the card stays
                    # visually present (shrinking/rotating/blurring, but
                    # still opaque) for most of its own motion -- see the
                    # Material Design Container Transform comment above.
                    $t = ($elapsedMs - $script:cardPopMs) / $script:cardImplodeMs
                    $eased = $t * $t * $t
                    $script:cardScale.ScaleX = 1.03 + (0.03 - 1.03) * $eased
                    $script:cardScale.ScaleY = $script:cardScale.ScaleX
                    $script:cardRotate.Angle = 7.0 * $eased
                    if ($t -le $script:cardOpacityHoldFrac) {
                        $script:cardEl.Opacity = 1.0
                    } else {
                        $fadeT = ($t - $script:cardOpacityHoldFrac) / (1.0 - $script:cardOpacityHoldFrac)
                        $script:cardEl.Opacity = 1.0 - ($fadeT * $fadeT * $fadeT)
                    }
                    $script:cardBlur.Radius = 16.0 * $eased
                }
            })
            $script:cardTimer.Start()
        } catch {
            Write-LogbookError "Fade-close card-implosion animation failed (closing on the timer fallback regardless): $($_.Exception.Message)"
        }
    } else {
        # No MainCard found (a future XAML edit renamed/removed it) -- fall
        # back to the previous whole-window shrink so the close still looks
        # deliberate instead of just vanishing.
        try {
            $win.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
            $wscale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
            $win.RenderTransform = $wscale
            $dur = [TimeSpan]::FromMilliseconds($DurationMs)
            $ease = New-Object System.Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseIn'
            $scaleAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.04, $dur)
            $scaleAnim.EasingFunction = $ease
            $wscale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $scaleAnim)
            $wscale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $scaleAnim)
            $fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, $dur)
            $fadeAnim.EasingFunction = $ease
            $win.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeAnim)
        } catch { Write-LogbookError "Fade-close fallback animation failed (closing on the timer fallback regardless): $($_.Exception.Message)" }
    }

    # GetNewClosure(): a bare scriptblock referencing a FUNCTION PARAMETER
    # (not a $script:-scope variable) does not capture it -- by the time the
    # Dispatcher fires this Tick, Invoke-LogbookFadeClose has already
    # returned and $win's local scope is gone, so an uncaptured reference
    # resolves to $null and $null.Close() throws, silently swallowed by the
    # try/catch below. That silent-null-close was the actual root cause of
    # an earlier stuck-window bug. GetNewClosure() snapshots $win's current
    # value into the scriptblock's own bound scope so it survives the
    # parent function returning -- fine here (unlike the card timer's own
    # step counter) because this only reads/calls methods on captured
    # object REFERENCES, and only fires once; it never needs a mutation to
    # persist across repeated invocations of the same delegate.
    #
    # A DispatcherTimer's nominal interval is a request, not a guarantee --
    # measured directly while building this, ticks can land 200-400ms+ late
    # under load (or simply when the window isn't the foreground/focused
    # one). The card's own implosion timer is Stopwatch-driven so each tick
    # computes the CORRECT value for whenever it happens to fire, but sparse
    # ticks mean it might not get a FINAL tick in before this guaranteed
    # close fires, cutting the animation off mid-flight (caught live: closing
    # at ~53% opacity instead of fully faded). So this snaps MainCard's
    # scale/rotation/opacity/blur straight to their fully-collapsed end
    # values immediately before Close() -- independent of whatever the card
    # timer's own ticks managed to reach -- so the very last visible frame is
    # always the correct "fully gone" state, never a half-finished one.
    $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $closeTimer.Interval = [TimeSpan]::FromMilliseconds($DurationMs + 90)
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        try {
            if ($card) {
                $scale.ScaleX = 0.03; $scale.ScaleY = 0.03
                $rotate.Angle = 7.0
                $card.Opacity = 0.0
                if ($blur) { $blur.Radius = 16.0 }
            }
        } catch {}
        try { $win.Close() } catch { Write-LogbookError "Fade-close fallback Close() failed: $($_.Exception.Message)" }
    }.GetNewClosure())
    $closeTimer.Start()
}

# Waits for the newly-spawned timer process (a SEPARATE process -- see
# Start-LogbookTimer in logbook_common.ps1) to signal it has actually reached
# the screen, THEN starts this form's collapse-close -- instead of closing on
# a fixed schedule unrelated to how long the timer's own cold start (new
# powershell.exe process, WPF/System.Xaml assembly load, XAML parse) actually
# takes. That fixed-schedule version was the real cause of the handoff not
# reading as smooth: on a slow/cold launch the form would already be gone
# before the timer had rendered anything, leaving a bare-desktop gap between
# the two windows' animations. logbook_timer.ps1 writes StateDir's
# timer_ready.flag the moment its own window reaches Add_Loaded (about to
# render); Start-LogbookTimer clears any stale flag right before spawning so
# a leftover from a PREVIOUS timer can't be misread as this one's signal.
# Polls via a DispatcherTimer (not Start-Sleep, which would freeze the WPF
# message loop and the "Menyimpan..." button along with it). Falls back to
# closing anyway after $MaxWaitMs so a timer that never starts, or never
# reaches Loaded, can't leave this fullscreen kiosk-locked form stuck.
# 1800ms default: measured cold-start latency (new conhost+powershell.exe
# process, WPF/System.Xaml assembly load, XAML parse, first Loaded) on real
# hardware came in around 1.0-1.3s -- an earlier, tighter 900ms default would
# have timed out and closed the form BEFORE the timer was actually ready on
# a cold launch, defeating the whole point of this handshake.
function Invoke-LogbookHandoffToTimer($win, [int]$MaxWaitMs = 1800) {
    $flagPath = Join-Path $Global:StateDir 'timer_ready.flag'
    $deadline = (Get-Date).AddMilliseconds($MaxWaitMs)
    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval = [TimeSpan]::FromMilliseconds(20)
    $poll.Add_Tick({
        $ready = Test-Path $flagPath
        if ($ready -or (Get-Date) -ge $deadline) {
            $poll.Stop()
            if ($ready) { Remove-Item $flagPath -Force -ErrorAction SilentlyContinue }
            Invoke-LogbookFadeClose $win
        }
    }.GetNewClosure())
    $poll.Start()
}

# Cached across the fast path -> full form transition. Clicking "Bukan saya /
# ganti data" used to rebuild the full form AND recapture a fresh fullscreen
# blurred screenshot (New-BlurredBackgroundImage: CopyFromScreen + PNG
# encode/decode, a few hundred ms of blocking work) -- the visible lag on that
# button. The fast path already captured an identical desktop screenshot, so we
# reuse the frozen bitmap (safe to share across windows once Frozen) and skip
# the second capture, making the switch feel instant.
$script:cachedBg = $null
$script:cachedMascot = $null

# Warm the whole START path NOW, while the form is still being built and the
# user cannot have clicked anything yet. See Initialize-LogbookStartPathWarmup
# for the measurements: it is not one slow operation, it is a stack of
# first-call costs (ConvertTo-Json, Start-Process, Out-File, the config read)
# that PowerShell only pays once per process -- and the sign-in popup is always
# a fresh process, so it paid all of them inside the click handler.
Initialize-LogbookStartPathWarmup

$sessionInfo = Get-LogbookSessionType
$detectedSessionType = [string]$sessionInfo[0]
$detectedAnyDesk = [int]$sessionInfo[1]
$sessionId = "win-$($env:USERNAME)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$profileFile = Join-Path $Global:StateDir 'last_profile.json'

# Shared session-start used by BOTH the full sign-in form and the returning-
# user fast path, so the two paths can never drift. Writes the session file +
# local profile, logs START, and starts the timer.
function Invoke-LogbookStartSession {
    param([string]$Nama, [string]$Nim, [string]$Access, [string]$Tujuan, [string]$Keterangan)
    Ensure-LogbookDirs
    $sessionType = $Access.Trim()
    $sid = "win-$env:USERNAME-$([DateTimeOffset]::Now.ToUnixTimeSeconds())-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $anydeskDetected = $(if ($sessionType -eq 'AnyDesk') { 1 } else { 0 })
    $obj = [ordered]@{
        session_id       = $sid
        start_time       = (Get-Date).ToString('o')
        session_type     = $sessionType
        anydesk_detected = $anydeskDetected
        username         = $env:USERNAME
        windows_user     = "$env:USERDOMAIN\$env:USERNAME"
        hostname         = $env:COMPUTERNAME
        nama             = $Nama.Trim()
        nim              = $Nim.Trim()
        tujuan           = $Tujuan.Trim()
        keterangan       = $Keterangan.Trim()
    }
    $obj | ConvertTo-Json -Depth 4 | Out-File -FilePath $Global:SessionFile -Encoding UTF8 -Force
    # Persist locally so the fast path can resume next time (identity never
    # leaves the machine except via the normal START log).
    ([ordered]@{ nama = $obj.nama; nim = $obj.nim; tujuan = $obj.tujuan; keterangan = $obj.keterangan } |
        ConvertTo-Json -Depth 3) | Out-File -FilePath $profileFile -Encoding UTF8 -Force

    # Spawn the timer process as early as possible -- BEFORE the WSL/Python
    # logging round-trip below, which can easily run tens to hundreds of ms
    # (interpreter startup + subprocess overhead). Start-Process returns
    # immediately without waiting for the child, so moving this up costs
    # nothing here; it just gives the timer's own cold start (new process,
    # WPF/XAML load) a head start that overlaps with the logging call instead
    # of stacking after it. logbook_timer.ps1 only needs session.json to
    # exist with a matching session_id, both already true at this point --
    # nothing below this line affects it.
    Start-LogbookTimer -SessionId $sid | Out-Null

    # -Async: this runs on the WPF UI thread inside the button's Click
    # handler, and the synchronous bridge costs ~251ms here -- 82ms to start a
    # Python interpreter, 135ms to import the module, and 6.6ms of actual
    # SQLite work (measured on this machine against a copy of the real
    # database). Blocking the UI thread for a quarter second at the exact
    # moment the user pressed START is the lag; the database was never the
    # problem.
    #
    # Safe here and NOT elsewhere: session.json is already written above and
    # is the client's own source of truth, and a START row that never lands
    # is reconstructed from it by repair_active_session_from_windows_state()
    # -- which logbook_report.build() already calls on every report. A close
    # (END) keeps the synchronous bridge on purpose, because that path has to
    # know whether the row was really written before it locks the machine.
    $dispatched = Invoke-WSLLogbook -Event 'START' -SessionType $sessionType -AnyDeskDetected $anydeskDetected -SessionId $sid -Nama $obj.nama -Nim $obj.nim -Tujuan $obj.tujuan -Keterangan $obj.keterangan -Async
    if (-not $dispatched) { Write-LogbookError "START logging failed to dispatch but continuing safely. sid=$sid" }
    return $true
}

# Returning-user fast path (C8.1): a saved profile + not a forced fresh form
# -> offer one-tap resume before the full sign-in form. "Bukan saya / ganti
# data" falls through to the full form below.
if ((-not $ForceNew) -and (Test-Path $profileFile)) {
    try {
        $fpProfile = Get-Content $profileFile -Raw | ConvertFrom-Json
        if ($fpProfile.nama -and $fpProfile.nim) {
            $fpWindow = [Windows.Markup.XamlReader]::Load(
                (New-Object System.Xml.XmlNodeReader ([xml](Build-LogbookWelcomeBackXaml $cfg $fpProfile $detectedSessionType))))
            # Covers every screen (kiosk), then puts the CARD on one of them.
            # See Set-LogbookWindowToVirtualScreen / Set-LogbookCardOnScreen.
            Set-LogbookWindowToVirtualScreen $fpWindow
            $fpWindow.Add_Loaded({
                # Re-applied here because the DIP scale is only knowable once
                # the window has an HWND; before that a 150% display is sized
                # in raw pixels and every coordinate inside it is off by half.
                Set-LogbookWindowToVirtualScreen $fpWindow
                # No picker on the resume card: it is a one-tap confirmation,
                # not a form, and it is on screen for a couple of seconds.
                [void](Set-LogbookPopupMonitorPlacement -Window $fpWindow -Card $fpWindow.FindName('MainCard') -Panel $null -cfg $cfg)
            })
            $fpWindow.Topmost = $true
            $fpBg = New-BlurredBackgroundImage
            if ($fpBg) { $fpWindow.FindName('BgImage').Source = $fpBg; $script:cachedBg = $fpBg }
            $fpLogo = [string]$cfg.branding.logoPath
            if (Test-Path $fpLogo) {
                try {
                    $m = New-Object System.Windows.Media.Imaging.BitmapImage
                    $m.BeginInit(); $m.UriSource = New-Object System.Uri($fpLogo); $m.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $m.EndInit(); $m.Freeze()
                    $fpWindow.FindName('MascotImage').Source = $m
                    $fpWindow.FindName('MascotImage').Visibility = 'Visible'
                    $script:cachedMascot = $m
                } catch {}
            }
            $script:fpChoice = 'pending'
            $fpWindow.Add_Closing({ param($s, $e) if ($script:fpChoice -eq 'pending') { $e.Cancel = $true } })
            $fpWindow.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -or $e.SystemKey -eq 'F4') { $e.Handled = $true } })
            $fpStartBtn = $fpWindow.FindName('StartBtn')
            $fpStartBtn.Add_Click({
                # Disabled immediately: Invoke-LogbookHandoffToTimer's poll
                # is non-blocking and can take up to ~1.8s, and this button
                # was never guarded before -- without this, a double-click
                # during that wait would start a SECOND session and kill/
                # replace the first timer mid-handoff.
                $fpStartBtn.IsEnabled = $false
                try {
                    $ket = [string]$fpProfile.keterangan
                    if ([string]::IsNullOrWhiteSpace($ket)) { $ket = '(lanjutan sesi)' }
                    Invoke-LogbookStartSession -Nama ([string]$fpProfile.nama) -Nim ([string]$fpProfile.nim) -Access $detectedSessionType -Tujuan ([string]$fpProfile.tujuan) -Keterangan $ket | Out-Null
                } catch { Write-LogbookError "Fast-path start failed: $($_.Exception.Message)" }
                $script:fpChoice = 'resumed'
                # Wait for the timer to actually be on screen, then fade --
                # resume path gets the same synced handoff as a fresh sign-in.
                Invoke-LogbookHandoffToTimer $fpWindow
            })
            # "Bukan saya / ganti data": close instantly (no fade) and fall
            # through to the full form, which now reuses the cached background
            # so it appears without the old recapture lag.
            $fpWindow.FindName('ChangeBtn').Add_Click({ $script:fpChoice = 'form'; $fpWindow.Close() })
            try {
                Set-TaskManagerDisabled -Disabled $true
                Enable-LogbookKeyboardLockdown
                [void]$fpWindow.ShowDialog()
            } finally {
                Disable-LogbookKeyboardLockdown
                Set-TaskManagerDisabled -Disabled $false
            }
            if ($script:fpChoice -eq 'resumed') { exit 0 }
            # otherwise fall through to the full sign-in form below
        }
    } catch { Write-LogbookError "Fast path skipped, showing full form: $($_.Exception.Message)" }
}

$xaml = Build-LogbookPopupXaml $cfg

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# The window still spans every connected screen, and must: this is a kiosk
# lock, and an uncovered second monitor is a way around it. What changed is
# that the CARD inside it is no longer centred on the combined desktop -- on an
# extended pair that centre is the seam between two panels, which is where the
# sign-in dialog used to appear, split across a bezel.
Set-LogbookWindowToVirtualScreen $window

$window.Add_StateChanged({
    if ($window.WindowState -ne 'Normal') { Set-LogbookWindowToVirtualScreen $window }
})

$window.Add_Loaded({
    # Both of these need an HWND: the DIP scale to size the window truthfully,
    # and the card's measured height to centre it vertically on its display.
    Set-LogbookWindowToVirtualScreen $window
    [void](Set-LogbookPopupMonitorPlacement -Window $window -Card $window.FindName('MainCard') `
            -Panel $window.FindName('MonitorPicker') -cfg $cfg)
})

$window.Topmost = $true
$window.Activate() | Out-Null

# Reuse the fast path's frozen screenshot when present (instant "ganti data"
# switch); only capture a fresh one when arriving at the full form directly.
$bg = if ($script:cachedBg) { $script:cachedBg } else { New-BlurredBackgroundImage }
if ($bg -ne $null) { $window.FindName('BgImage').Source = $bg }
# Mascot hero: load branding.logoPath (the mascot PNG the installer lays down
# at C:\Program Files\Logix\logo.png) into MascotImage above the wordmark. The
# LogoText wordmark stays visible beneath it, so a missing/broken image just
# leaves a clean wordmark-only header. Reuse the fast path's frozen copy if we
# already loaded it.
$logoPath = [string]$cfg.branding.logoPath
if ($script:cachedMascot) {
    $window.FindName('MascotImage').Source = $script:cachedMascot
    $window.FindName('MascotImage').Visibility = 'Visible'
} elseif (Test-Path $logoPath) {
    try {
        $mascot = New-Object System.Windows.Media.Imaging.BitmapImage
        $mascot.BeginInit(); $mascot.UriSource = New-Object System.Uri($logoPath); $mascot.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $mascot.EndInit(); $mascot.Freeze()
        $window.FindName('MascotImage').Source = $mascot
        $window.FindName('MascotImage').Visibility = 'Visible'
    } catch { Write-LogbookError "Mascot load failed: $($_.Exception.Message)" }
}
# SessionBadge existed in the older layout, but the revamped layout removes it.
# Keep this guarded so the popup does not crash when the element is absent.
$sessionBadge = $window.FindName('SessionBadge')
if ($null -ne $sessionBadge) {
    try {
        if ($sessionBadge -is [System.Windows.Controls.ContentControl]) {
            $sessionBadge.Content = "Detected: $detectedSessionType | $env:COMPUTERNAME"
        } else {
            $sessionBadge.Text = "Detected: $detectedSessionType | $env:COMPUTERNAME"
        }
    } catch {
        Write-LogbookError "SessionBadge update skipped: $($_.Exception.Message)"
    }
}
$window.FindName('StartTimeText').Text = [string]$cfg.text.startHint

$nama = $window.FindName('NamaBox')
$nim = $window.FindName('NimBox')
Set-LogbookNumericOnly $nim
$access = $window.FindName('AccessBox')
$tujuan = $window.FindName('TujuanBox')
$ket = $window.FindName('KetBox')
$btn = $window.FindName('SubmitBtn')

$hint = $window.FindName('HintText')

# NOTE: a legacy Set-ReadableComboBox lived here. It forced both dropdowns to
# a white background with brand-accent text and walked the visual tree to make
# it stick -- a workaround from before the client had its own dark ComboBox
# ControlTemplate. Once LxCombo landed (logbook_common.ps1) the workaround was
# no longer merely redundant, it WAS the bug: a white box with red text sitting
# in the middle of a dark sign-in card. Style the dropdown in LxCombo, never
# imperatively here.
$script:submitted = $false

if ($detectedSessionType -eq 'AnyDesk') { $access.SelectedIndex = 1 } else { $access.SelectedIndex = 0 }
$tujuan.SelectedIndex = 0
try {
    if (Test-Path $profileFile) {
        $last = Get-Content $profileFile -Raw | ConvertFrom-Json
        if ($last.nama) { $nama.Text = [string]$last.nama }
        if ($last.nim) { $nim.Text = [string]$last.nim }
        $allowedPurpose = @($cfg.purposes)
        if ($last.tujuan -and ($allowedPurpose -contains ([string]$last.tujuan))) {
            for ($i = 0; $i -lt $tujuan.Items.Count; $i++) {
                if ([string]$tujuan.Items[$i].Content -eq [string]$last.tujuan) { $tujuan.SelectedIndex = $i; break }
            }
        }
    }
} catch { Write-LogbookError "Profile prefill failed: $($_.Exception.Message)" }

function Get-ComboText($combo) {
    $txt = ''
    try { $txt = [string]$combo.Text } catch {}
    if (-not [string]::IsNullOrWhiteSpace($txt)) { return $txt }
    try {
        if ($combo.SelectedItem -and $combo.SelectedItem.Content) { return [string]$combo.SelectedItem.Content }
    } catch {}
    return ''
}

$requiredFields = @($cfg.requiredFields)
$validate = {
    # A field counts as filled unless it is listed in requiredFields and empty.
    $values = @{
        nama       = $nama.Text
        nim        = $nim.Text
        access     = (Get-ComboText $access)
        purpose    = (Get-ComboText $tujuan)
        keterangan = $ket.Text
    }
    $ok = $true
    foreach ($field in $requiredFields) {
        if ([string]::IsNullOrWhiteSpace([string]$values[$field])) { $ok = $false; break }
    }
    $btn.IsEnabled = $ok
    if ($ok) {
        $btn.Opacity = 1.0
        $hint.Text = [string]$cfg.text.hintReady
    } else {
        $btn.Opacity = 0.45
        $hint.Text = [string]$cfg.text.hintIncomplete
    }
}
@($nama,$nim,$ket) | ForEach-Object { $_.Add_TextChanged($validate) }
$tujuan.Add_TextInput($validate)
$tujuan.Add_KeyUp($validate)
$tujuan.Add_SelectionChanged($validate)
$tujuan.Add_DropDownClosed($validate)
$access.Add_SelectionChanged($validate)
& $validate

$window.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape' -or (($e.SystemKey -eq 'F4') -and (($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0))) {
        $e.Handled = $true
    }
})
$window.Add_Closing({ param($sender, $e) if (-not $script:submitted) { $e.Cancel = $true } })

$btn.Add_Click({
    try {
        Ensure-LogbookDirs
        $btn.IsEnabled = $false
        $btn.Content = 'Menyimpan...'
        Invoke-LogbookStartSession -Nama $nama.Text -Nim $nim.Text -Access (Get-ComboText $access) -Tujuan (Get-ComboText $tujuan) -Keterangan $ket.Text | Out-Null
        $script:submitted = $true
        # Session started and the timer process is launching; wait for it to
        # actually reach the screen (Invoke-LogbookHandoffToTimer), THEN
        # collapse this form -- so the two windows' animations line up
        # instead of racing on unrelated fixed schedules. Deliberately no
        # `finally` re-enabling the button on this path: Invoke-
        # LogbookHandoffToTimer's poll is non-blocking and can take up to
        # ~1.8s, and this form is about to fade+close anyway, so leaving
        # the button disabled/"Menyimpan..." for that stretch is invisible
        # to the user and closes off a double-click starting a SECOND
        # session (a fresh session_id + a second Start-LogbookTimer, which
        # would kill and replace the first timer mid-handoff) during the wait.
        Invoke-LogbookHandoffToTimer $window
    } catch {
        Write-LogbookError "Submit failed but form released: $($_.Exception.Message)"
        $script:submitted = $true
        try { $btn.Content = 'Mulai sesi'; $btn.IsEnabled = $true } catch {}
        try { $window.Close() } catch {}
    }
})

# Gate Task Manager for the duration of the sign-in prompt so the process
# can't be bypassed by killing it via Task Manager; always restored in
# `finally`, which runs on submit, on a caught exception, and on any
# unhandled exception that unwinds out of ShowDialog().
try {
    Set-TaskManagerDisabled -Disabled $true
    # Kiosk lockdown while the form is up (skipped in TestMode so a tester is
    # never trapped). Always released in the finally, whatever happens.
    if (-not $TestMode) { Enable-LogbookKeyboardLockdown }
    $nama.Focus() | Out-Null
    [void]$window.ShowDialog()
} catch {
    # FAIL OPEN, ON THE RECORD.
    #
    # This is the gate to a lab workstation. If it throws, the two bad outcomes
    # are (a) a student stuck at a machine they cannot use, staring at a
    # PowerShell stack trace, and (b) the machine's usage vanishing from the
    # logbook because nothing recorded it. The second is what used to happen
    # silently. Neither is acceptable, so: let them work, register the session
    # as identity_source='unverified' so the hours are still counted and
    # visibly attributed to nobody, and say so in words a student can act on.
    #
    # The finally below still runs, so Task Manager and the keyboard are
    # released no matter which way this goes -- a crashed popup must never
    # leave a workstation locked down.
    $reason = $_.Exception.Message
    Write-LogbookError "Sign-in popup failed: $reason"
    if (-not $TestMode) {
        Register-LogbookUnverifiedSession -Reason $reason | Out-Null
        Show-LogbookSignInFailureNotice -Reason $reason
    }
} finally {
    Disable-LogbookKeyboardLockdown
    Set-TaskManagerDisabled -Disabled $false
}
