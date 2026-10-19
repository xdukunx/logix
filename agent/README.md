# logix.exe — the native workstation core

One small Rust binary (~1.8 MB, no runtime to install) that does the work a
lab PC does all day, so the Windows client stays light on any machine.

| | before | logix.exe |
|---|---|---|
| Resident agent (heartbeat, commands, sync, idle, lock/unlock) | PowerShell monitor, ~100 MB | ~11 MB working set, ~2 MB private |
| One session event (START/END) | Python, ~106 ms, ~24 MB peak | ~15 ms, ~3 MB peak |
| Heartbeat side work | re-read AnyDesk ID and `/api/config` every 5 s | cached (10 min / 5 min) |

## What it is

* `logix.exe --json-file payload.json` and the other `log_physical.py` flags
  (`--sync-to-server`, `--sync-status`, `--sync-preview`, `--repair-active`,
  `--close-open`, `--migrate`) — a drop-in for the Python core: same table,
  same `sync_state.json`, same privacy-mode rules. `tests/test_rust_core.py`
  runs identical scenarios through both and compares the results.
* `logix.exe agent` — the resident monitor that replaces
  `windows/logbook_monitor.ps1`. It never draws anything: the sign-in popup,
  timer widget, lock screen and screenshot helper stay the WPF scripts and are
  started only when needed. Closing a session is native, so it still lands
  when Windows is shutting down.

The PowerShell side uses `logix.exe` whenever it sits next to the scripts
(`Get-LogixCoreCommand`) and falls back to Python and the PowerShell monitor
when it does not.

## Build

```
cd agent
cargo build --release      # -> target/release/logix.exe
```

`installer/build.ps1` runs this and ships the result as
`C:\Program Files\Logix\logix.exe`. Test hooks: `LOGIX_STATE_DIR` and
`LOGIX_INSTALL_DIR` redirect the agent's state and script directories.
