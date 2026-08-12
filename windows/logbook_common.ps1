# MindLab Report Logbook common helpers v5.7
$ErrorActionPreference = 'Stop'

# Program scripts live in $Global:InstallDir (Program Files) -- read-only at
# runtime, written only by the elevated installer. All WRITABLE runtime state
# (session.json, timer.pid, the error log, markers) lives in $Global:StateDir
# under %ProgramData%, which the non-elevated agent can create and modify. The
# error log was historically in the program dir (C:\lab); it moved to StateDir
# because Program Files is not writable by the standard-user runtime.
$Global:InstallDir = 'C:\Program Files\Logix'
$Global:LabDir = $Global:InstallDir   # back-compat alias for older references
$Global:StateDir = Join-Path $env:ProgramData 'MindLabLogbook'
$Global:SessionFile = Join-Path $Global:StateDir 'session.json'
$Global:ErrorLog = Join-Path $Global:StateDir 'logbook_error.log'
$Global:PopupLock = Join-Path $Global:StateDir 'popup.lock'

function Write-LogbookError {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
        # Size-capped with a single .old rotation: a workstation whose
        # configured server is unreachable logs a heartbeat failure every
        # ~5 seconds, which unbounded would grow this file by hundreds of
        # MB per year on a machine nobody looks at. 1 MB current + 1 MB
        # .old keeps months of context while bounding disk use at ~2 MB.
        $item = Get-Item -LiteralPath $Global:ErrorLog -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 1MB) {
            Move-Item -LiteralPath $Global:ErrorLog -Destination "$Global:ErrorLog.old" -Force -ErrorAction SilentlyContinue
        }
        "$(Get-Date -Format o) $Message" | Out-File -FilePath $Global:ErrorLog -Append -Encoding UTF8
    } catch {}
}

function Write-LogbookInfo {
    param([string]$Message)
    Write-LogbookError "INFO: $Message"
}

# Only the writable StateDir is created at runtime; InstallDir (Program Files)
# is provisioned by the elevated installer, not here.
function Ensure-LogbookDirs {
    New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
}

function Test-AnyDeskInteractiveWindow {
    if ($env:LOGBOOK_FORCE_ANYDESK -eq '1') { return $true }
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -like 'AnyDesk*' -and
            -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
        })
        foreach ($p in $procs) {
            $title = [string]$p.MainWindowTitle
            if ($title -match '(?i)(anydesk|session|connected|remote|incoming|desk)') {
                return $true
            }
        }
    } catch {}
    return $false
}

function Get-LogbookSessionType {
    if (Test-AnyDeskInteractiveWindow) { return @('AnyDesk', 1) }
    return @('Physical', 0)
}

function Get-ProcessByCommandPattern {
    param([string]$Pattern)
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.CommandLine -match $Pattern
        })
    } catch {
        return @()
    }
}

# Every background powershell.exe the agent spawns MUST go through this
# helper, for two reasons discovered the hard way:
#
# 1) QUOTING. Windows PowerShell 5.1's Start-Process joins -ArgumentList
#    elements with spaces WITHOUT quoting them, so
#    @('-File','C:\Program Files\Logix\x.ps1') reaches the child as
#    -File C:\Program Files\Logix\x.ps1 and powershell.exe exits
#    immediately with "C:\Program does not exist" (observed exit code
#    -196608, nothing runs). This silently broke every internal spawn the
#    moment the install moved from C:\lab (no spaces) to
#    C:\Program Files\Logix -- the long-unexplained field reports of "no
#    popup or timer after lock/unlock". This helper quotes any element
#    containing whitespace before it hits the command line.
#
# 2) NO WINDOW. -WindowStyle Hidden alone is not reliable on Windows 11:
#    when Windows Terminal is the default terminal host (the out-of-box
#    resolution of "Let Windows decide" on current builds), consoles
#    spawned by Task Scheduler / Run keys / Start-Process can still open
#    a visible terminal tab. Routing the launch through
#    "conhost.exe --headless" forces a windowless pseudo-console that WT
#    delegation never touches. --headless exists on every supported build
#    (Windows 10 1809+; anything older is EOL and was never a lab target),
#    so no OS-version gate -- the only fallback is conhost.exe being
#    absent entirely, where the plain hidden launch is the best we can do.
#
# Resolved once at dot-source time: this helper funnels every agent spawn
# (popup/timer/end/setup/screenshot), so a per-call Test-Path would be a
# recurring wasted syscall.
$script:HeadlessConhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
if (-not (Test-Path $script:HeadlessConhost)) { $script:HeadlessConhost = $null }

function Start-HiddenPowerShell {
    param(
        [Parameter(Mandatory=$true)][string[]]$ArgumentList,
        [switch]$Wait,
        [switch]$PassThru
    )
    $quoted = @($ArgumentList | ForEach-Object {
        if ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"{0}"' -f $_ } else { $_ }
    })
    if ($script:HeadlessConhost) {
        # NOTE: with the conhost wrapper, -PassThru returns conhost's process,
        # not the powershell child's. Everything that stops agent processes
        # already matches on the child's command line
        # (Get-ProcessByCommandPattern), and killing either side takes the
        # other down with it, so that is fine -- just don't treat the returned
        # Id as powershell's PID.
        return Start-Process -FilePath $script:HeadlessConhost -Wait:$Wait -PassThru:$PassThru `
            -ArgumentList (@('--headless', 'powershell.exe') + $quoted)
    }
    return Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -Wait:$Wait -PassThru:$PassThru -ArgumentList $quoted
}

function Stop-LogbookTimers {
    try {
        $procs = Get-ProcessByCommandPattern 'logbook_timer\.ps1'
        foreach ($p in $procs) {
            if ([int]$p.ProcessId -ne [int]$PID) {
                Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
        $pidFile = Join-Path $Global:StateDir 'timer.pid'
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } catch { Write-LogbookError "Stop timers failed: $($_.Exception.Message)" }
}

function Test-LogbookPopupRunning {
    $procs = Get-ProcessByCommandPattern 'logbook_popup\.ps1'
    foreach ($p in $procs) {
        if ([int]$p.ProcessId -ne [int]$PID) { return $true }
    }
    return $false
}

# Install-time-only, must run elevated. The popup/monitor run as a normal
# (often non-admin) user at runtime, and by default that account cannot
# write HKCU:\...\Policies\System even in its own hive (Windows locks that
# subtree down for exactly this reason). Elevation preserves the calling
# user's identity (HKCU still resolves to the same account, just with an
# elevated token - see the existing HKCU:\...\Run write a few lines below
# this function's caller), so this grants that one specific account just
# enough rights (SetValue + ReadKey on this one key, nothing broader) to
# toggle the sign-in gate at runtime without needing to be an admin.
# Idempotent - safe to call on every install/reinstall.
function Grant-LogbookTaskMgrGateAccess {
    $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
    $identity = "$env:USERDOMAIN\$env:USERNAME"
    try {
        if (-not (Test-Path $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
        $acl = Get-Acl -Path $keyPath
        $already = $acl.Access | Where-Object {
            $_.IdentityReference.Value -eq $identity -and
            $_.AccessControlType -eq 'Allow' -and
            ($_.RegistryRights -band [System.Security.AccessControl.RegistryRights]::SetValue)
        }
        if ($already) {
            Write-LogbookInfo "Task Manager gate: $identity already has write access."
            return
        }
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $identity,
            ([System.Security.AccessControl.RegistryRights]::SetValue -bor [System.Security.AccessControl.RegistryRights]::ReadKey),
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        Set-Acl -Path $keyPath -AclObject $acl
        Write-LogbookInfo "Task Manager gate: granted $identity write access."
    } catch {
        Write-LogbookError "Grant-LogbookTaskMgrGateAccess failed for ${identity}: $($_.Exception.Message)"
    }
}

# Runtime processes (monitor/popup/timer) must be able to DELETE state files in
# $Global:StateDir -- most importantly session.json, whose removal is what
# actually ends a session (SELESAI / END / AUTO_CLOSE / idle-timeout). If any of
# those processes ever ran elevated (an old scheduled task registered with
# -RunLevel Highest, or a manual elevated restart helper), the files it created
# are owned by BUILTIN\Administrators with no delete right for the normal
# interactive account. A later NON-elevated run then logs the END event but
# silently fails to remove session.json, leaving a "zombie" session: its timer
# keeps counting (even from a previous day) and the next unlock shows no sign-in
# form because the popup sees a session still on disk and only resumes the timer.
# This grants the interactive user an inheritable Modify ACE on the state dir so
# every file created there -- whoever creates it -- stays deletable by that user,
# and repairs any children already orphaned by a past elevated run. Install-time
# only: resetting admin-owned children requires running elevated.
function Grant-LogbookStateDirAccess {
    $identity = "$env:USERDOMAIN\$env:USERNAME"
    try {
        New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
        $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
                   [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $acl = Get-Acl -Path $Global:StateDir
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::Modify,
            $inherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)))
        Set-Acl -Path $Global:StateDir -AclObject $acl
        # Children created before this ACE never inherited it and may still be
        # admin-owned -- grant the same right on each directly so the current
        # session.json/timer.pid become removable by this account immediately.
        foreach ($child in @(Get-ChildItem -Path $Global:StateDir -Force -ErrorAction SilentlyContinue)) {
            try {
                $childAcl = Get-Acl -Path $child.FullName
                $childAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $identity,
                    [System.Security.AccessControl.FileSystemRights]::Modify,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
                Set-Acl -Path $child.FullName -AclObject $childAcl
            } catch {
                Write-LogbookError "State dir child ACL repair failed for $($child.FullName): $($_.Exception.Message)"
            }
        }
        Write-LogbookInfo "State dir access ensured for $identity on $Global:StateDir."
    } catch {
        Write-LogbookError "Grant-LogbookStateDirAccess failed for ${identity}: $($_.Exception.Message)"
    }
}

# Gate Task Manager while the sign-in popup is showing, using the standard
# Windows policy Task Manager itself honors (shows "disabled by your
# administrator" instead of opening) rather than fighting the process.
# Scoped to the interactive user only (HKCU), and restores whatever value
# was there before (so it doesn't clobber a real admin/GPO-managed setting).
# Always call this in a try/finally around the popup's ShowDialog() so it
# is restored on every exit path, including exceptions.
function Set-TaskManagerDisabled {
    param([bool]$Disabled)
    $markerPath = Join-Path $Global:StateDir 'taskmgr_prev_value.txt'
    try {
        # HKCU\...\Policies\System is one of the few HKCU keys the user does
        # NOT own by default (policy keys are admin-writable only, even under
        # HKCU). The elevated install grants this account a narrow
        # SetValue+ReadKey ACE (Grant-LogbookTaskMgrGateAccess), but the
        # registry provider cmdlets (New-ItemProperty/Remove-ItemProperty)
        # open the key requesting broader rights than that ACE covers and
        # fail with "Requested registry access is not allowed" -- observed
        # live from the (non-elevated) popup. Open the key via .NET with
        # exactly the rights the ACE grants instead. The key itself exists
        # after install (the elevated grant creates it), so no create path
        # is needed here.
        $rights = [System.Security.AccessControl.RegistryRights]::QueryValue -bor
                  [System.Security.AccessControl.RegistryRights]::SetValue
        # ReadWriteSubTree (not Default): the OS-level open uses exactly
        # $rights either way, but with Default the managed RegistryKey is
        # flagged read-only and SetValue/DeleteValue throw "Cannot write to
        # the registry key" before ever reaching the OS.
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            'Software\Microsoft\Windows\CurrentVersion\Policies\System',
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $rights)
        if (-not $key) {
            if ($Disabled) { Write-LogbookError 'Task Manager gate: policy key missing (run the installer to create it); leaving Task Manager enabled.' }
            return
        }
        try {
            if ($Disabled) {
                $prevObj = $key.GetValue('DisableTaskMgr', $null)
                $prev = if ($null -ne $prevObj) { "$prevObj" } else { 'none' }
                New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
                $prev | Out-File -FilePath $markerPath -Encoding UTF8 -Force
                $key.SetValue('DisableTaskMgr', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
                Write-LogbookInfo "Task Manager disabled for sign-in gate."
            } else {
                $restoreVal = 'none'
                if (Test-Path $markerPath) {
                    $restoreVal = (Get-Content $markerPath -Raw -ErrorAction SilentlyContinue).Trim()
                }
                if ([string]::IsNullOrWhiteSpace($restoreVal) -or $restoreVal -eq 'none') {
                    # DeleteValue needs only KEY_SET_VALUE, same as SetValue.
                    $key.DeleteValue('DisableTaskMgr', $false)
                } else {
                    $key.SetValue('DisableTaskMgr', [int]$restoreVal, [Microsoft.Win32.RegistryValueKind]::DWord)
                }
                Remove-Item -Path $markerPath -Force -ErrorAction SilentlyContinue
                Write-LogbookInfo "Task Manager restored to prior state."
            }
        } finally {
            $key.Close()
        }
    } catch {
        Write-LogbookError "Task Manager policy toggle failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Kiosk keyboard lockdown for the sign-in form. A WH_KEYBOARD_LL low-level
# hook that swallows the window-management chords a user could otherwise use
# to escape the fullscreen sign-in prompt before starting a session:
#   Win (either) + any key   Win+Tab (Task View), Win+D, Win+E, Win+R, and
#                            the bare Start menu.
#   Alt + Tab                classic window switch.
#   Alt + Esc / Ctrl + Esc   cycle windows / open Start.
#   Alt + F4 / Escape        close / dismiss (the form's own KeyDown also
#                            eats these once focused; the hook covers the
#                            pre-focus window too).
# It deliberately does NOT touch Ctrl+Alt+Del: the Secure Attention Sequence
# is enforced by the OS in kernel mode and is unblockable from user mode by
# design -- the Task Manager gate (Set-TaskManagerDisabled) is the paired
# mitigation for that path. Pairs exactly like that gate: installed right
# before ShowDialog and ALWAYS removed in a finally, so a crash or force-kill
# can never leave the keyboard permanently trapped.
#
# The hook proc lives in a compiled C# type (not a PowerShell delegate): the
# callback is held in a static field so the GC can never collect it mid-hook
# (a classic cause of a hard crash), and the low-level hook is called back on
# THIS thread -- the WPF Dispatcher message loop that ShowDialog runs pumps
# it, so no extra message loop is needed.
$script:LogixKioskHookType = $null
function Initialize-LogbookKioskHookType {
    if ($script:LogixKioskHookType) { return $true }
    if ('LogixKioskHook' -as [type]) { $script:LogixKioskHookType = [LogixKioskHook]; return $true }
    $src = @'
using System;
using System.Runtime.InteropServices;

public static class LogixKioskHook {
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int VK_TAB = 0x09;
    private const int VK_ESCAPE = 0x1B;
    private const int VK_LWIN = 0x5B;
    private const int VK_RWIN = 0x5C;
    private const int VK_F4 = 0x73;
    private const int VK_CONTROL = 0x11;
    private const int VK_MENU = 0x12;   // Alt

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT {
        public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    private static IntPtr _hook = IntPtr.Zero;
    // Rooted in a static field so it is never garbage-collected while installed.
    private static readonly LowLevelKeyboardProc _proc = HookCallback;

    public static bool Install() {
        if (_hook != IntPtr.Zero) return true;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
        return _hook != IntPtr.Zero;
    }

    public static void Uninstall() {
        if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
    }

    private static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = wParam.ToInt32();
            if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
                KBDLLHOOKSTRUCT kb = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                int vk = (int)kb.vkCode;
                bool alt = Down(VK_MENU);
                bool ctrl = Down(VK_CONTROL);
                bool win = Down(VK_LWIN) || Down(VK_RWIN);
                if (vk == VK_LWIN || vk == VK_RWIN) return (IntPtr)1;   // any Win chord
                if (win) return (IntPtr)1;
                if (alt && vk == VK_TAB) return (IntPtr)1;              // Alt+Tab
                if (alt && vk == VK_ESCAPE) return (IntPtr)1;           // Alt+Esc
                if (ctrl && vk == VK_ESCAPE) return (IntPtr)1;          // Ctrl+Esc
                if (alt && vk == VK_F4) return (IntPtr)1;               // Alt+F4
                if (vk == VK_ESCAPE) return (IntPtr)1;                  // bare Escape
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }
}
'@
    try {
        Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
        $script:LogixKioskHookType = [LogixKioskHook]
        return $true
    } catch {
        Write-LogbookError "Kiosk hook compile failed (lockdown disabled, form still works): $($_.Exception.Message)"
        return $false
    }
}

function Enable-LogbookKeyboardLockdown {
    try {
        if (-not (Initialize-LogbookKioskHookType)) { return $false }
        $ok = [LogixKioskHook]::Install()
        if ($ok) { Write-LogbookInfo 'Kiosk keyboard lockdown enabled.' }
        else { Write-LogbookError 'Kiosk keyboard lockdown: SetWindowsHookEx returned null (continuing without it).' }
        return $ok
    } catch {
        Write-LogbookError "Enable-LogbookKeyboardLockdown failed: $($_.Exception.Message)"
        return $false
    }
}

function Disable-LogbookKeyboardLockdown {
    # Idempotent and never throws -- this is the safety valve that guarantees
    # the keyboard is released even if the caller hit an exception.
    try {
        if ('LogixKioskHook' -as [type]) { [LogixKioskHook]::Uninstall() }
    } catch {
        Write-LogbookError "Disable-LogbookKeyboardLockdown failed: $($_.Exception.Message)"
    }
}

function Start-LogbookTimer {
    param([string]$SessionId = '')
    try {
        Stop-LogbookTimers
        # Cleared here, not just written fresh by the new process, so
        # logbook_popup.ps1's handoff poll (Invoke-LogbookHandoffToTimer)
        # can never read a STALE flag left by a PREVIOUS timer launch as
        # this one's readiness signal -- there would otherwise be a window,
        # between "old timer killed, new one about to spawn" and "the new
        # one reaches Loaded", where a leftover flag makes the popup fade
        # out before anything new is actually on screen.
        Remove-Item (Join-Path $Global:StateDir 'timer_ready.flag') -Force -ErrorAction SilentlyContinue
        $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\Program Files\Logix\logbook_timer.ps1')
        if ($SessionId) { $args += @('-SessionId', $SessionId) }
        $timer = Start-HiddenPowerShell -PassThru -ArgumentList $args
        # With the conhost wrapper this records the wrapper's PID, not
        # powershell's -- fine, Stop-LogbookTimers matches on command line.
        $pidFile = Join-Path $Global:StateDir 'timer.pid'
        $timer.Id | Out-File -FilePath $pidFile -Encoding ascii -Force
        return $true
    } catch {
        Write-LogbookError "Timer start failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-LogbookPopup {
    param([switch]$ForceNew, [switch]$TestMode)
    try {
        if (Test-LogbookPopupRunning) { return $true }
        $args = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','C:\Program Files\Logix\logbook_popup.ps1')
        if ($ForceNew) { $args += '-ForceNew' }
        if ($TestMode) { $args += '-TestMode' }
        # The hidden launch hides only the powershell CONSOLE window, not the
        # WPF form the popup opens with ShowDialog() -- the timer widget launches
        # exactly this way and renders fine. Keeps a stray console from sitting
        # on the user's desktop for the whole session.
        Start-HiddenPowerShell -ArgumentList $args | Out-Null
        return $true
    } catch {
        Write-LogbookError "Popup start failed: $($_.Exception.Message)"
        return $false
    }
}

# Whether to route bridge events through WSL (lab workstations, dual-boot
# boxes with a distro already set up for SSH logging) or call the native
# Python core directly (everything else, notably loaned/rented laptops --
# they typically have no WSL distro installed at all, which makes the WSL
# call fail outright; see logbook_error.log "no installed distributions").
# install/install.py already deploys log_physical.py + paths.py natively to
# LOGIX_HOME on every OS, so native is the safe default; WSL is opt-in via
# LOGIX_USE_WSL=1 in config.env (set by install_logbook_tasks.ps1 -UseWSL).
function Test-LogbookUseWSL {
    $val = Get-LogbookConfigEnv 'LOGIX_USE_WSL'
    return ($val -eq '1' -or $val -eq 'true')
}

function Get-LogixCoreDir {
    $logixHome = Get-LogbookConfigEnv 'LOGIX_HOME'
    if ($logixHome) { return $logixHome }
    return (Join-Path $env:ProgramData 'Logix')
}

function Find-LogixPython {
    foreach ($cmd in @('python', 'py')) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }
    return $null
}

function Invoke-WSLBridge {
    param([string]$PayloadPath, [string]$Event, [string]$SessionId)
    $wslPayloadPath = '/mnt/c/ProgramData/MindLabLogbook/' + (Split-Path $PayloadPath -Leaf)
    $output = & wsl.exe -u root -e /usr/bin/python3 /opt/software/logix/log_physical.py --json-file $wslPayloadPath 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-LogbookError "WSL root log returned exit code $rc for event $Event. Output: $output"
        $output = & wsl.exe -e /usr/bin/python3 /opt/software/logix/log_physical.py --json-file $wslPayloadPath 2>&1
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            Write-LogbookError "WSL user log returned exit code $rc for event $Event. Output: $output"
            return $false
        }
    }
    Write-LogbookInfo "WSL log OK event=$Event sid=$SessionId Output: $output"
    return $true
}

function Invoke-NativeBridge {
    param([string]$PayloadPath, [string]$Event, [string]$SessionId)
    $python = Find-LogixPython
    if (-not $python) {
        Write-LogbookError "Native bridge: no python/py found on PATH for event $Event"
        return $false
    }
    $script = Join-Path (Get-LogixCoreDir) 'log_physical.py'
    if (-not (Test-Path $script)) {
        Write-LogbookError "Native bridge: log_physical.py not found at $script (run install/install.py on this machine first) for event $Event"
        return $false
    }
    # Local ErrorActionPreference override: this file sets 'Stop' globally, and
    # under 'Stop' any stderr line from a native exe (2>&1) -- even a benign
    # informational one, like log_physical.py's local_only privacy notice --
    # gets promoted from a non-terminating to a terminating error and throws,
    # masquerading as a bridge failure. $LASTEXITCODE is the real signal.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $python $script --json-file $PayloadPath 2>&1
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($rc -ne 0) {
        Write-LogbookError "Native bridge returned exit code $rc for event $Event. Output: $output"
        return $false
    }
    Write-LogbookInfo "Native bridge log OK event=$Event sid=$SessionId Output: $output"
    return $true
}

function Invoke-WSLLogbook {
    param(
        [Parameter(Mandatory=$true)][string]$Event,
        [string]$SessionType = '',
        [int]$AnyDeskDetected = 0,
        [string]$SessionId = '',
        [string]$Nama = '',
        [string]$Nim = '',
        [string]$Tujuan = '',
        [string]$Keterangan = '',
        # See BASE_COLUMNS in log_physical.py. Only the fail-open path passes
        # anything other than the default.
        [ValidateSet('self_declared', 'unverified', 'directory')]
        [string]$IdentitySource = 'self_declared',
        [string]$PersonRole = ''
    )
    Ensure-LogbookDirs
    $winUser = "$env:USERDOMAIN\$env:USERNAME"
    $payloadPath = Join-Path $Global:StateDir ("payload-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $payload = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        event = $Event
        username = $env:USERNAME
        windows_user = $winUser
        hostname = $env:COMPUTERNAME
        session_type = $SessionType
        source = 'windows_wpf'
        session_id = $SessionId
        nama = $Nama
        nim = $Nim
        tujuan = $Tujuan
        keterangan = $Keterangan
        anydesk_detected = $AnyDeskDetected
        identity_source = $IdentitySource
        person_role = $PersonRole
    }
    try {
        $payload | ConvertTo-Json -Depth 5 | Out-File -FilePath $payloadPath -Encoding UTF8 -Force
        Write-LogbookInfo "Bridge payload event=$Event sid=$SessionId nama=$Nama nim=$Nim tujuan=$Tujuan"
        if (Test-LogbookUseWSL) {
            return Invoke-WSLBridge -PayloadPath $payloadPath -Event $Event -SessionId $SessionId
        }
        return Invoke-NativeBridge -PayloadPath $payloadPath -Event $Event -SessionId $SessionId
    } catch {
        Write-LogbookError "Bridge log error for event ${Event}: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $payloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-LogbookDefaultConfig {
    # Built-in defaults. With no config file present the popup renders
    # these out of the box.
    return @{
        branding = @{
            logoText = 'Logix'
            logoPath = 'C:\Program Files\Logix\logo.png'
            title    = 'Report Logbook'
            subtitle = 'Computational Workstation'
            # LogiX Client Foundation palette (docs/design/LogiX Client
            # Foundation.dc.html): "Blue is the direction; everything else is a
            # theme." Accent #2563EB on a deep-navy surface ramp. Maroon retired.
            # A lab re-themes by overriding any of these in config -- absent keys
            # fall back to these defaults via Get-LogbookTheme.
            colors   = @{
                primary         = '#0E1626'  # elevated surface (cards / inputs)
                accent          = '#2563EB'  # brand blue
                muted           = '#93A1B8'  # muted text / hairline captions
                text            = '#EEF3FB'  # primary text
                surface         = '#070C15'  # deepest surface (fullscreen popup)
                surfaceWidget   = '#0B1017'  # corner timer widget surface
                surfaceElevated = '#0E1626'  # raised panels / inputs
                border          = '#223451'  # 1px hairline border
            }
            # Solid "signal bar" colors -- status is a colored edge on a calm
            # surface, never a tinted card. Normal/Notice/Warning/Critical.
            signals  = @{
                normal   = '#22C55E'  # session running
                notice   = '#3B82F6'  # privacy / screenshot (calm, never red)
                warning  = '#F59E0B'  # attention
                critical = '#EF4444'  # power countdown / urgent
            }
        }
        text = @{
            intro          = 'Isi data penggunaan workstation sebelum memulai sesi.'
            startHint      = 'Waktu mulai akan dicatat saat tombol Mulai sesi ditekan.'
            namaLabel      = 'Nama Pengguna'
            nimLabel       = 'NIM/NIP/NIK'
            accessLabel    = 'Tipe Akses'
            purposeLabel   = 'Tujuan Penggunaan'
            ketLabel       = 'Keterangan Kegiatan'
            submit         = 'Mulai Sesi'
            hint           = 'Mohon isi data dengan benar dan selengkap mungkin, apabila ada error atau kesalahan, segera hubungi admin.'
            hintIncomplete = 'Lengkapi Nama, NIM/ID, tipe akses, tujuan, dan keterangan.'
            hintReady      = 'Siap disimpan. Tuliskan keterangan kegiatan sedetail mungkin agar mudah dipahami admin -- hanya nama, NIM, tipe akses, tujuan, dan keterangan yang dicatat, bukan aktivitas di layar Anda.'
            # --- Client Copy Deck (docs/design/LogiX Copy Deck.dc.html) ---
            # Returning-user fast path (C8.1)
            welcomeBack      = 'Lanjutkan sesi Anda'
            continueAs       = 'Lanjut sebagai {0}'
            notYou           = 'Bukan saya / ganti data'
            whatsRecorded    = 'Apa yang dicatat?'
            privacyOneLiner  = 'Siapa, cara & kapan - bukan ketikan.'
            # Timer widget (C8.2)
            timerEnd         = 'SELESAI'
            # The button says what the gesture IS, not just what it does. A pill
            # labelled only 'SELESAI' promises a tap, so the first tap -- which
            # correctly does nothing -- reads as a broken button; the label is
            # the cheapest place to fix that, and it fixes it before the press
            # rather than during it. timerEnd stays as the bare verb because
            # other surfaces (the preview client) present it as a plain button.
            timerEndHold     = 'Tahan untuk selesai'
            timerEndArmed    = 'Terus tahan...'
            timerEndDone     = 'Sesi selesai'
            timerNama        = 'Nama'
            timerTujuan      = 'Tujuan'
            timerPerangkat   = 'Perangkat'
            # Multi-monitor picker (only rendered when there are 2+ displays)
            monitorPicker    = 'Tampilkan di'
            # Notifications (C8.3)
            msgFromAdmin     = 'Pesan dari Admin'
            msgReply         = 'Balas'
            msgClose         = 'Tutup'
            noticePrivacyTitle = 'Pemberitahuan Privasi'
            noticeScreenshot = 'Admin baru saja mengambil tangkapan layar perangkat ini untuk keperluan pemantauan.'
            noticeAlwaysTold = 'Anda selalu diberi tahu - tidak pernah diam-diam.'
            noticeAck        = 'Mengerti'
            emergencyTitle   = 'Peringatan Sistem'
            emergencyBody    = 'Perangkat ini akan dimatikan oleh admin. Simpan pekerjaan Anda sekarang.'
            emergencySaved   = 'Saya sudah menyimpan'
            # Lock overlay (C8.4)
            lockTitle        = 'Workstation dikunci oleh admin lab'
            lockPausedNote   = 'Sesi Anda dijeda, bukan diakhiri. Semua pekerjaan & waktu sesi tetap tersimpan.'
            lockPausedBadge  = 'DIJEDA'
            lockElapsedLabel = 'Waktu sesi berjalan'
            lockUserLabel    = 'Pengguna'
            lockReasonLabel  = 'Alasan dari admin'
            lockUnlockHint   = 'Masuk kembali untuk melanjutkan sesi'
            lockUnlockBtn    = 'Buka & Lanjutkan'
            # Setup wizard (C8.4)
            setupWelcomeBody = 'Daftarkan komputer ini ke server lab agar sesi & kehadiran tercatat otomatis. Butuh kode undangan dari admin.'
            setupStart       = 'Mulai'
            setupSkip        = 'Lewati (mode lokal saja)'
            setupCodeTitle   = 'Masukkan kode undangan'
            setupCodeHint    = 'Minta kode dari admin lab. Berlaku 15 menit & hanya sekali pakai.'
            setupVerify      = 'Verifikasi'
            setupConfirmTitle = 'Konfirmasi perangkat'
            setupFinish      = 'Selesaikan Pengaturan'
            # English locale (future). Get-LogbookText falls back to the ID
            # string above for any key missing here, so 'en' is safe to grow
            # incrementally.
            en = @{
                intro          = 'Fill in your session details to start using this workstation.'
                submit         = 'Start Session'
                hintIncomplete = 'Please complete name, ID, access type, purpose, and notes.'
                hintReady      = 'Ready to save. Describe your activity in as much detail as you can -- only your name, ID, access type, purpose, and notes are recorded, never what is on your screen.'
                welcomeBack    = 'Continue your session'
                continueAs     = 'Continue as {0}'
                notYou         = 'Not you / change details'
                whatsRecorded  = "What's recorded?"
                timerEnd       = 'END'
                timerEndHold   = 'Hold to end session'
                timerEndArmed  = 'Keep holding...'
                timerEndDone   = 'Session ended'
                timerNama      = 'Name'; timerTujuan = 'Purpose'; timerPerangkat = 'Device'
                monitorPicker  = 'Show on'
                msgFromAdmin   = 'Message from Admin'; msgReply = 'Reply'; msgClose = 'Close'
                noticePrivacyTitle = 'Privacy Notice'
                noticeAlwaysTold = 'You are always notified - never silently.'
                noticeAck      = 'Got it'
                emergencyTitle = 'System Alert'
                emergencySaved = 'I have saved'
                lockTitle      = 'Workstation locked by the lab admin'
                lockPausedBadge = 'PAUSED'
                lockUnlockBtn  = 'Unlock & Resume'
                setupStart     = 'Start'; setupVerify = 'Verify'; setupFinish = 'Finish Setup'
            }
        }
        # UI language for client surfaces. 'id' (default) or 'en'. Resolved by
        # Get-LogbookText, which falls back to the ID string for any key the
        # chosen locale hasn't translated yet.
        locale         = 'id'
        accessTypes    = @('Physical', 'AnyDesk')
        purposes       = @('Visualisasi Data', 'Running Data', 'Maintenance')
        requiredFields = @('nama', 'nim', 'access', 'purpose', 'keterangan')
    }
}

function ConvertTo-LogbookHashtable($obj) {
    # JSON -> hashtable/array so config merges and member access stay uniform.
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-LogbookHashtable $p.Value }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return @($obj | ForEach-Object { ConvertTo-LogbookHashtable $_ })
    }
    return $obj
}

function Merge-LogbookConfig($base, $override) {
    # Deep-merge $override into $base. Objects merge key-by-key; arrays/scalars replace.
    if ($null -eq $override) { return $base }
    foreach ($key in @($override.Keys)) {
        if ($base.Contains($key) -and ($base[$key] -is [hashtable]) -and ($override[$key] -is [hashtable])) {
            Merge-LogbookConfig $base[$key] $override[$key]
        } else {
            $base[$key] = $override[$key]
        }
    }
    return $base
}

function Read-LogbookConfigFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content $Path -Raw -Encoding UTF8
        $raw = $raw -replace '^', ''   # tolerate a leading BOM
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ConvertTo-LogbookHashtable ($raw | ConvertFrom-Json)
    } catch {
        Write-LogbookError "Config load failed for ${Path}: $($_.Exception.Message)"
        return $null
    }
}

function Get-LogbookConfigEnv {
    param([string]$Key)
    $envVal = [System.Environment]::GetEnvironmentVariable($Key)
    if ($envVal) { return $envVal }
    # Where config.env lives is resolved from the ENVIRONMENT only, never via
    # Get-LogixCoreDir: that function asks this one for LOGIX_HOME, so routing
    # this lookup back through it is an infinite loop. logix/paths.py breaks
    # the same cycle the same way and already documents both overrides
    # (LOGIX_CONFIG, then the data home) -- the PowerShell side simply never
    # honoured them, so a machine whose core lives anywhere but the default
    # read its settings from a directory it does not use.
    $cfgPath = ''
    $explicit = [System.Environment]::GetEnvironmentVariable('LOGIX_CONFIG')
    if ($explicit -and (Test-Path $explicit)) {
        $cfgPath = $explicit
    } else {
        $home2 = [System.Environment]::GetEnvironmentVariable('LOGIX_HOME')
        if ($home2) { $cfgPath = Join-Path $home2 'config.env' }
    }
    if (-not $cfgPath) { $cfgPath = Join-Path $env:ProgramData 'Logix\config.env' }
    if (Test-Path $cfgPath) {
        try {
            $lines = Get-Content $cfgPath -ErrorAction SilentlyContinue
            if ($lines) {
                foreach ($line in $lines) {
                    $trimmed = $line.Trim()
                    if (-not $trimmed -or $trimmed.StartsWith('#') -or -not $trimmed.Contains('=')) { continue }
                    if ($trimmed.StartsWith('export ')) { $trimmed = $trimmed.Substring(7) }
                    $parts = $trimmed.Split('=', 2)
                    if ($parts.Count -eq 2) {
                        $k = $parts[0].Trim()
                        $v = $parts[1].Trim().Trim("'").Trim('"')
                        if ($k -eq $Key) { return $v }
                    }
                }
            }
        } catch {}
    }
    return ''
}

function Get-AnyDeskId {
    # Check standard per-user and system-wide AnyDesk system.conf files
    $paths = @(
        "$env:PROGRAMDATA\AnyDesk\system.conf",
        "$env:APPDATA\AnyDesk\system.conf"
    )
    foreach ($path in $paths) {
        if (Test-Path $path) {
            try {
                $lines = Get-Content $path -ErrorAction SilentlyContinue
                foreach ($line in $lines) {
                    if ($line -match 'ad\.anydesk\.id=([0-9]+)') {
                        return $Matches[1]
                    }
                }
            } catch {}
        }
    }
    # Check default install locations by calling AnyDesk --get-id
    $anydeskPaths = @(
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
        "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe"
    )
    foreach ($ap in $anydeskPaths) {
        if (Test-Path $ap) {
            try {
                $id = & $ap --get-id 2>$null
                $id = "$id".Trim()
                if ($id -match '^[0-9]+$') { return $id }
            } catch {}
        }
    }
    return ''
}

# What build this agent is. Read from the VERSION file the installer drops
# beside these scripts, so it describes the code actually on disk rather than
# something baked in at build time that a hand-copied file would not update.
# Cached: this is read on every heartbeat.
$script:LogbookAgentVersion = $null
function Get-LogbookAgentVersion {
    if ($null -ne $script:LogbookAgentVersion) { return $script:LogbookAgentVersion }
    $script:LogbookAgentVersion = ''
    foreach ($dir in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent))) {
        if (-not $dir) { continue }
        $candidate = Join-Path $dir 'VERSION'
        if (Test-Path $candidate) {
            try {
                $v = (Get-Content $candidate -Raw -ErrorAction Stop).Trim()
                if ($v) { $script:LogbookAgentVersion = $v; break }
            } catch { }
        }
    }
    return $script:LogbookAgentVersion
}

# ---- Sign-in failure policy --------------------------------------------------
#
# The sign-in popup gates access to a lab workstation. When it cannot run, the
# machine must FAIL OPEN: a student in front of a PC they cannot use, with a
# raw PowerShell exception on screen, is a worse outcome than a session whose
# operator is unknown. That was already the de facto behaviour, but silently --
# the popup crashed, nothing recorded it, and the machine's usage simply went
# missing from the logbook.
#
# So: fail open, but ON THE RECORD. Register a session marked
# identity_source='unverified' so the usage is still counted and visibly
# attributed to nobody, log the cause, and tell the user in plain language
# instead of showing them a stack trace.
function Register-LogbookUnverifiedSession {
    param(
        [Parameter(Mandatory)] [string] $Reason
    )
    try {
        $sessionId = [guid]::NewGuid().ToString('N')
        Write-LogbookError "SIGN-IN FAILED OPEN: $Reason (session $sessionId recorded as unverified)"
        # Same bridge an ordinary START uses, so the event queues offline and
        # retries exactly like any other -- a fail-open session must not also
        # be a lost session.
        Invoke-WSLLogbook -Event 'START' -SessionType 'Physical' -SessionId $sessionId `
            -Keterangan "Sesi tanpa verifikasi identitas: $Reason" `
            -IdentitySource 'unverified' | Out-Null
        return $sessionId
    } catch {
        # Even the fallback failing must not block the desktop.
        Write-LogbookError "Failed to register unverified session: $($_.Exception.Message)"
        return $null
    }
}

# Plain-language notice, auto-dismissing, never modal to the desktop. The user
# cannot act on a .NET exception; they can act on "tell the admin".
function Show-LogbookSignInFailureNotice {
    param([string]$Reason = '')
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $tip = New-Object System.Windows.Forms.NotifyIcon
        $tip.Icon = [System.Drawing.SystemIcons]::Warning
        $tip.Visible = $true
        $tip.BalloonTipTitle = 'Logix: pencatatan sesi bermasalah'
        $tip.BalloonTipText = 'Komputer tetap bisa dipakai. Sesi ini tercatat tanpa identitas -- mohon lapor ke admin lab.'
        $tip.ShowBalloonTip(15000)
        Start-Sleep -Seconds 2
        $tip.Dispose()
    } catch {
        Write-LogbookError "Could not show sign-in failure notice: $($_.Exception.Message)"
    }
}

# ---- Status bar bridge (YASB and anything else that can read a file) --------
#
# The floating pill has one unavoidable problem: it is an overlay, so wherever
# it sits it sits ON TOP of something -- and docked to the top edge, that
# something is the browser tab strip. A status bar does not have that problem,
# because a bar RESERVES its space; nothing is ever underneath it.
#
# So the widget publishes its state to a small file and a bar renders it. The
# timer process is already ticking once a second and already knows all of this,
# which is what makes this cheap: the bar runs `type <file>`, not a PowerShell
# process per second.
$Global:LogbookStatusFile = $null
function Get-LogbookStatusFile {
    if (-not $Global:LogbookStatusFile) {
        $Global:LogbookStatusFile = Join-Path $Global:StateDir 'bar_status.json'
    }
    return $Global:LogbookStatusFile
}

# YASB's custom widget with return_format: json reads {"text", "alt", "tooltip"}.
# Written whole via a temp file + move so a bar polling mid-write never reads a
# half-flushed file and renders a blank slot.
function Write-LogbookBarStatus {
    param(
        [string]$Text = '',
        [string]$Alt = '',
        [string]$Tooltip = '',
        [string]$State = 'idle'
    )
    try {
        $path = Get-LogbookStatusFile
        $payload = [ordered]@{
            text    = $Text
            alt     = $Alt
            tooltip = $Tooltip
            # Not read by YASB itself -- it is there so a stylesheet or another
            # bar can colour the slot by session state without parsing the text.
            state   = $State
            updated = (Get-Date).ToString('o')
        }
        $tmp = "$path.tmp"
        # NOT Out-File -Encoding UTF8: in Windows PowerShell 5.1 that always
        # writes a UTF-8 BOM, and YASB's CustomWidget reads this file's output
        # as a decoded string, then calls json.loads() on it. json.loads on a
        # STRING (unlike on raw bytes) throws on a leading BOM -- and does so
        # silently as far as the user can tell: YASB's own error handling
        # catches JSONDecodeError and swaps in None, so the bar just renders
        # the raw "{data[text]}" template forever with no error anywhere.
        # WriteAllText with an explicit no-BOM UTF8Encoding is the same fix
        # this project already uses for its other JSON writes.
        [System.IO.File]::WriteAllText(
            $tmp, ($payload | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch { }
}

# A bar slot showing a stale time is worse than one showing nothing: it says a
# session is running when the agent may have died. Called when the timer exits.
function Clear-LogbookBarStatus {
    try {
        Write-LogbookBarStatus -Text '' -Alt '' -Tooltip 'Tidak ada sesi aktif' -State 'none'
    } catch { }
}

# One-shot action channel from a status bar back to the widget. The bar is a
# separate process with no handle on the widget's window, and the widget is
# already polling once a second, so a file it consumes and deletes is both the
# cheapest and the least stateful thing that can work.
function Request-LogbookBarAction {
    param([ValidateSet('open', 'posture')] [string]$Action)
    try {
        Ensure-LogbookDirs
        $path = Join-Path $Global:StateDir 'bar_action'
        # Temp file plus rename, matching Write-LogbookBarStatus and the copy of
        # this write in logix_yasb.ps1's callback fast path: the widget polls
        # for this file ten times a second, so a reader CAN arrive between the
        # file being created and being written, and it would consume an empty
        # file and drop the request. A rename has no such in-between state.
        $tmp = "$path.tmp"
        $Action | Out-File -FilePath $tmp -Encoding ASCII -Force
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch { }
}

function Read-LogbookBarAction {
    try {
        $path = Join-Path $Global:StateDir 'bar_action'
        if (-not (Test-Path $path)) { return '' }
        $action = (Get-Content $path -Raw -ErrorAction Stop).Trim()
        # Consumed on read: a request that survived would re-fire every second.
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        return $action
    } catch { return '' }
}

function Get-LogbookDeviceApiKey {
    # Per-device key from device.json (written by logbook_setup.ps1 on a
    # successful /api/enroll). Mirrors the server's own verify_api_key
    # fallback order: per-device key first, shared LOGIX_SERVER_API_KEY
    # from config.env as the bootstrap/unenrolled fallback.
    $identityPath = 'C:\ProgramData\Logix\device.json'
    if (Test-Path $identityPath) {
        try {
            $obj = Get-Content $identityPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($obj -and $obj.api_key) { return [string]$obj.api_key }
        } catch {}
    }
    return ''
}

function Get-LogbookDeviceDisplayName {
    # This device's local name preference, same source Send-LogbookHeartbeat
    # sends to the server -- also used by the timer widget so it shows the
    # same name the dashboard does (absent an admin rename; that's a
    # server-side override the agent doesn't need to know about).
    $deviceName = Get-LogbookConfigEnv -Key 'LOGIX_DEVICE_NAME'
    if ([string]::IsNullOrWhiteSpace($deviceName)) { $deviceName = $env:COMPUTERNAME }
    return $deviceName
}

# Writes the single incoming-message drop the timer widget polls each tick and
# shows inline near the clock. allow_reply lets the widget offer a reply box for
# admin messages (BROADCAST) but not for one-way notices (screenshot/power).
function Set-LogbookIncomingMessage {
    param([string]$Text, [string]$Reason = 'Direction Message', [string]$CommandId = '', [bool]$AllowReply = $true)
    Ensure-LogbookDirs
    $msgPath = Join-Path $Global:StateDir 'incoming_message.json'
    @{ text = $Text; reason = $Reason; command_id = $CommandId; allow_reply = $AllowReply; received_at = (Get-Date).ToString('o') } |
        ConvertTo-Json | Out-File -FilePath $msgPath -Encoding UTF8 -Force
}

# Device -> admin message (Logix Control replies). Posts to /api/replies with the
# same credential order as the heartbeat (per-device key first, shared key
# fallback). command_id links a reply back to the broadcast it answers.
function Send-LogbookReply {
    param([Parameter(Mandatory=$true)][string]$Text, [string]$CommandId = '')
    try {
        $serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
        if (-not $serverUrl) { return $false }
        $serverKey = Get-LogbookDeviceApiKey
        if (-not $serverKey) { $serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY' }
        $payload = @{
            hostname    = $env:COMPUTERNAME
            device_name = Get-LogbookDeviceDisplayName
            message     = $Text
            command_id  = $CommandId
        }
        $headers = @{ 'Content-Type' = 'application/json' }
        if ($serverKey) { $headers['X-API-Key'] = $serverKey }
        $apiUrl = $serverUrl.TrimEnd('/') + '/api/replies'
        Invoke-RestMethod -Uri $apiUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 3) -Headers $headers -TimeoutSec 5 -UseBasicParsing | Out-Null
        Write-LogbookInfo "Reply sent to server (command_id: $CommandId)."
        return $true
    } catch {
        Write-LogbookError "Reply send failed: $($_.Exception.Message)"
        return $false
    }
}

# Screen capture lives in its own on-demand script (logbook_screenshot.ps1),
# NOT here: the capture-and-upload pattern trips Windows Defender's AMSI, and
# having it inline would get this whole always-loaded core file blocked as
# "malicious", breaking every agent function. Isolated, only the screenshot
# feature is affected if AV objects, and the SCREENSHOT handler shells out to it.
function Invoke-LogbookScreenshotCapture {
    param([Parameter(Mandatory=$true)][string]$CommandId)
    $script = Join-Path $Global:LabDir 'logbook_screenshot.ps1'
    if (-not (Test-Path $script)) { throw "logbook_screenshot.ps1 not found at $script" }
    Start-HiddenPowerShell -Wait -ArgumentList @(
        '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$script,'-CommandId',$CommandId) | Out-Null
}

function Send-LogbookHeartbeat {
    param(
        [Parameter(Mandatory=$true)][string]$Status
    )
    try {
        $serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
        if (-not $serverUrl) { return }
        $serverKey = Get-LogbookDeviceApiKey
        if (-not $serverKey) { $serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY' }

        $username = $env:USERNAME
        # Session context for the dashboard's Monitoring card -- start time,
        # access type and purpose. Read from the same session file the timer
        # uses; the schema is untouched, these fields already live there.
        $sessionStart = ''
        $accessType = ''
        $purpose = ''
        if (Test-Path $Global:SessionFile) {
            try {
                $s = Get-ActiveLogbookSession
                if ($s -and $s.nama) { $username = $s.nama }
                elseif ($s -and $s.username) { $username = $s.username }
                if ($s -and $s.start_time) { $sessionStart = [string]$s.start_time }
                if ($s -and $s.session_type) { $accessType = [string]$s.session_type }
                if ($s -and $s.tujuan) { $purpose = [string]$s.tujuan }
            } catch {}
        }

        $anydeskId = Get-AnyDeskId
        $deviceName = Get-LogbookDeviceDisplayName

        # Outcomes for commands delivered on a *previous* heartbeat -- see
        # apply_command_acks() server-side. Read what's pending, send it,
        # and only clear the file once the server has actually confirmed
        # receipt (a dropped response leaves it for the next attempt --
        # at-least-once delivery, absorbed by the server's idempotent
        # "AND status = 'queued'" guard on re-application).
        $acksPath = Join-Path $Global:StateDir 'pending_acks.json'
        $pendingAcks = @()
        if (Test-Path $acksPath) {
            try {
                $loaded = Get-Content $acksPath -Raw | ConvertFrom-Json
                if ($loaded) { $pendingAcks = @($loaded) }
            } catch {}
        }

        $payload = @{
            hostname    = $env:COMPUTERNAME
            device_name = $deviceName
            status      = $Status
            username    = $username
            anydesk_id  = $anydeskId
        }
        if ($sessionStart) { $payload['session_started_at'] = $sessionStart }
        if ($accessType)   { $payload['access_type'] = $accessType }
        if ($purpose)      { $payload['purpose'] = $purpose }
        if ($pendingAcks.Count -gt 0) { $payload['acks'] = $pendingAcks }

        # Which build this workstation is on. Without it the dashboard cannot
        # tell a fleet running the current agent from one that quietly drifted
        # -- which is exactly how an install ended up with a sign-in popup
        # three weeks older than the logbook_common.ps1 beside it, found only
        # when it crashed.
        $agentVersion = Get-LogbookAgentVersion
        if ($agentVersion) { $payload['agent_version'] = $agentVersion }
        $payload['agent_os'] = 'windows'
        # This machine's clock, so the server can measure skew. The agent
        # timestamps its own session events, so a wrong clock here files real
        # sessions under the wrong hour -- and across midnight, the wrong day.
        # Nothing downstream can detect that from the data alone.
        $payload['client_time'] = (Get-Date).ToString('o')

        $headers = @{
            'Content-Type' = 'application/json'
        }
        if ($serverKey) { $headers['X-API-Key'] = $serverKey }
        $body = $payload | ConvertTo-Json -Depth 5
        $apiUrl = $serverUrl.TrimEnd('/') + '/api/heartbeat'

        $res = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $body -Headers $headers -TimeoutSec 3 -UseBasicParsing
        # Reaching here means the POST succeeded -- the acks we just sent
        # are now the server's problem.
        if ($pendingAcks.Count -gt 0) {
            Remove-Item $acksPath -Force -ErrorAction SilentlyContinue
        }

        $newAcks = @()
        if ($res -and $res.commands) {
            foreach ($cmd in $res.commands) {
                $name = $cmd.command.ToUpper()
                $param = $cmd.param
                Write-LogbookInfo "Received remote command: $name (param: $param)"

                # Logix Control command dispatch. LOCK/BROADCAST are the
                # originals; SCREENSHOT/SHUTDOWN/RESTART/LOGOFF are the Logix
                # Control additions. All paths ack their outcome; unknown names
                # fail explicitly rather than being silently dropped.
                try {
                    switch ($name) {
                        'LOCK' {
                            Write-LogbookInfo "Remote LOCK trigger execution."
                            Start-HiddenPowerShell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_end.ps1'),'-Reason','LOCK') | Out-Null
                            Start-HiddenPowerShell -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_popup.ps1'),'-ForceNew') | Out-Null
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = '' }
                        }
                        'BROADCAST' {
                            # Drop for the timer widget to show inline near the
                            # clock -- not a separate MessageBox. command_id
                            # rides along so a reply typed into the widget can
                            # reference the exact broadcast it answers. "done"
                            # means the file was written, not that the user saw it.
                            Write-LogbookInfo "Remote message received (reason: $($cmd.reason))."
                            $reason = if ($cmd.reason) { [string]$cmd.reason } else { 'Direction Message' }
                            Set-LogbookIncomingMessage -Text $param -Reason $reason -CommandId ([string]$cmd.command_id)
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = '' }
                        }
                        'SCREENSHOT' {
                            # Transparency first, then capture: the person at the
                            # device always sees a notice that a capture happened
                            # (docs/PRIVACY.md, "never silently").
                            Write-LogbookInfo "Remote SCREENSHOT trigger execution."
                            Set-LogbookIncomingMessage -Text 'Admin baru saja mengambil tangkapan layar perangkat ini untuk keperluan pemantauan.' -Reason 'Screen View Notice' -AllowReply $false
                            Invoke-LogbookScreenshotCapture -CommandId ([string]$cmd.command_id)
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = 'screenshot uploaded' }
                        }
                        'SHUTDOWN' {
                            Write-LogbookInfo "Remote SHUTDOWN trigger execution."
                            Set-LogbookIncomingMessage -Text 'Perangkat ini akan dimatikan oleh admin dalam 30 detik. Simpan pekerjaan Anda sekarang.' -Reason 'Emergency Alert' -AllowReply $false
                            & shutdown.exe /s /t 30 /c 'Logix: perangkat dimatikan oleh admin. Simpan pekerjaan Anda.' | Out-Null
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = 'shutdown scheduled (30s)' }
                        }
                        'RESTART' {
                            Write-LogbookInfo "Remote RESTART trigger execution."
                            Set-LogbookIncomingMessage -Text 'Perangkat ini akan dimulai ulang oleh admin dalam 30 detik. Simpan pekerjaan Anda sekarang.' -Reason 'Emergency Alert' -AllowReply $false
                            & shutdown.exe /r /t 30 /c 'Logix: perangkat dimulai ulang oleh admin. Simpan pekerjaan Anda.' | Out-Null
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = 'restart scheduled (30s)' }
                        }
                        'LOGOFF' {
                            # Close the logbook session cleanly first so hours
                            # aren't lost, then sign the user out.
                            Write-LogbookInfo "Remote LOGOFF trigger execution."
                            Start-HiddenPowerShell -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Global:LabDir 'logbook_end.ps1'),'-Reason','END') | Out-Null
                            & shutdown.exe /l /f | Out-Null
                            $newAcks += @{ command_id = $cmd.command_id; status = 'done'; detail = 'user logged off' }
                        }
                        default {
                            Write-LogbookError "Unknown remote command: $name"
                            $newAcks += @{ command_id = $cmd.command_id; status = 'failed'; detail = "unknown command $name" }
                        }
                    }
                } catch {
                    $newAcks += @{ command_id = $cmd.command_id; status = 'failed'; detail = $_.Exception.Message }
                }
            }
        }

        # Persist immediately after executing, before this function's own
        # outer try/catch has any chance to swallow a later error -- this is
        # what guarantees an outcome is never silently lost. If the file
        # already has unsent acks from an earlier failed delivery attempt,
        # append rather than overwrite.
        if ($newAcks.Count -gt 0) {
            $existing = @()
            if (Test-Path $acksPath) {
                try {
                    $loaded = Get-Content $acksPath -Raw | ConvertFrom-Json
                    if ($loaded) { $existing = @($loaded) }
                } catch {}
            }
            ($existing + $newAcks) | ConvertTo-Json -Depth 5 | Out-File -FilePath $acksPath -Encoding UTF8 -Force
        }
    } catch {
        # Fail silently
    }
}

function Get-LogbookConfig {
    # -MaxCacheAgeSeconds: reuse the cached server config outright when it is
    # younger than this, skipping the network entirely. 0 (the default) keeps
    # the original always-fetch behaviour for callers that must be current.
    #
    # This exists because the sign-in popup blocked on /api/config at every
    # login. With the server reachable that is ~190ms; with it unreachable --
    # a restart, a flaky lab switch, a workstation booting before the server --
    # it is the full timeout, every single time, while a person stares at
    # nothing. The config drives labels and branding, so a slightly stale copy
    # is fine; a slow login is not.
    param([int]$MaxCacheAgeSeconds = 0)

    # Cascading: built-in defaults <- machine config <- per-user config.
    $cfg = Get-LogbookDefaultConfig

    # Try to fetch from central server first.
    $serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
    # Same credential order as Send-LogbookHeartbeat: this device's own key
    # first, the shared bootstrap key only as a fallback. Reading just the
    # shared key was wrong in two ways -- an enrolled device deliberately has
    # it cleared (so config fetches 401'd and silently fell back to a stale
    # cache), and a server running with LOGIX_REQUIRE_DEVICE_KEY=1 refuses the
    # shared key outright.
    $serverKey = Get-LogbookDeviceApiKey
    if (-not $serverKey) { $serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY' }
    $serverCfg = $null
    
    $cachePath = Join-Path $Global:StateDir 'server_config_cache.json'
    
    # A cache young enough for this caller means we never touch the network.
    $cacheAge = $null
    if (Test-Path $cachePath) {
        $cacheAge = ((Get-Date) - (Get-Item $cachePath).LastWriteTime).TotalSeconds
    }
    $useCacheOnly = ($MaxCacheAgeSeconds -gt 0 -and $null -ne $cacheAge -and
                     $cacheAge -ge 0 -and $cacheAge -lt $MaxCacheAgeSeconds)
    if ($useCacheOnly) {
        Write-LogbookInfo ("Config cache is {0:N0}s old (< {1}s) -- skipping the server fetch." -f $cacheAge, $MaxCacheAgeSeconds)
    }

    if ($serverUrl -and -not $useCacheOnly) {
        try {
            $headers = @{}
            if ($serverKey) { $headers['X-API-Key'] = $serverKey }
            $apiUrl = $serverUrl.TrimEnd('/') + '/api/config'
            Write-LogbookInfo "Fetching config from server: $apiUrl"
            # Having a cache to fall back on buys a much shorter wait: 1s is
            # generous for a lab LAN, and losing the race only costs freshness.
            # With no cache at all this is the only source of labels and
            # branding, so give it the full 2s before giving up.
            $timeoutSec = if ($null -ne $cacheAge) { 1 } else { 2 }
            $res = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec $timeoutSec -UseBasicParsing
            if ($res) {
                $serverCfg = ConvertTo-LogbookHashtable $res
                # Save to cache
                New-Item -ItemType Directory -Force -Path $Global:StateDir | Out-Null
                $res | ConvertTo-Json -Depth 5 | Out-File -FilePath $cachePath -Encoding UTF8 -Force
                Write-LogbookInfo "Cached config from server."
            }
        } catch {
            Write-LogbookError "Failed to fetch server config: $($_.Exception.Message). Falling back to cache/local."
        }
    }
    
    # If server fetch failed, try to load from local cache
    if (-not $serverCfg -and (Test-Path $cachePath)) {
        $serverCfg = Read-LogbookConfigFile $cachePath
        if ($serverCfg) {
            Write-LogbookInfo "Applied cached server config."
        }
    }
    
    if ($serverCfg) {
        $cfg = Merge-LogbookConfig $cfg $serverCfg
    }
    
    $machine = Join-Path $Global:LabDir 'logbook_config.json'
    $perUser = Join-Path (Join-Path $env:APPDATA 'MindLabLogbook') 'logbook_config.json'
    foreach ($path in @($machine, $perUser)) {
        $override = Read-LogbookConfigFile $path
        if ($override) {
            $cfg = Merge-LogbookConfig $cfg $override
            Write-LogbookInfo "Applied config override: $path"
        }
    }
    return $cfg
}

function ConvertTo-LogbookXmlText([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Get-LogbookText($cfg, [string]$Key, [string]$Fallback = '') {
    # Resolve a client UI string by key, honoring $cfg.locale ('id' default,
    # 'en' optional). Falls back to the ID string for any key the chosen
    # locale hasn't translated, then to $Fallback. Optional -f args are
    # applied by the caller (these are format templates, e.g. 'Lanjut sebagai {0}').
    $t = $cfg.text
    $locale = [string]$cfg.locale
    if ($locale -eq 'en' -and $t -and $t.en) {
        $en = $t.en
        if ($en.Contains($Key) -and -not [string]::IsNullOrWhiteSpace([string]$en[$Key])) {
            return [string]$en[$Key]
        }
    }
    if ($t -and $t.Contains($Key) -and -not [string]::IsNullOrWhiteSpace([string]$t[$Key])) {
        return [string]$t[$Key]
    }
    return $Fallback
}

function Get-LogbookMixedHex([string]$From, [string]$To, [double]$Amount) {
    # Linear mix of two #RRGGBB strings, returned as #RRGGBB. Used to DERIVE the
    # quiet members of the palette from the loud ones rather than inventing new
    # hex values: a wash is its signal colour laid over the surface it sits on,
    # a soft text is the same colour lifted toward white. That is the whole
    # reason they stay in tune when a faculty rebrand changes the signal, and
    # the reason they cannot drift out of tune by hand-editing.
    #
    # Opaque on purpose, not an alpha brush: the result is composited ONCE here
    # against the surface it is known to sit on, so a fill that grows across a
    # button cannot pick up whatever happens to be behind it.
    # Parsed by hand rather than through a colour helper: this file is dot-
    # sourced by processes that never load System.Drawing or WPF (the monitor,
    # the bar bridge), and adding an assembly load to all of them to mix two
    # numbers would be the expensive way to do arithmetic.
    $parse = {
        param($hex)
        $h = ([string]$hex).Trim().TrimStart('#')
        if ($h.Length -ne 6) { return $null }
        try {
            return @([Convert]::ToInt32($h.Substring(0, 2), 16),
                     [Convert]::ToInt32($h.Substring(2, 2), 16),
                     [Convert]::ToInt32($h.Substring(4, 2), 16))
        } catch { return $null }
    }
    $a = & $parse $From
    $b = & $parse $To
    # A bad override must not take the whole widget down with it.
    if (-not $a -or -not $b) { return $From }
    $t = [Math]::Max(0.0, [Math]::Min(1.0, $Amount))
    $c = 0..2 | ForEach-Object { [int][Math]::Round($a[$_] + ($b[$_] - $a[$_]) * $t) }
    return ('#{0:X2}{1:X2}{2:X2}' -f $c[0], $c[1], $c[2])
}

# ---- Server pairing (Device <-> Server), from the client ---------------------
#
# A Logix Device is a complete product on its own; a server is an OPTIONAL
# layer on top of it. That framing only holds if a device can be joined to a
# server, and unjoined from one, after installation -- by the person using it,
# from the application. Until now enrolment existed only inside the setup
# wizard, which is a thing you run once at install time, and there was no way
# to leave a server at all: changing or dropping one meant hand-editing
# config.env or reinstalling. Both are answers for a maintainer, not a user.
#
# The transport is NOT new. This drives the same POST /api/enroll and the same
# device.json identity file that API_CONTRACT.md already specifies, because a
# second enrolment path would be a second thing to keep secure.

function Set-LogbookConfigValue {
    param([string]$Key, [string]$Value)
    # Canonical runtime writer for config.env. install_logbook_tasks.ps1
    # deliberately keeps its own copy (Set-LogixConfigValue): the installer has
    # to write this file BEFORE the install directory it would load this
    # library from exists. Same semantics on purpose -- if one changes, change
    # both, which is what the check in test_logbook_config.ps1 is for.
    $cfgDir = Get-LogixCoreDir
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfgPath = Join-Path $cfgDir 'config.env'
    $lines = if (Test-Path $cfgPath) { @(Get-Content $cfgPath) } else { @() }
    $pattern = "^\s*#?\s*(?:export\s+)?$Key\s*="
    $found = $false
    # @(...) is load-bearing: without it a 0- or 1-line config.env makes $out a
    # single STRING and += concatenates text instead of appending a line, which
    # welds every key onto one line. Only bites on a fresh machine -- which is
    # exactly the machine being paired for the first time.
    $out = @(foreach ($line in $lines) {
        if ($line -match $pattern) { $found = $true; "$Key=$Value" } else { $line }
    })
    if (-not $found) { $out += "$Key=$Value" }
    $out | Set-Content -Path $cfgPath -Encoding UTF8
}

function Get-LogbookDeviceIdentityPath {
    return (Join-Path (Get-LogixCoreDir) 'device.json')
}

function Get-LogbookPairingState {
    # One place that answers "is this device joined to a server, and which".
    # Deliberately does NOT touch the network: this is the state the UI opens
    # with, and a settings screen that blocks on a dead server before it can
    # draw itself is how "not connected" becomes indistinguishable from "hung".
    $state = [ordered]@{
        Paired    = $false
        ServerUrl = ''
        DeviceId  = ''
        Category  = ''
        HasKey    = $false
    }
    try {
        $url = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
        if ($url) { $state.ServerUrl = $url.Trim() }
        $path = Get-LogbookDeviceIdentityPath
        if (Test-Path $path) {
            $id = Get-Content $path -Raw | ConvertFrom-Json
            $state.DeviceId = [string]$id.device_id
            $state.Category = [string]$id.category
            $state.HasKey = -not [string]::IsNullOrWhiteSpace([string]$id.api_key)
        }
    } catch { }
    # Paired means BOTH halves: an identity without a server URL cannot reach
    # anything, and a URL without an identity is a server we were never let
    # into. Either one alone is a half-finished pairing, and calling that
    # "connected" is how a device silently stops syncing.
    $state.Paired = ($state.ServerUrl -ne '') -and ($state.DeviceId -ne '') -and $state.HasKey
    return $state
}

function Test-LogbookServerReachable {
    param([string]$Url, [int]$TimeoutSec = 8)
    # Checked BEFORE spending an invite code. An invite is single-use
    # (API_CONTRACT.md), so firing one at a typo'd address burns it and the
    # operator has to go back to an admin for another.
    $result = [ordered]@{ Ok = $false; Detail = '' }
    if ([string]::IsNullOrWhiteSpace($Url)) { $result.Detail = 'Alamat server kosong.'; return $result }
    $trimmed = $Url.Trim().TrimEnd('/')
    if ($trimmed -notmatch '^https?://') { $result.Detail = 'Alamat harus diawali http:// atau https://'; return $result }
    try {
        $resp = Invoke-RestMethod -Uri ($trimmed + '/api/health') -Method Get `
                    -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $result.Ok = $true
        $result.Detail = if ($resp.version) { "Server terjangkau (versi $($resp.version))." } else { 'Server terjangkau.' }
    } catch {
        $result.Detail = "Tidak bisa menghubungi server: $($_.Exception.Message)"
    }
    return $result
}

function Invoke-LogbookServerPairing {
    param([string]$Url, [string]$Code)
    # Redeems an invite and stores what comes back. Order matters: device.json
    # is written BEFORE config.env gains the URL, so a crash between the two
    # leaves a device that is not "connected" (Get-LogbookPairingState needs
    # both) rather than one that believes it is enrolled and is not.
    $out = [ordered]@{ Ok = $false; DeviceId = ''; Category = ''; Error = '' }
    $trimmed = ([string]$Url).Trim().TrimEnd('/')
    $code = ([string]$Code).Trim()
    if (-not $trimmed) { $out.Error = 'Alamat server wajib diisi.'; return $out }
    if (-not $code) { $out.Error = 'Kode pairing wajib diisi.'; return $out }
    try {
        $body = @{
            invite_code = $code
            hostname    = $env:COMPUTERNAME
            os          = 'windows'
            os_version  = [System.Environment]::OSVersion.VersionString
        } | ConvertTo-Json
        $enrolled = Invoke-RestMethod -Uri ($trimmed + '/api/enroll') -Method Post -Body $body `
                        -ContentType 'application/json' -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        if (-not $enrolled.device_id -or -not $enrolled.api_key) {
            $out.Error = 'Server menerima kode tetapi tidak mengirim identitas perangkat.'
            return $out
        }
        $identityPath = Get-LogbookDeviceIdentityPath
        New-Item -ItemType Directory -Force -Path (Split-Path $identityPath -Parent) | Out-Null
        @{ device_id = $enrolled.device_id; api_key = $enrolled.api_key; category = $enrolled.category } |
            ConvertTo-Json | Out-File -FilePath $identityPath -Encoding UTF8 -Force
        Set-LogbookConfigValue -Key 'LOGIX_SERVER_URL' -Value $trimmed

        $out.Ok = $true
        $out.DeviceId = [string]$enrolled.device_id
        $out.Category = [string]$enrolled.category
        # The code itself is never logged: it is a credential, and this log is
        # readable by anyone who can read the state directory.
        Write-LogbookInfo "Paired with server $trimmed as device $($out.DeviceId)"
    } catch {
        $msg = $_.Exception.Message
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $raw = $reader.ReadToEnd()
                if ($raw) {
                    $parsed = $raw | ConvertFrom-Json
                    if ($parsed.detail) { $msg = [string]$parsed.detail }
                }
            }
        } catch { }
        $out.Error = $msg
        Write-LogbookError "Pairing failed against $trimmed : $msg"
    }
    return $out
}

function Remove-LogbookServerPairing {
    # Leaves the server WITHOUT touching a single session: the local database
    # is this device's own record and is not the server's to take back. What
    # goes is the identity and the address, which is exactly what "this device
    # is no longer joined to that server" means.
    #
    # Note this is local only. It cannot revoke the key server-side -- that is
    # an admin action (POST /api/devices/{id}/revoke) and a device being able
    # to revoke itself remotely would be a device being able to delete its own
    # audit trail.
    $out = [ordered]@{ Ok = $false; Error = '' }
    try {
        $path = Get-LogbookDeviceIdentityPath
        if (Test-Path $path) { Remove-Item $path -Force -ErrorAction Stop }
        Set-LogbookConfigValue -Key 'LOGIX_SERVER_URL' -Value ''
        $out.Ok = $true
        Write-LogbookInfo "Server pairing removed on this device (local sessions untouched)."
    } catch {
        $out.Error = $_.Exception.Message
        Write-LogbookError "Unpair failed: $($_.Exception.Message)"
    }
    return $out
}

# ---- Multi-monitor placement -------------------------------------------------
#
# The sign-in surface COVERS every screen on purpose: it is a kiosk lock, paired
# with the keyboard lockdown and the Task Manager gate, and a second monitor
# left uncovered is simply a way around all three. That part is correct and
# must not be traded away.
#
# What was wrong is that the 320px card inside it was centred on the WHOLE
# virtual desktop. On an extended pair that centre is the seam between the two
# monitors, so the dialog a user is supposed to type into was split down the
# middle across a bezel. Coverage is a property of the WINDOW; which display
# the dialog belongs to is a property of the CARD. Separating those two is the
# whole fix.
function Import-LogbookFormsAssembly {
    # Loaded on demand, never at file scope. This file is dot-sourced by the
    # monitor and the bar bridge too, and they have no use for WinForms; the
    # sign-in path already pays enough startup cost for a person who is
    # standing there waiting. Idempotent -- Add-Type on an already-loaded
    # assembly is a no-op, but the type check skips even that.
    if (-not ([System.Management.Automation.PSTypeName]'System.Windows.Forms.Screen').Type) {
        Add-Type -AssemblyName System.Windows.Forms
    }
    if (-not ([System.Management.Automation.PSTypeName]'System.Drawing.Rectangle').Type) {
        Add-Type -AssemblyName System.Drawing
    }
}

function Get-LogbookScreens {
    # Every display, left-to-right, with the label the picker shows.
    Import-LogbookFormsAssembly
    $screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.Left })
    $out = @()
    for ($i = 0; $i -lt $screens.Count; $i++) {
        $s = $screens[$i]
        $out += [pscustomobject]@{
            Index   = $i
            Screen  = $s
            Primary = $s.Primary
            Bounds  = $s.Bounds
            Label   = "Layar $($i + 1)"
            Detail  = ("{0} x {1}{2}" -f $s.Bounds.Width, $s.Bounds.Height,
                        $(if ($s.Primary) { ' - Utama' } else { '' }))
        }
    }
    return $out
}

function Get-LogbookPreferredScreen {
    Import-LogbookFormsAssembly
    # Where the person actually is. The cursor is the only signal available
    # before anything is on screen -- they were just using that machine, and on
    # a lab workstation the mouse is where their attention is. Primary is the
    # fallback, never the assumption: on a docked setup the primary display is
    # routinely the one that is switched off.
    try {
        $screens = Get-LogbookScreens
        $pos = [System.Windows.Forms.Cursor]::Position
        foreach ($s in $screens) {
            if ($s.Bounds.Contains($pos)) { return $s }
        }
        foreach ($s in $screens) { if ($s.Primary) { return $s } }
        if ($screens.Count -gt 0) { return $screens[0] }
    } catch { }
    return $null
}

function Get-LogbookDipScale($Window) {
    # Window.Left/Width are device-INDEPENDENT units; Screen.Bounds is physical
    # pixels. They are equal only at 100% scaling, which is why placing a card
    # by raw pixel arithmetic lands it somewhere else entirely on a 125%/150%
    # laptop panel. Returns the px -> DIP factors, or 1,1 before the window has
    # an HWND (nothing to scale against yet).
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($Window)
        if ($src -and $src.CompositionTarget) {
            $m = $src.CompositionTarget.TransformFromDevice
            if ($m.M11 -gt 0 -and $m.M22 -gt 0) { return @($m.M11, $m.M22) }
        }
    } catch { }
    return @(1.0, 1.0)
}

function Set-LogbookWindowToVirtualScreen($Window) {
    Import-LogbookFormsAssembly
    # Cover everything. Deliberately in the same call as the DIP conversion:
    # sized in raw pixels on a scaled display the window OVER-covers, which is
    # harmless for a lock screen but makes every coordinate inside it lie.
    $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $scale = Get-LogbookDipScale $Window
    $Window.WindowState = 'Normal'
    $Window.Left   = $v.Left * $scale[0]
    $Window.Top    = $v.Top * $scale[1]
    $Window.Width  = $v.Width * $scale[0]
    $Window.Height = $v.Height * $scale[1]
}

function Set-LogbookCardOnScreen($Window, $Card, $Target) {
    # Pin the card inside ONE display's bounds. Alignment moves from Center to
    # Left/Top because "centre of the window" is precisely the wrong anchor
    # when the window spans several displays; the margin then does the real
    # positioning, in the window's own coordinate space.
    if (-not $Window -or -not $Card -or -not $Target) { return }
    Import-LogbookFormsAssembly
    try {
        $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $scale = Get-LogbookDipScale $Window
        $b = $Target.Bounds

        $cardW = $Card.Width
        if ([double]::IsNaN($cardW) -or $cardW -le 0) { $cardW = $Card.ActualWidth }
        $cardH = $Card.ActualHeight
        if ($cardH -le 0) { $cardH = $Card.DesiredSize.Height }

        # Centre of the target display, expressed relative to the window origin.
        $left = (($b.Left - $v.Left) + ($b.Width / 2.0)) * $scale[0] - ($cardW / 2.0)
        $top  = (($b.Top - $v.Top) + ($b.Height / 2.0)) * $scale[1] - ($cardH / 2.0)

        # A card taller than the display would otherwise hang off the top edge,
        # where the title bar and the close affordance live.
        $minLeft = ($b.Left - $v.Left) * $scale[0]
        $minTop  = ($b.Top - $v.Top) * $scale[1]
        if ($left -lt $minLeft) { $left = $minLeft }
        if ($top -lt $minTop) { $top = $minTop }

        $Card.HorizontalAlignment = 'Left'
        $Card.VerticalAlignment   = 'Top'
        $Card.Margin = New-Object System.Windows.Thickness ([Math]::Round($left)), ([Math]::Round($top)), 0, 0
    } catch {
        Write-LogbookError "Card placement failed: $($_.Exception.Message)"
    }
}

function Add-LogbookMonitorPicker($Window, $Card, $Panel, $cfg, $Screens, $Current) {
    # Builds the display chips. Returns nothing; wiring is done by side effect
    # on $Panel. Stays hidden for a single display -- a "choose a display"
    # control on a one-display machine is a question with one answer, which is
    # not a choice, it is an obstacle.
    if (-not $Panel) { return }
    if (-not $Screens -or $Screens.Count -lt 2) { $Panel.Visibility = 'Collapsed'; return }

    $theme = Get-LogbookTheme $cfg
    $conv = New-Object System.Windows.Media.BrushConverter
    $Panel.Children.Clear()

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = (Get-LogbookText $cfg 'monitorPicker' 'Tampilkan di')
    $lbl.FontSize = 11
    $lbl.Foreground = $conv.ConvertFromString($theme.muted)
    $lbl.VerticalAlignment = 'Center'
    $lbl.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    [void]$Panel.Children.Add($lbl)

    foreach ($s in $Screens) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = [string]($s.Index + 1)
        $btn.ToolTip = "$($s.Label) - $($s.Detail)"
        $btn.Width = 26
        $btn.Height = 22
        $btn.FontSize = 11
        $btn.Margin = New-Object System.Windows.Thickness 0, 0, 4, 0
        $btn.Cursor = 'Hand'
        $btn.BorderThickness = New-Object System.Windows.Thickness 1
        $btn.Tag = $s

        $isCurrent = ($Current -and $s.Index -eq $Current.Index)
        $btn.Background = $conv.ConvertFromString($(if ($isCurrent) { $theme.accent } else { $theme.surfaceWidget }))
        $btn.BorderBrush = $conv.ConvertFromString($(if ($isCurrent) { $theme.accent } else { $theme.border }))
        $btn.Foreground = $conv.ConvertFromString($(if ($isCurrent) { '#FFFFFF' } else { $theme.muted }))

        # A pill, not a default WPF button: the chrome-free chip is the whole
        # reason this reads as a choice rather than as an error dialog.
        $tpl = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
  <Border CornerRadius="11" Background="{TemplateBinding Background}"
          BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
</ControlTemplate>
"@)
        $btn.Template = $tpl

        $btn.Add_Click({
            param($sender, $e)
            $target = $sender.Tag
            Set-LogbookCardOnScreen -Window $Window -Card $Card -Target $target
            # Repaint the chips so the selected one is unambiguous.
            foreach ($child in $Panel.Children) {
                if ($child -is [System.Windows.Controls.Button]) {
                    $on = ($child.Tag.Index -eq $target.Index)
                    $child.Background  = $conv.ConvertFromString($(if ($on) { $theme.accent } else { $theme.surfaceWidget }))
                    $child.BorderBrush = $conv.ConvertFromString($(if ($on) { $theme.accent } else { $theme.border }))
                    $child.Foreground  = $conv.ConvertFromString($(if ($on) { '#FFFFFF' } else { $theme.muted }))
                }
            }
            Save-LogbookPreferredMonitor $target
        }.GetNewClosure())

        [void]$Panel.Children.Add($btn)
    }
    $Panel.Visibility = 'Visible'
}

# The chosen display is remembered per machine. A lab workstation's monitor
# layout does not change between sessions, so asking again every single sign-in
# would be asking a question whose answer we already have.
function Save-LogbookPreferredMonitor($Target) {
    try {
        if (-not $Target) { return }
        Ensure-LogbookDirs
        $path = Join-Path $Global:StateDir 'monitor_pref.json'
        $obj = @{ deviceName = $Target.Screen.DeviceName
                  bounds = ("{0},{1},{2},{3}" -f $Target.Bounds.Left, $Target.Bounds.Top, $Target.Bounds.Width, $Target.Bounds.Height) }
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Compress),
            (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch { }
}

function Get-LogbookSavedMonitor($Screens) {
    # Matched on DeviceName AND geometry: a remembered "\\.\DISPLAY2" means
    # nothing if that display was unplugged and a different one took the name.
    try {
        $path = Join-Path $Global:StateDir 'monitor_pref.json'
        if (-not (Test-Path $path)) { return $null }
        $saved = Get-Content $path -Raw | ConvertFrom-Json
        foreach ($s in $Screens) {
            $geo = "{0},{1},{2},{3}" -f $s.Bounds.Left, $s.Bounds.Top, $s.Bounds.Width, $s.Bounds.Height
            if ($s.Screen.DeviceName -eq [string]$saved.deviceName -and $geo -eq [string]$saved.bounds) {
                return $s
            }
        }
    } catch { }
    return $null
}

function Set-LogbookPopupMonitorPlacement($Window, $Card, $Panel, $cfg) {
    # One call the popup controllers use. Order matters: saved choice wins over
    # the cursor, because it is an explicit instruction and the cursor is only
    # ever an inference.
    $screens = Get-LogbookScreens
    $target = Get-LogbookSavedMonitor $screens
    if (-not $target) { $target = Get-LogbookPreferredScreen }
    if (-not $target -and $screens.Count -gt 0) { $target = $screens[0] }
    if ($target) { Set-LogbookCardOnScreen -Window $Window -Card $Card -Target $target }
    if ($Panel) { Add-LogbookMonitorPicker -Window $Window -Card $Card -Panel $Panel -cfg $cfg -Screens $screens -Current $target }
    return $target
}

function Get-LogbookTheme($cfg) {
    # Resolve the full client palette from config, with the Client Foundation
    # defaults as fallbacks. Backward-compatible: a config that only sets the
    # legacy four colours (primary/accent/muted/text) still renders -- the
    # surface ramp and signal colours derive from sensible defaults. Every
    # value is a #RRGGBB string ready to drop straight into XAML.
    $c = $cfg.branding.colors
    $s = $cfg.branding.signals
    $val = {
        param($map, $key, $fallback)
        if ($map -and $map.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$map[$key])) {
            return [string]$map[$key]
        }
        return $fallback
    }
    $accent          = & $val $c 'accent'          '#2563EB'
    $text            = & $val $c 'text'            '#EEF3FB'
    $muted           = & $val $c 'muted'           '#93A1B8'
    $surfaceElevated = & $val $c 'surfaceElevated' (& $val $c 'primary' '#0E1626')
    $surfaceWidget   = & $val $c 'surfaceWidget'   '#0B1017'
    $critical        = & $val $s 'critical'        '#EF4444'
    return @{
        accent          = $accent
        text            = $text
        muted           = $muted
        surface         = & $val $c 'surface'       '#070C15'
        surfaceWidget   = $surfaceWidget
        surfaceElevated = $surfaceElevated
        border          = & $val $c 'border'        '#223451'
        signalNormal    = & $val $s 'normal'        '#22C55E'
        signalNotice    = & $val $s 'notice'        '#3B82F6'
        signalWarning   = & $val $s 'warning'       '#F59E0B'
        signalCritical  = $critical
        # The quiet half of the critical signal, derived (see
        # Get-LogbookMixedHex) rather than picked. Full-strength #EF4444 is a
        # correct ALERT colour and a wrong SURFACE colour: on a card whose
        # whole palette is deep navy, muted slate and a green dot, a button
        # that floods solid red on press does not read as "this is serious",
        # it reads as a different application's button. The guard rail this
        # file already states -- status colour appears only as a dot or an
        # edge, never as a tinted background -- is exactly the rule that flood
        # broke. These three keep the meaning and drop the shouting:
        #   Wash: the signal laid over the widget surface at low strength, so
        #         a growing fill stays a member of this palette.
        #   Edge: the same mix at border strength, for the 1px outline that is
        #         the design's sanctioned place for a status colour.
        #   Soft: the signal lifted toward white, for TEXT that has to stay
        #         legible on the wash -- #EF4444 on a near-black wash is under
        #         the contrast the body text on this card holds itself to.
        criticalWash    = Get-LogbookMixedHex $surfaceWidget $critical 0.16
        criticalEdge    = Get-LogbookMixedHex $surfaceWidget $critical 0.45
        criticalSoft    = Get-LogbookMixedHex $critical      '#FFFFFF' 0.35
    }
}

function Build-LogbookClientResources($cfg) {
    # The v3 "Clean Calibration" client token set, emitted as a WPF
    # ResourceDictionary fragment. This is the client-side twin of the web
    # dashboard's tokens.css: one place defines the palette, every window
    # references it via {StaticResource ...} instead of inlining hex.
    #
    # Values come from docs/design_handoff_logix_v3/README.md ("Client widget
    # (WPF, always dark)") and remain config-overridable through
    # Get-LogbookTheme, so a faculty rebrand still works.
    #
    # Guard rails encoded here: no gradient brushes, and status colour exists
    # only as a dot fill or a 3px edge -- there is deliberately no tinted
    # status background brush to reach for. LxNotice is the accent blue,
    # matching the message states in the Timer prototype (D-02 state 04/07).
    $t = Get-LogbookTheme $cfg
    return @"
    <SolidColorBrush x:Key="LxSurface"  Color="$($t.surfaceWidget)"/>
    <SolidColorBrush x:Key="LxElevated" Color="$($t.surfaceElevated)"/>
    <SolidColorBrush x:Key="LxHairline" Color="$($t.border)"/>
    <SolidColorBrush x:Key="LxText"     Color="$($t.text)"/>
    <SolidColorBrush x:Key="LxMuted"    Color="$($t.muted)"/>
    <SolidColorBrush x:Key="LxAccent"   Color="$($t.accent)"/>
    <SolidColorBrush x:Key="LxActive"   Color="$($t.signalNormal)"/>
    <SolidColorBrush x:Key="LxNotice"   Color="$($t.accent)"/>
    <SolidColorBrush x:Key="LxWarning"  Color="$($t.signalWarning)"/>
    <SolidColorBrush x:Key="LxCritical" Color="$($t.signalCritical)"/>
    <SolidColorBrush x:Key="LxCriticalWash" Color="$($t.criticalWash)"/>
    <SolidColorBrush x:Key="LxCriticalEdge" Color="$($t.criticalEdge)"/>
    <SolidColorBrush x:Key="LxCriticalSoft" Color="$($t.criticalSoft)"/>

    <!-- Two type voices only: Segoe UI for words, Consolas for time/ID/duration. -->
    <Style x:Key="LxLabel" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource LxMuted}"/>
    </Style>
    <Style x:Key="LxValue" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource LxText}"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="LxMono" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="Foreground" Value="{StaticResource LxText}"/>
    </Style>

    <!-- Dark dropdown. WPF's stock ComboBox chrome is light-themed and
         unreadable on this surface, so the whole control is re-templated:
         a hairline Border, a chevron, and a dark popup list. PART_EditableTextBox
         is present because the Tujuan dropdown is editable (the "Lainnya"
         free-text escape hatch types straight into it). -->
    <Style x:Key="LxComboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource LxText}"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ItemBg" Background="Transparent" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBg" Property="Background" Value="{StaticResource LxElevated}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="LxCombo" TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource LxText}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{StaticResource LxHairline}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource LxComboItem}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleBtn" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="ComboBg" CornerRadius="12" Background="{StaticResource LxSurface}"
                            BorderBrush="{StaticResource LxHairline}" BorderThickness="1">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0"
                            Data="M 2,3.5 L 5,6.5 L 8,3.5" Stroke="{StaticResource LxMuted}" StrokeThickness="1.5"
                            StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
              <TextBox x:Name="PART_EditableTextBox" Visibility="Collapsed" Background="Transparent"
                       BorderThickness="0" Foreground="{StaticResource LxText}"
                       CaretBrush="{StaticResource LxAccent}" Margin="{TemplateBinding Padding}"
                       VerticalAlignment="Center"/>
              <Popup x:Name="PART_Popup" AllowsTransparency="True" Placement="Bottom"
                     IsOpen="{TemplateBinding IsDropDownOpen}" Focusable="False" PopupAnimation="None">
                <Border Background="{StaticResource LxSurface}" BorderBrush="{StaticResource LxHairline}"
                        BorderThickness="1" CornerRadius="12" Padding="6"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="240">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                <Setter TargetName="ContentSite" Property="Visibility" Value="Collapsed"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.75"/>
                <Setter TargetName="ToggleBtn" Property="Visibility" Value="Collapsed"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Pill button: fully rounded, no gradient, no glow. Outline by default;
         the caller sets Background/Foreground for the primary + armed forms. -->
    <Style x:Key="LxPill" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="{StaticResource LxText}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{StaticResource LxHairline}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <!-- 20, not 999: WPF generates degenerate elliptical arcs from a
                 corner radius far larger than the box, which renders a
                 stretched button as a full ellipse rather than a stadium.
                 20 exceeds half the tallest pill here, so it still clamps to
                 a true half-height round-end. -->
            <Border x:Name="PillBg" CornerRadius="20"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <TextBlock Text="{TemplateBinding Content}" HorizontalAlignment="Center"
                         VerticalAlignment="Center" TextWrapping="NoWrap"
                         Foreground="{TemplateBinding Foreground}"
                         FontFamily="{TemplateBinding FontFamily}"
                         FontSize="{TemplateBinding FontSize}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="PillBg" Property="Opacity" Value="0.75"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="PillBg" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
"@
}

# NIM/NIP/NIK is numbers-only (student/staff ID, national ID) -- reject
# non-digit keystrokes at the source and strip non-digits from paste, rather
# than validating after the fact. Shared by the real popup (logbook_popup.ps1)
# and the interactive preview (preview_client.ps1) so both behave the same.
function Set-LogbookNumericOnly($TextBox) {
    $TextBox.Add_PreviewTextInput({
        param($sender, $e)
        if ($e.Text -notmatch '^[0-9]+$') { $e.Handled = $true }
    })
    $TextBox.Add_PreviewKeyDown({
        param($sender, $e)
        # Space bar doesn't fire PreviewTextInput as printable text on some
        # layouts -- block it explicitly so it can't sneak a blank in.
        if ($e.Key -eq 'Space') { $e.Handled = $true }
    })
    [System.Windows.DataObject]::AddPastingHandler($TextBox, {
        param($sender, $e)
        if ($e.DataObject.GetDataPresent([System.Windows.DataFormats]::Text)) {
            $text = [string]$e.DataObject.GetData([System.Windows.DataFormats]::Text)
            $digits = ($text -replace '[^0-9]', '')
            if ($digits -ne $text) {
                if ($digits) { $sender.SelectedText = $digits }
                $e.CancelCommand()
            }
        } else {
            $e.CancelCommand()
        }
    })
}

function Build-LogbookPopupXaml($cfg) {
    # Render the popup XAML from config. Pure string building (no WPF), so it is
    # unit-testable by parsing the result as [xml].
    $theme   = Get-LogbookTheme $cfg
    $accent  = $theme.accent
    $muted   = $theme.muted            # muted TEXT
    $text    = $theme.text
    $primary = $theme.surfaceElevated  # card / input surface
    $surface = $theme.surface          # deepest fullscreen surface
    $border  = $theme.border           # hairline BORDER
    $overlay = '#D8' + $surface.TrimStart('#')  # deep translucent scrim over blur

    $logoText = ConvertTo-LogbookXmlText ([string]$cfg.branding.logoText)
    $title    = ConvertTo-LogbookXmlText ([string]$cfg.branding.title)
    $subtitle = ConvertTo-LogbookXmlText ([string]$cfg.branding.subtitle)
    $tIntro   = ConvertTo-LogbookXmlText ([string]$cfg.text.intro)
    $tStart   = ConvertTo-LogbookXmlText ([string]$cfg.text.startHint)
    $tNama    = ConvertTo-LogbookXmlText ([string]$cfg.text.namaLabel)
    $tNim     = ConvertTo-LogbookXmlText ([string]$cfg.text.nimLabel)
    $tAccess  = ConvertTo-LogbookXmlText ([string]$cfg.text.accessLabel)
    $tPurpose = ConvertTo-LogbookXmlText ([string]$cfg.text.purposeLabel)
    $tKet     = ConvertTo-LogbookXmlText ([string]$cfg.text.ketLabel)
    $tSubmit  = ConvertTo-LogbookXmlText ([string]$cfg.text.submit)
    $tHint    = ConvertTo-LogbookXmlText ([string]$cfg.text.hint)
    $tHeading = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'signinTitle' 'Mulai sesi')

    $accessItems  = (@($cfg.accessTypes) | ForEach-Object { "                <ComboBoxItem Content=`"$(ConvertTo-LogbookXmlText $_)`" />" }) -join "`r`n"
    $purposeItems = (@($cfg.purposes)    | ForEach-Object { "                <ComboBoxItem Content=`"$(ConvertTo-LogbookXmlText $_)`" />" }) -join "`r`n"

    # ShowInTaskbar="True", not False: confirmed live that a Topmost,
    # ShowInTaskbar=False, WindowStyle=None window spawned by the Task
    # Scheduler-launched monitor process never actually renders (verified
    # with a real Win32 EnumWindows scan, not just Get-Process -- the same
    # window shown directly, outside of Task Scheduler, renders fine). The
    # exact Windows mechanism wasn't pinned down further (candidates: the
    # ShowInTaskbar=False/"tool window" style itself, or Topmost needing
    # foreground rights a Task-Scheduler-launched process may lack) --
    # ShowInTaskbar=True is the safer, lower-risk direction to try first.
    # Same change applied to every other fullscreen/topmost window this
    # client shows (welcome-back, lock, emergency overlay, timer widget).
    $res = Build-LogbookClientResources $cfg
    # v3 sign-in popup (design: docs/design_handoff_logix_v3/
    # "LogiX Sign-in Popup.dc.html", README section 6).
    #
    # A 320px dark dialog (radius 22) centred over a dimmed full-screen scrim,
    # matching the pill's visual language. Shown for PHYSICAL access only --
    # SSH/AnyDesk sessions are logged from remote-login credentials and never
    # raise this window.
    #
    # Deviation from the prototype, deliberate: the design draws three fields
    # (NIM, Tujuan, read-only access type). This build also renders Nama and
    # Keterangan because `requiredFields` in config can demand them and the
    # session schema (which we must not change) stores them -- dropping the
    # inputs would leave those columns permanently empty in every report. The
    # layout, spacing and type scale are otherwise the design's.
    #
    # Element names are the existing contract logbook_popup.ps1 binds to
    # (NamaBox / NimBox / AccessBox / TujuanBox / KetBox / SubmitBtn /
    # HintText / StartTimeText / MainCard / BgImage / MascotImage); only the
    # presentation changed, so the controller keeps working untouched.
    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="True" AllowsTransparency="True"
        Background="$overlay" FontFamily="Segoe UI">
  <Window.Resources>
$res
    <!-- Dark field: hairline border, radius 12, accent ring on focus. -->
    <Style x:Key="LxField" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource LxText}"/>
      <Setter Property="CaretBrush" Value="{StaticResource LxAccent}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{StaticResource LxHairline}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="FieldBg" CornerRadius="12" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="FieldBg" Property="BorderBrush" Value="{StaticResource LxAccent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LxFieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource LxMuted}"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
  </Window.Resources>

  <Grid>
    <!-- Kept for the controller's optional wallpaper/mascot hooks; the v3
         dialog itself is chrome-free, so both start collapsed. -->
    <Image Name="BgImage" Stretch="UniformToFill" Opacity="0.18" Visibility="Collapsed"/>

    <Border Name="MainCard" Width="320" CornerRadius="22" Padding="28,26"
            Background="{StaticResource LxElevated}" BorderBrush="{StaticResource LxHairline}" BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Center">
      <Border.Effect><DropShadowEffect BlurRadius="64" ShadowDepth="20" Direction="270" Opacity="0.55" Color="#000000"/></Border.Effect>
      <StackPanel>

        <StackPanel Orientation="Horizontal" Margin="0,0,0,20">
          <Border Width="26" Height="26" CornerRadius="8" Background="{StaticResource LxAccent}" Margin="0,0,9,0">
            <TextBlock Text="&gt;_" FontFamily="Consolas" FontSize="12" FontWeight="Bold"
                       Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Name="LogoText" Text="$logoText" FontFamily="Consolas" FontSize="13"
                     Foreground="{StaticResource LxText}" VerticalAlignment="Center"/>
          <Image Name="MascotImage" Width="0" Height="0" Visibility="Collapsed"/>
        </StackPanel>

        <!-- Short heading + the configured intro as supporting copy. The
             design's heading is two words; `text.intro` is a full sentence,
             so it reads as body rather than clipping the title. -->
        <TextBlock Text="$tHeading" FontSize="19" FontWeight="SemiBold" TextWrapping="Wrap"
                   Foreground="{StaticResource LxText}" Margin="0,0,0,4"/>
        <TextBlock Text="$tIntro" FontSize="12" TextWrapping="Wrap" LineHeight="17"
                   Foreground="{StaticResource LxMuted}" Margin="0,0,0,18"/>

        <TextBlock Text="$tNim" Style="{StaticResource LxFieldLabel}"/>
        <TextBox Name="NimBox" Style="{StaticResource LxField}" FontFamily="Consolas" Margin="0,0,0,14"/>

        <TextBlock Text="$tNama" Style="{StaticResource LxFieldLabel}"/>
        <TextBox Name="NamaBox" Style="{StaticResource LxField}" Margin="0,0,0,14"/>

        <TextBlock Text="$tPurpose" Style="{StaticResource LxFieldLabel}"/>
        <ComboBox Name="TujuanBox" Style="{StaticResource LxCombo}" IsEditable="True" Margin="0,0,0,14">
$purposeItems
          <ComboBoxItem Content="Lainnya - tulis sendiri..." />
        </ComboBox>

        <TextBlock Text="$tKet" Style="{StaticResource LxFieldLabel}"/>
        <TextBox Name="KetBox" Style="{StaticResource LxField}" Margin="0,0,0,14"/>

        <!-- Access type is auto-detected, never a user choice: the control is
             present so the controller can select the detected value, but it is
             disabled and reads as a status line with a dot. -->
        <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
          <Ellipse Width="8" Height="8" Fill="{StaticResource LxActive}" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock Text="$tAccess" FontSize="12" Foreground="{StaticResource LxMuted}" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <ComboBox Name="AccessBox" Style="{StaticResource LxCombo}" IsEnabled="False" FontSize="12" BorderThickness="0" Padding="0" VerticalAlignment="Center">
$accessItems
          </ComboBox>
        </StackPanel>

        <Button Name="SubmitBtn" Content="$tSubmit" Style="{StaticResource LxPill}"
                Padding="0,11" HorizontalContentAlignment="Center" FontSize="13"
                Background="{StaticResource LxAccent}" BorderBrush="{StaticResource LxAccent}"
                Foreground="#FFFFFF" Margin="0,0,0,14"/>

        <!-- Inline validation: one sentence telling the user how to fix it.
             No shake, no separate dialog. -->
        <TextBlock Name="HintText" Text="$tHint" FontSize="11.5" TextWrapping="Wrap"
                   TextAlignment="Center" Foreground="{StaticResource LxMuted}" Margin="0,0,0,10"/>

        <TextBlock Name="StartTimeText" Text="$tStart" FontSize="11" TextWrapping="Wrap"
                   TextAlignment="Center" LineHeight="16" Foreground="{StaticResource LxMuted}"/>

        <!-- Multi-monitor: one chip per display, filled in by the controller
             (Add-LogbookMonitorPicker) because the number of displays is not
             known until runtime. Collapsed by default and left that way on a
             single-screen machine, so the ordinary case gains no extra step,
             no extra question, and not one pixel of height. It is only ever
             a CORRECTION affordance: the dialog has already placed itself on
             the display the user is working at. -->
        <StackPanel Name="MonitorPicker" Visibility="Collapsed" Orientation="Horizontal"
                    HorizontalAlignment="Center" Margin="0,16,0,0"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
}

function Build-LogbookWelcomeBackXaml($cfg, $profile, [string]$detectedType) {
    # Returning-user fast path (Action canvas: LogiX Sign-in Popup SA). A
    # returning user confirms one saved identity and starts -- no full form.
    # Same deep-navy fullscreen surface as the main popup. Named controls the
    # controller wires: StartBtn (resume) and ChangeBtn (fall through to form).
    $theme  = Get-LogbookTheme $cfg
    $accent = $theme.accent; $text = $theme.text; $muted = $theme.muted
    $surface = $theme.surface; $elevated = $theme.surfaceElevated; $border = $theme.border
    $overlay = '#D8' + $surface.TrimStart('#')

    $logoText = ConvertTo-LogbookXmlText ([string]$cfg.branding.logoText)
    $title    = ConvertTo-LogbookXmlText ([string]$cfg.branding.title)
    $subtitle = ConvertTo-LogbookXmlText ([string]$cfg.branding.subtitle)
    $nama     = [string]$profile.nama
    $nim      = [string]$profile.nim
    $tujuan   = [string]$profile.tujuan
    $access   = if ([string]::IsNullOrWhiteSpace([string]$detectedType)) { 'Physical' } else { [string]$detectedType }

    # Avatar initials from the name (up to two).
    $initials = (($nama -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() }) -join '')
    if ($initials.Length -gt 2) { $initials = $initials.Substring(0,2) }
    if ([string]::IsNullOrWhiteSpace($initials)) { $initials = '?' }
    $nimMasked = if ($nim.Length -gt 4) { $nim.Substring(0,4) + '...' } else { $nim }
    $meta = ConvertTo-LogbookXmlText ("NIM $nimMasked - $access - $tujuan")

    $tWelcome = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'welcomeBack' 'Lanjutkan sesi Anda')
    $tContinue = ConvertTo-LogbookXmlText (([string](Get-LogbookText $cfg 'continueAs' 'Lanjut sebagai {0}')) -f $nama)
    $tNotYou  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'notYou' 'Bukan saya / ganti data')
    $tSubmit  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'submit' 'Mulai Sesi')
    $tPrivacy = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'privacyOneLiner' 'Siapa, cara & kapan - bukan ketikan.')
    $tRecorded = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'whatsRecorded' 'Apa yang dicatat?')
    $started  = ConvertTo-LogbookXmlText ('Sesi dimulai ' + (Get-Date).ToString('HH:mm'))
    $nameX    = ConvertTo-LogbookXmlText $nama

    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="True" Background="$surface"
        AllowsTransparency="True" FontFamily="Segoe UI">
  <Grid>
    <Image Name="BgImage" Stretch="Fill" Opacity="0.88"><Image.Effect><BlurEffect Radius="24" KernelType="Gaussian" /></Image.Effect></Image>
    <Rectangle Fill="$overlay" />
    <Border Name="MainCard" Width="430" CornerRadius="16" BorderBrush="$border" BorderThickness="1" Background="$elevated"
            HorizontalAlignment="Center" VerticalAlignment="Center" Padding="34,30,34,28">
      <Border.Effect><DropShadowEffect BlurRadius="40" ShadowDepth="0" Opacity="0.5" Color="#070C15" /></Border.Effect>
      <StackPanel>
        <Image Name="MascotImage" Height="96" MaxWidth="200" Stretch="Uniform" HorizontalAlignment="Center"
               RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed" Margin="0,0,0,10" />
        <TextBlock Text="$logoText" FontFamily="Segoe UI Semibold" FontSize="28" FontWeight="SemiBold" Foreground="$text" HorizontalAlignment="Center" />
        <TextBlock Text="$title" FontSize="15" FontWeight="SemiBold" Foreground="$text" HorizontalAlignment="Center" Margin="0,6,0,0" />
        <TextBlock Text="$subtitle" FontSize="12" Foreground="$muted" HorizontalAlignment="Center" Margin="0,1,0,0" />
        <Border Height="1" Background="$border" Margin="0,20,0,18" />
        <TextBlock Text="$tWelcome" FontSize="12" FontWeight="SemiBold" Foreground="$muted" Margin="0,0,0,12" />
        <Border Background="$surface" CornerRadius="12" BorderBrush="$border" BorderThickness="1" Padding="14,12" Margin="0,0,0,18">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Width="44" Height="44" CornerRadius="22" Background="$accent" VerticalAlignment="Center">
              <TextBlock Text="$initials" FontFamily="Segoe UI Semibold" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="$tContinue" FontFamily="Segoe UI Semibold" FontSize="17" FontWeight="Bold" Foreground="$text" TextTrimming="CharacterEllipsis" />
              <TextBlock Text="$meta" FontFamily="Consolas" FontSize="12" Foreground="$muted" Margin="0,3,0,0" TextTrimming="CharacterEllipsis" />
            </StackPanel>
          </Grid>
        </Border>
        <Button Name="StartBtn" Height="50" Content="$tSubmit" FontFamily="Segoe UI Semibold" FontSize="19" FontWeight="Bold"
                Background="$accent" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" />
        <Button Name="ChangeBtn" Content="$tNotYou" Background="Transparent" BorderThickness="0" Foreground="$muted"
                FontSize="13" FontWeight="SemiBold" Cursor="Hand" Margin="0,12,0,0" HorizontalAlignment="Center" />
        <TextBlock Text="$started" FontFamily="Consolas" FontSize="11" Foreground="$muted" HorizontalAlignment="Center" Margin="0,14,0,0" />
        <Border Height="1" Background="$border" Margin="0,16,0,14" />
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
          <TextBlock Text="$tPrivacy" FontSize="11.5" Foreground="$muted" VerticalAlignment="Center" />
          <TextBlock Text="  $tRecorded" FontSize="11.5" FontWeight="SemiBold" Foreground="$accent" VerticalAlignment="Center" />
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
}

function Build-LogbookCountdownOverlayXaml($cfg) {
    # The shared "escape both postures" overlay (design: D-02 state 08). One
    # component serves BOTH the idle auto-end warning and an admin Emergency
    # Broadcast -- the controller shows/hides the countdown numeral and swaps
    # the action row rather than there being two overlays to keep in step.
    #
    # Dimmed backdrop + a single centered 360px card, radius 22. Both action
    # labels are TextWrapping="NoWrap" so "Perpanjang sesi" / "Selesai
    # sekarang" can never break across two lines.
    $res = Build-LogbookClientResources $cfg
    $tExtend = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'overlayExtend' 'Perpanjang sesi')
    $tEndNow = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'overlayEndNow' 'Selesai sekarang')
    $tAck    = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'overlayAck' 'Saya paham')
    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="False" AllowsTransparency="True"
        Background="#B805080D" FontFamily="Segoe UI">
  <Window.Resources>
$res
  </Window.Resources>
  <Grid>
    <Border Name="OverlayCard" Width="360" CornerRadius="22" Padding="26,24" RenderTransformOrigin="0.5,0.5"
            Background="{StaticResource LxElevated}" BorderBrush="{StaticResource LxHairline}" BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Center">
      <Border.RenderTransform><ScaleTransform x:Name="OverlayScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
      <Border.Effect><DropShadowEffect BlurRadius="64" ShadowDepth="20" Direction="270" Opacity="0.6" Color="#000000"/></Border.Effect>
      <StackPanel HorizontalAlignment="Center">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,6">
          <Ellipse Name="OverlayDot" Width="8" Height="8" Fill="{StaticResource LxCritical}" VerticalAlignment="Center" Margin="0,0,7,0"/>
          <TextBlock Name="OverlayTitle" Text="Sesi berakhir dalam" FontFamily="Segoe UI Semibold" FontSize="13"
                     Foreground="{StaticResource LxText}" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock Name="CountNumber" Text="05:00" FontFamily="Consolas" FontSize="44" LineHeight="51"
                   Foreground="{StaticResource LxCritical}" HorizontalAlignment="Center"/>
        <TextBlock Name="OverlayBody" Text="" FontSize="12" Foreground="{StaticResource LxMuted}"
                   TextWrapping="Wrap" TextAlignment="Center" MaxWidth="308" Margin="0,6,0,16"/>
        <StackPanel Name="OverlayActions" Orientation="Horizontal" HorizontalAlignment="Center">
          <Button Name="ExtendBtn" Content="$tExtend" Style="{StaticResource LxPill}" Padding="16,9" FontSize="12.5"
                  Background="{StaticResource LxAccent}" BorderBrush="{StaticResource LxAccent}"
                  Foreground="#FFFFFF" Margin="0,0,8,0"/>
          <Button Name="EndNowBtn" Content="$tEndNow" Style="{StaticResource LxPill}" Padding="16,9" FontSize="12.5"/>
          <Button Name="AckBtn" Content="$tAck" Style="{StaticResource LxPill}" Padding="16,9" FontSize="12.5"
                  Background="{StaticResource LxAccent}" BorderBrush="{StaticResource LxAccent}"
                  Foreground="#FFFFFF" Visibility="Collapsed"/>
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
}

function Build-LogbookLockXaml($cfg, [string]$Nama, [string]$Reason) {
    # Lock / paused overlay (design: LogiX Lock & Setup SA). Reads "in use,
    # paused" -- never punitive. The session keeps running; only the screen is
    # held. Controller drives LockClock + LockElapsed; UnlockBtn resumes.
    $theme  = Get-LogbookTheme $cfg
    $accent = $theme.accent; $text = $theme.text; $muted = $theme.muted
    $surface = $theme.surface; $elevated = $theme.surfaceElevated; $border = $theme.border
    $warn   = $theme.signalWarning
    $res    = Build-LogbookClientResources $cfg
    $logoText = ConvertTo-LogbookXmlText ([string]$cfg.branding.logoText)
    $namaX  = ConvertTo-LogbookXmlText $Nama
    $reasonX = ConvertTo-LogbookXmlText $Reason
    $tTitle = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockTitle' 'Workstation dikunci oleh admin lab')
    $tPaused = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockPausedNote' 'Sesi Anda dijeda, bukan diakhiri. Semua pekerjaan & waktu sesi tetap tersimpan.')
    $tBadge = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockPausedBadge' 'DIJEDA')
    $tElapsed = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockElapsedLabel' 'Waktu sesi berjalan')
    $tUser  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockUserLabel' 'Pengguna')
    $tReason = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockReasonLabel' 'Alasan dari admin')
    $tHint  = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockUnlockHint' 'Masuk kembali untuk melanjutkan sesi')
    $tUnlock = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'lockUnlockBtn' 'Buka & Lanjutkan')
    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        Topmost="True" ShowInTaskbar="True" Background="$surface" FontFamily="Segoe UI">
  <Window.Resources>
$res
  </Window.Resources>
  <Grid>
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="520">
      <Image Name="MascotImage" Height="96" Stretch="Uniform" HorizontalAlignment="Center" Visibility="Collapsed" Margin="0,0,0,10"/>
      <TextBlock Text="$logoText" FontFamily="Segoe UI Semibold" FontSize="30" FontWeight="SemiBold" Foreground="$text" HorizontalAlignment="Center"/>
      <TextBlock Name="LockClock" Text="--:--" FontFamily="Consolas" FontSize="15" Foreground="$muted" HorizontalAlignment="Center" Margin="0,6,0,22"/>
      <TextBlock Text="$tTitle" FontFamily="Segoe UI Semibold" FontSize="20" FontWeight="Bold" Foreground="$text" HorizontalAlignment="Center" TextAlignment="Center"/>
      <TextBlock Text="$tPaused" FontSize="14" Foreground="$muted" TextWrapping="Wrap" TextAlignment="Center" Margin="0,8,0,20"/>
      <Border Background="$elevated" CornerRadius="22" BorderBrush="$border" BorderThickness="1" Padding="20,16" Margin="0,0,0,20">
        <StackPanel>
          <!-- v3: status is a dot plus a label, never a tinted pill. The
               amber fill this badge used to carry was the one guard-rail
               violation left on this screen. -->
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,10">
            <Ellipse Width="8" Height="8" Fill="$warn" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock Text="$tBadge" FontFamily="Segoe UI Semibold" FontSize="11" Foreground="$text" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock Text="$tElapsed" FontSize="12" Foreground="$muted" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Name="LockElapsed" Text="00:00:00" FontFamily="Consolas" FontSize="40" FontWeight="Bold" Foreground="$text" HorizontalAlignment="Center" Margin="0,0,0,12"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="$tUser" FontSize="12" Foreground="$muted" Width="120"/>
            <TextBlock Grid.Column="1" Text="$namaX" FontFamily="Segoe UI Semibold" FontSize="13" Foreground="$text"/>
          </Grid>
          <Grid Margin="0,6,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="$tReason" FontSize="12" Foreground="$muted" Width="120"/>
            <TextBlock Grid.Column="1" Text="$reasonX" FontSize="13" Foreground="$text" TextWrapping="Wrap"/>
          </Grid>
        </StackPanel>
      </Border>
      <TextBlock Text="$tHint" FontSize="12" Foreground="$muted" HorizontalAlignment="Center" Margin="0,0,0,10"/>
      <Button Name="UnlockBtn" Content="$tUnlock" Style="{StaticResource LxPill}" MinWidth="220"
              HorizontalAlignment="Center" Padding="24,12" FontSize="14"
              Background="{StaticResource LxAccent}" BorderBrush="{StaticResource LxAccent}" Foreground="#FFFFFF"/>
    </StackPanel>
  </Grid>
</Window>
"@
}

# Timer widget -- v3 "Pill & Strip" (design: docs/design_handoff_logix_v3/
# "LogiX Timer Pill & Strip.dc.html", README section 5).
#
# One instrument, two postures, both anchored to the TOP EDGE of the screen:
#   Pill   150x32 capsule at rest; hover expands it to a 240px card.
#   Strip  a 3px full-width line (a separate click-through window, see
#          Build-LogbookStripXaml); dwelling at the top edge drops a 24px
#          sliver from THIS window.
# Double-click toggles the posture and the choice is remembered across
# sessions. All three visuals live in one window and are swapped by
# Visibility, so there is a single always-on-top surface to manage.
#
# Sizing is SizeToContent -- unlike the previous chamfered-Path widget, every
# surface here is a plain Border with CornerRadius, so there is no Path
# geometry or Grid.Clip to keep in sync and WPF's own measure pass is
# trustworthy. RootVisual carries a 16px margin purely as bleed room for the
# drop shadows.
#
# Guard rails: no gradient, no glow, no pulse. The status dot is a static 8px
# Ellipse. Colours come exclusively from Build-LogbookClientResources.
# ---- Click-through -----------------------------------------------------------
#
# A WPF window with AllowsTransparency + Background="Transparent" still HIT-TESTS
# across its entire rectangle. For the timer widget that rectangle is the pill
# PLUS the invisible margin its drop shadow needs, parked on the top edge of the
# screen -- exactly where browser tab strips and title-bar buttons live. The
# reported symptom was browser tabs that simply would not click.
#
# The fix is WS_EX_TRANSPARENT, toggled from a cursor poll: on while the pointer
# is anywhere else (every click falls straight through to the app underneath),
# off the moment the pointer reaches the widget's visible surface.
#
# Why not answer WM_NCHITTEST with HTTRANSPARENT, which is the textbook answer?
# Because that requires writing to the hook's `ref bool handled` parameter, and
# a PowerShell scriptblock converted to a delegate cannot write to a ref
# parameter -- the assignment is silently dropped, WPF never sees handled=true,
# and the return value is ignored. It looks correct and does nothing;
# test_logbook_clickthrough.ps1 is what caught it.
# Deliberately its own type rather than the timer's LogixWin: this file is
# dot-sourced by scripts that never create a widget, and keeping the helper
# self-contained is what lets the click-through be tested on its own.
# Compiled on first use -- see Use-LogbookNativeType for why that matters.
$script:LogixClickThroughSrc = @"
using System;
using System.Runtime.InteropServices;
public static class LogixClickThrough {
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")] static extern IntPtr GetLongPtr64(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint="GetWindowLong")] static extern int GetLong32(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtr")] static extern IntPtr SetLongPtr64(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll", EntryPoint="SetWindowLong")] static extern int SetLong32(IntPtr h, int i, int v);
    // High bit set = physically down right now. Polled, not hooked -- this is
    // for "did the user click OUTSIDE the popup", the same signal a native
    // dropdown/menu uses to dismiss itself.
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    const int VK_LBUTTON = 0x01;
    public static bool LeftButtonDown() { return (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0; }

    static long Ex(IntPtr h) {
        return IntPtr.Size == 8 ? GetLongPtr64(h, GWL_EXSTYLE).ToInt64() : (long)(uint)GetLong32(h, GWL_EXSTYLE);
    }
    public static POINT Cursor() { POINT p; GetCursorPos(out p); return p; }
    public static bool IsOn(IntPtr h) { return (Ex(h) & WS_EX_TRANSPARENT) != 0; }

    // Read-modify-write so the caller's WS_EX_TOOLWINDOW / WS_EX_NOACTIVATE
    // survive. Widening through uint first, never a bare int|long: that is the
    // CS0675 sign-extension warning, and Add-Type treats warnings as errors.
    public static void Set(IntPtr h, bool on) {
        long cur = Ex(h);
        long bit = (long)(uint)WS_EX_TRANSPARENT;
        long next = on ? (cur | bit) : (cur & ~bit);
        if (next == cur) return;
        if (IntPtr.Size == 8) { SetLongPtr64(h, GWL_EXSTYLE, new IntPtr(next)); }
        else { SetLong32(h, GWL_EXSTYLE, (int)(uint)next); }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll", EntryPoint = "GetWindowRect")] static extern bool GetWindowRectRaw(IntPtr h, out RECT r);
    // The window's TRUE on-screen footprint, in the same physical pixels
    // GetCursorPos reports. Needed because this host (plain powershell.exe,
    // no per-monitor-v2 manifest) is not DPI-aware -- Windows silently
    // bitmap-scales the whole window for display, and WPF's own
    // PointToScreen has no idea that happened, so it keeps answering in the
    // UN-scaled logical space. The two agree near the window's origin and
    // drift apart with distance from it, which is why a short pill was fine
    // and a tall card was not: the drift is proportional to how far down
    // the element sits.
    public static RECT WindowRect(IntPtr h) { RECT r; GetWindowRectRaw(h, out r); return r; }
}
"@

# Compile a P/Invoke helper the first time something actually calls it.
#
# Add-Type shells out to csc.exe: roughly 370ms for the first type in a process
# and 250ms for every one after. Compiling at file scope charged that to EVERY
# script that dot-sources this file, whether or not it uses the type -- and the
# sign-in popup, the one surface a person stands there waiting for at login, was
# paying ~570ms for a click-through helper and an idle-input helper it never
# touches. Parsing this whole file, by comparison, costs 18ms.
function Use-LogbookNativeType {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Source
    )
    if (([System.Management.Automation.PSTypeName]$Name).Type) { return }
    Add-Type -TypeDefinition $Source
}

# Screen rectangle of a laid-out element, in physical pixels. Two PointToScreen
# calls rather than ActualWidth arithmetic, so it is correct at any DPI and
# follows the pill as it auto-sizes -- no rectangle here can drift out of step
# with the XAML.
# PointToScreen alone is wrong on this host: plain powershell.exe carries no
# per-monitor-v2 manifest, so Windows bitmap-scales the whole window for
# display while WPF's PointToScreen keeps answering in the un-scaled logical
# space. The two agree near the window's origin and drift apart with distance
# from it -- harmless for a short pill, but the redesigned card is tall enough
# that its bottom (the SELESAI button) landed outside its own click-through
# rect. Ground truth instead in the window's real GetWindowRect (physical
# pixels, same space GetCursorPos reports) and scale this element's
# window-relative DIP offset into that space.
function Get-LogbookSurfaceRect($Element, [IntPtr]$Hwnd = [IntPtr]::Zero) {
    if (-not $Element -or -not $Element.IsVisible -or $Element.ActualWidth -le 0) { return $null }
    $win = [System.Windows.Window]::GetWindow($Element)
    if (-not $win -or $win.ActualWidth -le 0 -or $win.ActualHeight -le 0) { return $null }
    if ($Hwnd -eq [IntPtr]::Zero) {
        $Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    }
    if ($Hwnd -eq [IntPtr]::Zero) { return $null }
    Use-LogbookNativeType -Name 'LogixClickThrough' -Source $script:LogixClickThroughSrc

    $native = [LogixClickThrough]::WindowRect($Hwnd)
    $scaleX = ($native.R - $native.L) / $win.ActualWidth
    $scaleY = ($native.B - $native.T) / $win.ActualHeight

    $toWin = $Element.TransformToVisual($win)
    $tl = $toWin.Transform((New-Object System.Windows.Point 0, 0))
    $br = $toWin.Transform((New-Object System.Windows.Point $Element.ActualWidth, $Element.ActualHeight))

    return @{
        L = $native.L + ($tl.X * $scaleX)
        T = $native.T + ($tl.Y * $scaleY)
        R = $native.L + ($br.X * $scaleX)
        B = $native.T + ($br.Y * $scaleY)
    }
}

# Should the window pass clicks through, given where the pointer is? Pure, so
# the test can drive it with synthetic points instead of moving the real mouse.
# $Grace widens the target slightly: the pill is small on purpose now, and a
# hover target you have to hit exactly is a worse problem than the one we fixed.
function Test-LogbookClickThrough {
    param($Rect, [double]$X, [double]$Y, [double]$Grace = 3)
    if (-not $Rect) { return $true }
    return ($X -lt ($Rect.L - $Grace) -or $X -gt ($Rect.R + $Grace) -or
            $Y -lt ($Rect.T - $Grace) -or $Y -gt ($Rect.B + $Grace))
}

# -GetSurface returns the FrameworkElement the user can currently see (the pill,
# the expanded card, the sliver), or $null when nothing is visible.
# -OnPointerEnter / -OnPointerLeave let the caller drive expand/collapse from
# this poll. That matters: while the window is click-through it receives no
# mouse messages at all, so WPF's own MouseEnter cannot be the only trigger.
function Register-LogbookClickThrough {
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)] [scriptblock] $GetSurface,
        [scriptblock] $OnPointerEnter,
        [scriptblock] $OnPointerLeave,
        # Fires on a left-click that lands OUTSIDE the current surface --
        # dismiss-on-outside-click, the same rule every native menu/dropdown
        # uses. Only meaningful while the caller considers something "open"
        # (GetSurface returning non-null); a caller with nothing open should
        # just not need it.
        [scriptblock] $OnOutsideClick,
        [int] $PollMs = 40,
        [double] $Grace = 3
    )
    Use-LogbookNativeType -Name 'LogixClickThrough' -Source $script:LogixClickThroughSrc
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
    if ($hwnd -eq [IntPtr]::Zero) {
        throw "Register-LogbookClickThrough needs a realised window (call it from SourceInitialized or later)."
    }
    # Start click-through: the pointer is not on the widget the instant it appears.
    [LogixClickThrough]::Set($hwnd, $true)

    $st = [pscustomobject]@{ Hwnd = $hwnd; Get = $GetSurface; Grace = $Grace
                             Enter = $OnPointerEnter; Leave = $OnPointerLeave
                             Outside = $OnOutsideClick; Over = $false; WasDown = $false }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($PollMs)
    $timer.Add_Tick({
        try {
            $p = [LogixClickThrough]::Cursor()
            $rect = Get-LogbookSurfaceRect (& $st.Get) $st.Hwnd
            $through = Test-LogbookClickThrough -Rect $rect -X $p.X -Y $p.Y -Grace $st.Grace
            [LogixClickThrough]::Set($st.Hwnd, $through)

            $over = -not $through
            if ($over -ne $st.Over) {
                $st.Over = $over
                if ($over) { if ($st.Enter) { & $st.Enter } }
                else       { if ($st.Leave) { & $st.Leave } }
            }

            # Edge-triggered on the button transition, not "is it down" --
            # otherwise a click that STARTED outside and dragged in (or a
            # held button from before the surface even opened) would fire
            # every single poll tick while held.
            $down = [LogixClickThrough]::LeftButtonDown()
            if ($down -and -not $st.WasDown -and $through -and $rect -and $st.Outside) {
                & $st.Outside
            }
            $st.WasDown = $down
        } catch { }
    }.GetNewClosure())
    $timer.Start()
    # Handed back so the caller can stop it on shutdown, and so a test can tick
    # it by hand.
    return $timer
}

function Build-LogbookTimerXaml($cfg, $session, $deviceName) {
    $res = Build-LogbookClientResources $cfg
    $tSelesai = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'timerEndHold' 'Tahan untuk selesai')
    # Baked in rather than filled at press time. The caption has to occupy its
    # final height from the very first layout: it is Hidden, not Collapsed, so
    # revealing it cannot change the card's size. See the XAML note below.
    $tArmed = ConvertTo-LogbookXmlText (Get-LogbookText $cfg 'timerEndArmed' 'Terus tahan...')

    $nama   = ConvertTo-LogbookXmlText ([string]$session.nama)
    $tujuan = ConvertTo-LogbookXmlText ([string]$session.tujuan)
    # A display name reads "WS-07 - GPU-A100": the station ID is the card
    # header's right-hand identity, the spec goes on the Perangkat row next to
    # the access type. Split only on a SPACED separator (" - " or a spaced middle dot) --
    # "WS-07" contains a hyphen itself, so an unspaced split leaves just "WS".
    $parts = [regex]::Split([string]$deviceName, '\s+(?:-|\u00B7)\s+')
    $station = ConvertTo-LogbookXmlText ($parts[0].Trim())
    $spec = if ($parts.Count -gt 1) { (($parts[1..($parts.Count - 1)]) -join ' ').Trim() } else { $parts[0].Trim() }
    $access = ConvertTo-LogbookXmlText ([string]$session.session_type)
    $perangkat = ConvertTo-LogbookXmlText $spec
    if ($access) { $perangkat = "$perangkat &#183; $access" }

    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        Topmost="True" ShowInTaskbar="False" AllowsTransparency="True"
        Background="Transparent" FontFamily="Segoe UI" Left="0" Top="0">
  <Window.Resources>
$res
  </Window.Resources>

  <Grid Name="RootVisual" Margin="20,6,20,36">

    <!-- ===== 1. PILL (collapsed, default posture) ===================== -->
    <Border Name="PillView" Height="26" CornerRadius="13" Padding="11,0" Opacity="0.72"
            Background="#EB0B1017" BorderBrush="{StaticResource LxHairline}" BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Top">
      <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
      <!-- Lighter than the card's: a 26px pill under a 24/8 shadow looks like it
           is hovering an inch off the glass. -->
      <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="5" Direction="270" Opacity="0.35" Color="#000000"/></Border.Effect>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Ellipse Name="PillDot" Width="7" Height="7" Fill="{StaticResource LxActive}" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock Name="PillClock" Text="00:00" FontFamily="Consolas" FontSize="12"
                   Foreground="{StaticResource LxText}" VerticalAlignment="Center"/>
        <Border Name="PillBadge" Visibility="Collapsed" MinWidth="16" Height="16" CornerRadius="8"
                Background="{StaticResource LxNotice}" Margin="8,0,0,0" VerticalAlignment="Center">
          <TextBlock Name="PillBadgeText" Text="1" FontFamily="Consolas" FontSize="10" FontWeight="Bold"
                     Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="4,0"/>
        </Border>
      </StackPanel>
    </Border>

    <!-- ===== 2. SLIVER (strip posture, peeked) ======================== -->
    <Border Name="SliverView" Visibility="Collapsed" Height="24" CornerRadius="12"
            Background="{StaticResource LxSurface}" BorderBrush="{StaticResource LxHairline}" BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Top" Padding="14,0">
      <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
      <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="8" Direction="270" Opacity="0.45" Color="#000000"/></Border.Effect>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Ellipse Name="SliverDot" Width="6" Height="6" Fill="{StaticResource LxActive}" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <Border Name="SliverBadge" Visibility="Collapsed" MinWidth="15" Height="15" CornerRadius="8"
                Background="{StaticResource LxNotice}" Margin="0,0,8,0" VerticalAlignment="Center">
          <TextBlock Name="SliverBadgeText" Text="1" FontFamily="Consolas" FontSize="10" FontWeight="Bold"
                     Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="4,0"/>
        </Border>
        <TextBlock Name="SliverText" Text="00:00" FontFamily="Consolas" FontSize="12"
                   Foreground="{StaticResource LxText}" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>

    <!-- ===== 3. EXPAND CARD (hover / sliver click) ==================== -->
    <Border Name="CardView" Visibility="Collapsed" Width="240" CornerRadius="22"
            Background="{StaticResource LxElevated}" BorderBrush="{StaticResource LxHairline}" BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Top" Padding="18,16" RenderTransformOrigin="0.5,0">
      <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Border.RenderTransform>
      <Border.Effect><DropShadowEffect BlurRadius="36" ShadowDepth="12" Direction="270" Opacity="0.5" Color="#000000"/></Border.Effect>
      <StackPanel>

        <!-- Session identity. Hidden while armed or while a message is open.
             A ring plus a big centered clock, not a label/value table: the
             "feels native" reference for this was a status-bar widget's own
             popup (YASB's pomodoro), which anchors a circular dial with the
             time inside it rather than a form. There is no fixed-duration
             target here to draw a partial arc against, since a lab session
             has no "25:00" to count down to, so the ring is a static frame,
             not a progress indicator: an accurate one that looks decorative
             beats a precise-looking one that lies about progress that does
             not exist. -->
        <StackPanel Name="CardInfo" HorizontalAlignment="Center">
          <Grid Width="152" Height="152" Margin="0,2,0,14" HorizontalAlignment="Center">
            <Ellipse Width="152" Height="152" Stroke="{StaticResource LxHairline}" StrokeThickness="2"/>
            <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
              <Ellipse Name="CardDot" Width="8" Height="8" Fill="{StaticResource LxActive}"
                       HorizontalAlignment="Center" Margin="0,0,0,10"/>
              <TextBlock Name="CardClock" Text="00:00:00" FontFamily="Consolas" FontSize="24" FontWeight="SemiBold"
                         Foreground="{StaticResource LxText}" HorizontalAlignment="Center"/>
              <TextBlock Name="CardStation" Text="$station" FontFamily="Consolas" FontSize="11"
                         Foreground="{StaticResource LxMuted}" HorizontalAlignment="Center" Margin="0,6,0,0"
                         TextTrimming="CharacterEllipsis" MaxWidth="120"/>
            </StackPanel>
          </Grid>
          <TextBlock Name="NamaValue" Text="$nama" FontFamily="Consolas" FontSize="12.5"
                     Foreground="{StaticResource LxText}" HorizontalAlignment="Center"
                     TextTrimming="CharacterEllipsis" MaxWidth="204" Margin="0,0,0,3"/>
          <!-- Two real TextBlocks, not inline Runs: the test suite finds
               fields by walking TextBlock elements specifically, and a Run
               is a different element type it would silently never find. -->
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,14">
            <TextBlock Name="TujuanValue" Text="$tujuan" FontSize="11.5" Foreground="{StaticResource LxMuted}"
                       TextTrimming="CharacterEllipsis" MaxWidth="95"/>
            <TextBlock Text=" &#183; " FontSize="11.5" Foreground="{StaticResource LxMuted}"/>
            <TextBlock Name="DeviceValue" Text="$perangkat" FontSize="11.5" Foreground="{StaticResource LxMuted}"
                       TextTrimming="CharacterEllipsis" MaxWidth="95"/>
          </StackPanel>
        </StackPanel>

        <!-- Admin message. Never auto-expands; revealed when the user hovers. -->
        <StackPanel Name="CardMessage" Visibility="Collapsed">
          <Border Height="1" Background="{StaticResource LxHairline}" Margin="0,0,0,10"/>
          <TextBlock Name="MessageMeta" Text="ADMIN" FontFamily="Consolas" FontSize="10.5"
                     Foreground="{StaticResource LxMuted}" Margin="0,0,0,4"/>
          <TextBlock Name="MessageText" Text="" FontFamily="Segoe UI" FontSize="12.5" LineHeight="18"
                     Foreground="{StaticResource LxText}" TextWrapping="Wrap" Margin="0,0,0,12"/>
        </StackPanel>

        <!-- Quick replies: two one-tap answers plus a free-text escape. -->
        <StackPanel Name="CardQuickReply" Visibility="Collapsed" Orientation="Horizontal" Margin="0,0,0,2">
          <Button Name="QuickOkBtn" Content="OK" Style="{StaticResource LxPill}" Padding="13,6" FontSize="11.5" Margin="0,0,6,0"/>
          <Button Name="QuickWaitBtn" Content="Butuh 10 mnt" Style="{StaticResource LxPill}" Padding="13,6" FontSize="11.5" Margin="0,0,6,0"/>
          <Button Name="QuickFreeBtn" Content="Balas..." Style="{StaticResource LxPill}" Padding="13,6" FontSize="11.5"
                  Foreground="{StaticResource LxMuted}"/>
        </StackPanel>

        <!-- Free-text reply. Enter sends; the card will not auto-collapse while
             this field has focus. -->
        <Grid Name="CardReplyRow" Visibility="Collapsed" Margin="0,0,0,2">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border CornerRadius="999" BorderBrush="{StaticResource LxAccent}" BorderThickness="1" Padding="13,6" Margin="0,0,6,0">
            <TextBox Name="ReplyInput" Background="Transparent" BorderThickness="0" FontSize="12"
                     Foreground="{StaticResource LxText}" CaretBrush="{StaticResource LxAccent}"
                     MaxLength="140" VerticalContentAlignment="Center"/>
          </Border>
          <Button Name="ReplySendBtn" Grid.Column="1" Width="30" Height="30" Cursor="Hand"
                  Background="{StaticResource LxAccent}" BorderThickness="0">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border CornerRadius="15" Background="{TemplateBinding Background}">
                  <Path Data="M 5,12 L 19,12 M 13,6 L 19,12 L 13,18" Stroke="#FFFFFF" StrokeThickness="2.2"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                        Width="13" Height="13" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </ControlTemplate>
            </Button.Template>
          </Button>
        </Grid>

        <!-- Reply confirmation. Dot returns to green, card auto-collapses in 5s. -->
        <StackPanel Name="CardSent" Visibility="Collapsed" Orientation="Horizontal">
          <Border Height="1" Background="{StaticResource LxHairline}" Margin="0,0,0,10" Visibility="Collapsed"/>
          <Path Data="M 4,12.5 L 9.5,18 L 20,6.5" Stroke="{StaticResource LxActive}" StrokeThickness="2.4"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                Width="13" Height="13" Stretch="Uniform" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock Name="SentText" Text="Terkirim ke admin" FontSize="12"
                     Foreground="{StaticResource LxMuted}" VerticalAlignment="Center"/>
        </StackPanel>

        <!-- SELESAI: press-and-hold to confirm, not a tap. SelesaiFill is an
             empty-width Border the controller grows left-to-right over the
             hold. The fill is deliberately SQUARE-cornered and relies on the
             controller's rounded Clip to shape it: giving the fill its own
             CornerRadius instead made a part-grown fill render as a floating
             lozenge that had visibly detached from the left edge, rather than
             as the pill filling up. ClipToBounds cannot do this job on its
             own, because a Border clips to its rectangle, corner radius and
             all; the controller installs a real rounded clip instead.

             THE LABEL IS DRAWN TWICE, and that is the point of the control.
             SelesaiLabel is the resting copy; SelesaiSweepLabel is an
             identical copy in the critical colour, sitting inside a clipping
             Border (SelesaiSweep) that the controller grows to exactly the
             fill's width. So the hold does not repaint the text, it UNCOVERS
             it: the words change colour one at a time as the fill passes
             under them, which is what reads as a progress meter without a
             progress bar's chrome. The alternative already tried here (one
             label swapping colour wholesale partway through) has to pick a
             threshold, and at that threshold the entire label blinks.

             SelesaiSweepInner is a fixed-width Grid, not an auto-width one.
             The copy has to stay centred against the WHOLE button while its
             container is only a slice of it, so the controller sets this to
             the track's measured width; letting it size to the slice would
             slide the text leftward as the fill grew. -->
        <Border Name="SelesaiBtn" Height="36" CornerRadius="20" ClipToBounds="True"
                Background="{StaticResource LxSurface}" BorderBrush="{StaticResource LxHairline}"
                BorderThickness="1" Cursor="Hand">
          <Grid Name="SelesaiTrack">
            <Border Name="SelesaiFill" Background="{StaticResource LxCriticalWash}"
                    HorizontalAlignment="Left" Width="0"/>
            <TextBlock Name="SelesaiLabel" Text="$tSelesai" HorizontalAlignment="Center"
                       VerticalAlignment="Center" TextWrapping="NoWrap"
                       FontFamily="Segoe UI Semibold" FontSize="12.5"
                       Foreground="{StaticResource LxText}"/>
            <Border Name="SelesaiSweep" HorizontalAlignment="Left" Width="0" ClipToBounds="True">
              <Grid Name="SelesaiSweepInner" HorizontalAlignment="Left">
                <TextBlock Name="SelesaiSweepLabel" Text="$tSelesai" HorizontalAlignment="Center"
                           VerticalAlignment="Center" TextWrapping="NoWrap"
                           FontFamily="Segoe UI Semibold" FontSize="12.5"
                           Foreground="{StaticResource LxCriticalSoft}"/>
              </Grid>
            </Border>
          </Grid>
        </Border>
        <!-- Hidden, NOT Collapsed, and its text is baked in rather than set on
             press. Collapsed reserves no space, so revealing this on mouse-down
             grew the card, slid SELESAI out from under the stationary cursor,
             and WPF fired MouseLeave on the button, cancelling the hold about
             110ms after it started, every time. Reserving the space means
             pressing changes no geometry at all. -->
        <TextBlock Name="ArmedCaption" Visibility="Hidden" Text="$tArmed"
                   FontSize="11" Foreground="{StaticResource LxMuted}"
                   HorizontalAlignment="Center" Margin="0,8,0,0"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
}

function Build-LogbookServerPairingXaml($cfg, $state) {
    # "Koneksi Server": the screen that makes the server optional in practice
    # and not just on paper. Deliberately shaped as a STATUS panel with actions
    # rather than as a wizard -- a wizard implies a thing you must finish, and
    # the correct outcome here is very often "stay unpaired".
    $res = Build-LogbookClientResources $cfg
    $serverUrl = ConvertTo-LogbookXmlText ([string]$state.ServerUrl)
    $deviceId  = ConvertTo-LogbookXmlText ([string]$state.DeviceId)
    $idLine = if ($state.DeviceId) { "ID perangkat: $deviceId" } else { '' }

    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" SizeToContent="Height"
        Width="420" WindowStartupLocation="CenterScreen"
        Topmost="False" ShowInTaskbar="True" AllowsTransparency="True"
        Background="Transparent" FontFamily="Segoe UI">
  <Window.Resources>
$res
  </Window.Resources>
  <Border CornerRadius="20" Background="{StaticResource LxElevated}" Margin="18"
          BorderBrush="{StaticResource LxHairline}" BorderThickness="1" Padding="26,24">
    <Border.Effect><DropShadowEffect BlurRadius="48" ShadowDepth="14" Direction="270" Opacity="0.5" Color="#000000"/></Border.Effect>
    <StackPanel>

      <Grid Margin="0,0,0,18">
        <TextBlock Text="Koneksi Server" FontFamily="Segoe UI Semibold" FontSize="17"
                   Foreground="{StaticResource LxText}" VerticalAlignment="Center"/>
        <Button Name="CloseBtn" Content="Tutup" Style="{StaticResource LxPill}" Padding="12,5"
                FontSize="11.5" HorizontalAlignment="Right" Foreground="{StaticResource LxMuted}"/>
      </Grid>

      <!-- Status first. Someone opening this screen is usually asking "is it
           connected?", not "how do I connect?" -->
      <Border CornerRadius="14" Background="{StaticResource LxSurface}" Padding="14,12" Margin="0,0,0,18"
              BorderBrush="{StaticResource LxHairline}" BorderThickness="1">
        <StackPanel>
          <StackPanel Orientation="Horizontal">
            <Ellipse Name="StatusDot" Width="8" Height="8" Fill="{StaticResource LxMuted}"
                     VerticalAlignment="Center" Margin="0,0,9,0"/>
            <TextBlock Name="StatusText" Text="Tidak terhubung" FontSize="13"
                       Foreground="{StaticResource LxText}" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Name="DeviceIdText" Text="$idLine" FontFamily="Consolas" FontSize="11"
                     Foreground="{StaticResource LxMuted}" Margin="17,5,0,0"
                     TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </Border>

      <TextBlock Text="Alamat server" FontSize="11.5" Foreground="{StaticResource LxMuted}" Margin="0,0,0,6"/>
      <Border CornerRadius="10" Background="{StaticResource LxSurface}" Padding="12,9" Margin="0,0,0,14"
              BorderBrush="{StaticResource LxHairline}" BorderThickness="1">
        <TextBox Name="ServerBox" Text="$serverUrl" Background="Transparent" BorderThickness="0"
                 FontSize="12.5" FontFamily="Consolas" Foreground="{StaticResource LxText}"
                 CaretBrush="{StaticResource LxAccent}"/>
      </Border>

      <StackPanel Name="CodeRow">
        <TextBlock Text="Kode pairing" FontSize="11.5" Foreground="{StaticResource LxMuted}" Margin="0,0,0,6"/>
        <Border CornerRadius="10" Background="{StaticResource LxSurface}" Padding="12,9" Margin="0,0,0,6"
                BorderBrush="{StaticResource LxHairline}" BorderThickness="1">
          <TextBox Name="CodeBox" Background="Transparent" BorderThickness="0"
                   FontSize="12.5" FontFamily="Consolas" Foreground="{StaticResource LxText}"
                   CaretBrush="{StaticResource LxAccent}"/>
        </Border>
        <TextBlock Text="Minta kode sekali-pakai ini ke admin lab." FontSize="11"
                   Foreground="{StaticResource LxMuted}" Margin="0,0,0,14"/>
      </StackPanel>

      <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
        <Button Name="ConnectBtn" Content="Hubungkan" Style="{StaticResource LxPill}" Padding="16,8"
                FontSize="12.5" Background="{StaticResource LxAccent}" BorderBrush="{StaticResource LxAccent}"
                Foreground="#FFFFFF" Margin="0,0,7,0"/>
        <Button Name="TestBtn" Content="Uji koneksi" Style="{StaticResource LxPill}" Padding="14,8"
                FontSize="12.5" Margin="0,0,7,0"/>
        <Button Name="DisconnectBtn" Content="Putuskan" Style="{StaticResource LxPill}" Padding="14,8"
                FontSize="12.5" Foreground="{StaticResource LxMuted}" Visibility="Collapsed"/>
      </StackPanel>

      <TextBlock Name="MessageText" Text="" FontSize="11.5" TextWrapping="Wrap" LineHeight="17"
                 Foreground="{StaticResource LxMuted}" Margin="0,14,0,0"/>

      <Border Height="1" Background="{StaticResource LxHairline}" Margin="0,16,0,12"/>
      <!-- Said plainly, because the alternative reading (that an unpaired
           device is a crippled one) is the exact misunderstanding this whole
           screen exists to prevent. -->
      <TextBlock FontSize="11" TextWrapping="Wrap" LineHeight="17" Foreground="{StaticResource LxMuted}"
                 Text="Tanpa server pun Logix tetap mencatat sesi dan membuat laporan di komputer ini. Menghubungkan ke server hanya menambah pemantauan terpusat dan laporan gabungan."/>
    </StackPanel>
  </Border>
</Window>
"@
}

function Build-LogbookStripXaml($cfg) {
    # Strip posture: a 3px full-width line pinned to the very top of the
    # screen, coloured by session status. Its own window because it must span
    # the whole width while the pill/card window stays narrow and draggable.
    # The controller makes it click-through (WS_EX_TRANSPARENT) so it never
    # steals a click from the app underneath -- the top edge stays a usable
    # target for the application, and the sliver is what the user aims at.
    $res = Build-LogbookClientResources $cfg
    return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        AllowsTransparency="True" Background="Transparent" Height="3" Left="0" Top="0">
  <Window.Resources>
$res
  </Window.Resources>
  <Border Name="StripBar" Background="{StaticResource LxActive}"/>
</Window>
"@
}

function Get-ActiveLogbookSession {
    try {
        if (Test-Path $Global:SessionFile) {
            return (Get-Content $Global:SessionFile -Raw | ConvertFrom-Json)
        }
    } catch { Write-LogbookError "Read active session failed: $($_.Exception.Message)" }
    return $null
}

function Get-ActiveLogbookSessionAgeSeconds {
    $session = Get-ActiveLogbookSession
    if ($null -eq $session -or -not $session.start_time) { return $null }
    try {
        $start = [datetime]$session.start_time
        return [int]((Get-Date) - $start).TotalSeconds
    } catch { return $null }
}

function Close-ActiveLogbookSession {
    param([string]$Reason = 'END')
    Ensure-LogbookDirs
    try {
        if (Test-Path $Global:SessionFile) {
            $session = Get-Content $Global:SessionFile -Raw | ConvertFrom-Json
            [void](Invoke-WSLLogbook -Event $Reason -SessionType $session.session_type -AnyDeskDetected ([int]$session.anydesk_detected) -SessionId $session.session_id -Nama $session.nama -Nim $session.nim -Tujuan $session.tujuan -Keterangan $session.keterangan)
            Remove-Item $Global:SessionFile -Force -ErrorAction SilentlyContinue
            if (Test-Path $Global:SessionFile) {
                # Removing session.json is what actually ends the session; if it
                # survives, the session is NOT closed no matter that the event
                # was logged above. Almost always an ACL/ownership problem (the
                # file was created by an elevated run and this process is not).
                # Do NOT report success -- surface the real error and fail so the
                # caller (and the log) can see why SELESAI "did nothing".
                try {
                    Remove-Item $Global:SessionFile -Force -ErrorAction Stop
                } catch {
                    Write-LogbookError "Could NOT remove session file '$($Global:SessionFile)' closing sid=$($session.session_id) reason=$Reason -- session will not end and its timer keeps running. Likely ACL/ownership (file owned by another/elevated account). Run windows\repair_logbook_permissions.ps1 as admin. Error: $($_.Exception.Message)"
                    Stop-LogbookTimers
                    return $false
                }
            }
            Write-LogbookInfo "Closed active session sid=$($session.session_id) reason=$Reason"
        }
        Stop-LogbookTimers
        return $true
    } catch {
        Write-LogbookError "Close active session failed: $($_.Exception.Message)"
        Stop-LogbookTimers
        return $false
    }
}

function Get-SystemBootTime {
    try {
        return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch {
        Write-LogbookError "Get boot time failed: $($_.Exception.Message)"
        return $null
    }
}

# A session file that predates the machine's most recent boot means whatever
# was supposed to close it (lock/logoff/shutdown handler) never finished --
# e.g. a hard shutdown killed the process before the WSL call completed, or
# the shutdown reason simply wasn't one Windows delivered to this process in
# time. Resuming it blindly (the old behavior) lets elapsed time keep
# accumulating across reboots -- this is how a session was observed still
# "active" 16 hours later. Call this before resuming any on-disk session.
function Close-StaleLogbookSessionIfAny {
    if (-not (Test-Path $Global:SessionFile)) { return $false }
    $session = Get-ActiveLogbookSession
    if ($null -eq $session -or -not $session.start_time) { return $false }
    try {
        $start = [datetime]$session.start_time
        $bootTime = Get-SystemBootTime
        if ($null -eq $bootTime) { return $false }
        if ($bootTime -gt $start) {
            Write-LogbookInfo "Stale session detected sid=$($session.session_id) started=$($session.start_time) boot=$($bootTime.ToString('o')); auto-closing instead of resuming."
            Close-ActiveLogbookSession -Reason 'AUTO_CLOSE' | Out-Null
            return $true
        }
    } catch { Write-LogbookError "Stale session check failed: $($_.Exception.Message)" }
    return $false
}

# Upper bound (seconds) on how long a single session may span before resuming it
# stops making sense as a logbook duration. Configurable via
# LOGIX_MAX_SESSION_HOURS; 0/unset falls back to the 8-hour default (roughly a
# working day). See Close-OverAgeLogbookSessionIfAny.
function Get-LogbookMaxSessionSeconds {
    $hours = Get-LogbookConfigEnv 'LOGIX_MAX_SESSION_HOURS'
    $parsed = 0.0
    if ($hours -and [double]::TryParse($hours, [ref]$parsed) -and $parsed -gt 0) {
        return [int]($parsed * 3600)
    }
    return 8 * 3600
}

# Companion to Close-StaleLogbookSessionIfAny, but keyed off wall-clock age
# rather than reboot. A machine locked or slept overnight WITHOUT a reboot keeps
# start_time newer than LastBootUpTime, so the stale-check above never fires and
# the session resumes with a timer reading e.g. 25:00:00 -- "continuing from
# yesterday". Call this on the resume/unlock path (see logbook_popup.ps1's
# early-exit and logbook_monitor.ps1): a session older than
# Get-LogbookMaxSessionSeconds is closed so a fresh sign-in form is shown
# instead. Deliberately NOT called on every timer tick of an actively-used
# unlocked session -- a legitimate long compute run stays open while the user is
# present; this only caps the "came back to a locked machine" case.
function Close-OverAgeLogbookSessionIfAny {
    if (-not (Test-Path $Global:SessionFile)) { return $false }
    $ageSec = Get-ActiveLogbookSessionAgeSeconds
    if ($null -eq $ageSec) { return $false }
    $maxSec = Get-LogbookMaxSessionSeconds
    if ($maxSec -le 0) { return $false }
    if ($ageSec -ge $maxSec) {
        Write-LogbookInfo "Session age ${ageSec}s exceeds cap ${maxSec}s; auto-closing instead of resuming."
        Close-ActiveLogbookSession -Reason 'AUTO_CLOSE' | Out-Null
        return $true
    }
    return $false
}

# Product decision: a lock or sleep/resume cycle, by itself, is NOT a
# session boundary -- someone stepping away for coffee (or a laptop lid
# closing) shouldn't split one lab visit into two logbook rows, no matter
# how long the lock/sleep lasted. Only a real departure signal ends a
# session: explicit sign-out (this function, wired to the timer widget's
# SELESAI button), OS shutdown/logoff (SessionEnding /
# ConsoleDisconnect/RemoteDisconnect/SessionLogoff in logbook_monitor.ps1),
# reboot (Close-StaleLogbookSessionIfAny above), or genuinely being idle
# with the screen unlocked for LOGIX_IDLE_TIMEOUT_HOURS (below). Locking
# the workstation here is deliberate: it both signals departure to anyone
# walking up to the machine and guarantees the *next* sign-in goes through
# the unlock path, which starts a fresh session when none is on disk.
function Close-LogbookSessionAndLock {
    Close-ActiveLogbookSession -Reason 'END' | Out-Null
    # Guarantee the next sign-in form appears rather than relying solely on the
    # monitor's SessionUnlock event, which was observed NOT to re-prompt after an
    # END (leaving the user with no way to start a new session on return). The
    # popup is a full-screen topmost overlay, so it sits ready behind the Windows
    # lock screen and is there the moment the user signs back in.
    Start-LogbookPopup | Out-Null
    try {
        Start-Process 'rundll32.exe' -ArgumentList 'user32.dll,LockWorkStation' | Out-Null
    } catch {
        Write-LogbookError "Lock workstation failed: $($_.Exception.Message)"
    }
}

# How often the monitor heartbeats the server AND polls for queued remote
# commands (lock / message / power). Lower = snappier remote actions -- a lock
# from the dashboard lands within this many seconds instead of up to 30 -- at
# the cost of more requests. Configurable via LOGIX_HEARTBEAT_SECONDS; default
# 5s, floored at 2s.
function Get-LogbookHeartbeatSeconds {
    $val = Get-LogbookConfigEnv 'LOGIX_HEARTBEAT_SECONDS'
    $parsed = 0
    if ($val -and [int]::TryParse($val, [ref]$parsed) -and $parsed -ge 2) {
        return $parsed
    }
    return 5
}

# Idle auto-end threshold, in seconds. RETURNS 0 WHEN THE POLICY IS OFF -- every
# caller must treat 0 as "never auto-close", not as "close immediately".
#
# Resolution order:
#   1. devices.idle_auto_end.<category> from the server-delivered config
#      (Settings > Perangkat). Ships disabled for every category, so an
#      upgrade never starts closing sessions on its own.
#   2. LOGIX_IDLE_TIMEOUT_HOURS, the pre-existing env override.
#   3. The historical 4-hour default.
function Get-LogbookIdleTimeoutSeconds {
    try {
        $cfg = Get-LogbookConfig
        $policy = $null
        if ($cfg -and $cfg.devices -and $cfg.devices.idle_auto_end) {
            $category = [string]$cfg.devices.category
            if (-not $category) { $category = 'custom' }
            $map = $cfg.devices.idle_auto_end
            if ($map.Contains($category)) { $policy = $map[$category] }
        }
        if ($null -ne $policy) {
            if (-not $policy.enabled) { return 0 }
            $h = 0.0
            if ([double]::TryParse([string]$policy.hours, [ref]$h) -and $h -gt 0) {
                return [int]($h * 3600)
            }
        }
    } catch {
        Write-LogbookError "Idle policy lookup failed: $($_.Exception.Message)"
    }

    $hours = Get-LogbookConfigEnv 'LOGIX_IDLE_TIMEOUT_HOURS'
    $parsed = 0.0
    if ($hours -and [double]::TryParse($hours, [ref]$parsed) -and $parsed -gt 0) {
        return [int]($parsed * 3600)
    }
    return 4 * 3600
}

$script:LogixIdleSrc = @"
using System;
using System.Runtime.InteropServices;
public static class LogixIdle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
}
"@

# Seconds since the last keyboard/mouse input anywhere on the machine (not
# per-window) -- used only to catch "left unlocked and walked away"; a
# locked screen is gated out separately (see logbook_monitor.ps1's
# workstation_locked.flag) because locking already means "same session,
# any duration" per the product decision above.
function Get-LogbookIdleSeconds {
    try {
        Use-LogbookNativeType -Name 'LogixIdle' -Source $script:LogixIdleSrc
        $lii = New-Object LogixIdle+LASTINPUTINFO
        $lii.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($lii)
        if (-not [LogixIdle]::GetLastInputInfo([ref]$lii)) { return $null }
        $idleMs = [Environment]::TickCount - $lii.dwTime
        if ($idleMs -lt 0) { return 0 }
        return [double]$idleMs / 1000.0
    } catch {
        Write-LogbookError "Get idle seconds failed: $($_.Exception.Message)"
        return $null
    }
}
