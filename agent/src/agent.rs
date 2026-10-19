//! `logix.exe agent` -- the resident workstation agent.
//!
//! Replaces logbook_monitor.ps1, which kept a whole PowerShell runtime
//! (~100 MB) resident on every lab PC to do a handful of small things on a
//! timer. Everything that loop did is here, natively:
//!
//!   * heartbeat (every LOGIX_HEARTBEAT_SECONDS, default 5) with session
//!     context, acks for the previous round's commands, and the privacy mode
//!   * server commands -- BROADCAST, LOCK, SCREENSHOT, SHUTDOWN, RESTART,
//!     LOGOFF -- deduplicated by command_id and acked on the next heartbeat
//!   * queued replies, flushed whenever the server is reachable
//!   * periodic delivery of unsynced session rows (in-process, no spawn)
//!   * closing a session that outlived LOGIX_MAX_SESSION_HOURS, that predates
//!     the last boot, or whose user went idle past the policy
//!   * lock/unlock/logoff/shutdown/suspend events, from a hidden window
//!   * the Task Manager gate watchdog
//!
//! What it does NOT do is draw anything: the sign-in popup, the timer widget,
//! the lock screen and the screenshot helper stay the existing WPF scripts,
//! started only when they are needed. Closing a session is native, so it
//! still lands when Windows is shutting down and there is no time to start
//! PowerShell for it.

#[cfg(not(windows))]
pub fn run(_args: &[String]) -> i32 {
    eprintln!("logix agent runs on Windows only");
    2
}

#[cfg(windows)]
pub use imp::run;

#[cfg(windows)]
mod imp {
    use crate::config::{read_json, Config};
    use crate::sync::{http_agent, post_json, Outcome};
    use crate::util::{now_iso, write_atomic};
    use serde_json::{json, Map, Value};
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::{mpsc, Mutex, OnceLock};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::*;
    use windows_sys::Win32::System::Registry::*;
    use windows_sys::Win32::System::RemoteDesktop::*;
    use windows_sys::Win32::System::SystemInformation::GetTickCount64;
    use windows_sys::Win32::System::Threading::*;
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
    use windows_sys::Win32::UI::WindowsAndMessaging::*;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    // ---- paths ---------------------------------------------------------

    /// Runtime state: %ProgramData%\Logix, exactly where the PowerShell side
    /// keeps session.json, timer.pid, the inbox and the acks. Overridable for
    /// tests only.
    fn state_dir() -> PathBuf {
        std::env::var("LOGIX_STATE_DIR").map(PathBuf::from).unwrap_or_else(|_| crate::config::system_data_home())
    }

    /// Where the scripts live: next to logix.exe (C:\Program Files\Logix).
    fn install_dir() -> PathBuf {
        if let Ok(v) = std::env::var("LOGIX_INSTALL_DIR") {
            return PathBuf::from(v);
        }
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| PathBuf::from(r"C:\Program Files\Logix"))
    }

    fn sp(name: &str) -> PathBuf {
        state_dir().join(name)
    }

    // ---- log -----------------------------------------------------------

    /// Same file and line shape as Write-LogbookError, so one log tells the
    /// whole story whichever side wrote it.
    pub fn log(msg: &str) {
        let path = sp("logbook_error.log");
        if std::fs::metadata(&path).map(|m| m.len() > 1_048_576).unwrap_or(false) {
            let mut old = path.as_os_str().to_owned();
            old.push(".old");
            let _ = std::fs::rename(&path, old);
        }
        let ts = crate::util::iso_o(&chrono::Local::now());
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            use std::io::Write;
            let _ = writeln!(f, "{ts} {msg}");
        }
    }

    fn info(msg: &str) {
        log(&format!("INFO: {msg}"));
    }

    // ---- small Win32 helpers -------------------------------------------

    fn mutex_exists(name: &str) -> bool {
        let w = wide(name);
        unsafe {
            let h = OpenMutexW(0x0010_0000 /* SYNCHRONIZE */, 0, w.as_ptr());
            if h.is_null() {
                return false;
            }
            CloseHandle(h);
            true
        }
    }

    fn process_image(pid: u32) -> Option<String> {
        unsafe {
            let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if h.is_null() {
                return None;
            }
            let mut code = 0u32;
            let alive = GetExitCodeProcess(h, &mut code) != 0 && code == STILL_ACTIVE as u32;
            let mut buf = [0u16; 520];
            let mut len = buf.len() as u32;
            let ok = QueryFullProcessImageNameW(h, 0, buf.as_mut_ptr(), &mut len) != 0;
            CloseHandle(h);
            if !alive || !ok {
                return None;
            }
            let full = String::from_utf16_lossy(&buf[..len as usize]);
            Some(full.rsplit('\\').next().unwrap_or("").to_lowercase())
        }
    }

    fn kill(pid: u32) {
        unsafe {
            let h = OpenProcess(PROCESS_TERMINATE, 0, pid);
            if !h.is_null() {
                TerminateProcess(h, 1);
                CloseHandle(h);
            }
        }
    }

    fn idle_seconds() -> Option<f64> {
        unsafe {
            let mut lii = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
            if GetLastInputInfo(&mut lii) == 0 {
                return None;
            }
            let now = windows_sys::Win32::System::SystemInformation::GetTickCount();
            Some(now.wrapping_sub(lii.dwTime) as f64 / 1000.0)
        }
    }

    fn boot_time() -> chrono::DateTime<chrono::Local> {
        let up = unsafe { GetTickCount64() };
        chrono::Local::now() - chrono::Duration::milliseconds(up as i64)
    }

    fn powershell(script: &str, args: &[&str], sta: bool) -> std::io::Result<std::process::Child> {
        let path = install_dir().join(script);
        let mut c = Command::new("powershell.exe");
        c.arg("-NoProfile");
        if sta {
            c.arg("-STA");
        }
        c.args(["-ExecutionPolicy", "Bypass", "-File"]).arg(&path).args(args);
        c.creation_flags(CREATE_NO_WINDOW).spawn()
    }

    // ---- session state -------------------------------------------------

    fn session() -> Option<Map<String, Value>> {
        read_json(&sp("session.json")).and_then(|v| v.as_object().cloned())
    }

    fn s(m: &Map<String, Value>, k: &str) -> String {
        crate::util::norm(m.get(k), "")
    }

    fn parse_time(t: &str) -> Option<chrono::DateTime<chrono::Local>> {
        let t = t.trim();
        if let Ok(d) = chrono::DateTime::parse_from_rfc3339(t) {
            return Some(d.with_timezone(&chrono::Local));
        }
        for f in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"] {
            if let Ok(n) = chrono::NaiveDateTime::parse_from_str(t, f) {
                return n.and_local_timezone(chrono::Local).single();
            }
        }
        None
    }

    fn popup_running() -> bool {
        mutex_exists("Local\\LogixSignInPopup")
    }

    fn timer_running() -> bool {
        let Ok(pid) = std::fs::read_to_string(sp("timer.pid")) else { return false };
        let Ok(pid) = pid.trim().trim_start_matches('\u{feff}').parse::<u32>() else { return false };
        matches!(process_image(pid).as_deref(), Some("powershell.exe" | "pwsh.exe" | "conhost.exe"))
    }

    fn stop_timer() {
        if let Ok(pid) = std::fs::read_to_string(sp("timer.pid")) {
            if let Ok(pid) = pid.trim().trim_start_matches('\u{feff}').parse::<u32>() {
                if matches!(process_image(pid).as_deref(), Some("powershell.exe" | "pwsh.exe")) {
                    kill(pid);
                }
            }
        }
        let _ = std::fs::remove_file(sp("timer.pid"));
        let _ = std::fs::remove_file(sp("timer_ready.flag"));
    }

    fn start_timer(session_id: &str) {
        // At most once a minute: a widget that dies on start (a broken
        // install, a GPU driver WPF dislikes) must not turn the loop into a
        // PowerShell launch every heartbeat.
        static LAST: Mutex<Option<Instant>> = Mutex::new(None);
        {
            let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
            if last.map(|t| t.elapsed() < Duration::from_secs(60)).unwrap_or(false) {
                return;
            }
            *last = Some(Instant::now());
        }
        stop_timer();
        let mut args = vec![];
        if !session_id.is_empty() {
            args.extend(["-SessionId", session_id]);
        }
        match powershell("logbook_timer.ps1", &args, true) {
            Ok(child) => {
                let _ = std::fs::write(sp("timer.pid"), child.id().to_string());
                info(&format!("Agent started the session timer (sid={session_id})."));
            }
            Err(e) => log(&format!("Timer start failed: {e}")),
        }
    }

    fn start_popup(force_new: bool) {
        if popup_running() && !force_new {
            return;
        }
        let args: &[&str] = if force_new { &["-ForceNew"] } else { &[] };
        if let Err(e) = powershell("logbook_popup.ps1", args, true) {
            log(&format!("Popup start failed: {e}"));
        }
    }

    /// One session open/close at a time, whichever thread asks.
    static SESSION_LOCK: Mutex<()> = Mutex::new(());

    /// Close-ActiveLogbookSession, natively: write the closing event, remove
    /// session.json, stop the timer. `end_at` back-dates the close (boot time
    /// for a stale session, start + cap for an over-age one).
    fn close_session(reason: &str, end_at: Option<chrono::DateTime<chrono::Local>>) -> bool {
        let _guard = SESSION_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let cfg = Config::load();
        if cfg.get("LOGIX_USE_WSL") == "1" {
            // The WSL bridge is the PowerShell side's; hand it the whole close.
            let mut args = vec!["-Reason", reason];
            let iso;
            if let Some(t) = end_at {
                iso = t.to_rfc3339();
                args.extend(["-EndTime", iso.as_str()]);
            }
            return powershell("logbook_end.ps1", &args, false).and_then(|mut c| c.wait()).is_ok();
        }
        let _ = std::fs::write(sp("session_ending.flag"), now_iso());
        let mut ok = true;
        if let Some(sess) = session() {
            let mut ts = end_at;
            if let (Some(t), Some(start)) = (ts, parse_time(&s(&sess, "start_time"))) {
                if t < start {
                    log(&format!("Close end time {} precedes start for sid={}; clamping to start.", t.to_rfc3339(), s(&sess, "session_id")));
                    ts = Some(start);
                }
            }
            let user = std::env::var("USERNAME").unwrap_or_default();
            let domain = std::env::var("USERDOMAIN").unwrap_or_default();
            let mut data = Map::new();
            let put = |m: &mut Map<String, Value>, k: &str, v: String| {
                m.insert(k.into(), Value::String(v));
            };
            put(&mut data, "timestamp", ts.map(|t| crate::util::iso_o(&t)).unwrap_or_else(now_iso));
            put(&mut data, "event", reason.to_string());
            put(&mut data, "username", user.clone());
            put(&mut data, "windows_user", format!("{domain}\\{user}"));
            put(&mut data, "hostname", crate::host_name());
            put(&mut data, "session_type", s(&sess, "session_type"));
            put(&mut data, "source", "windows_wpf".into());
            put(&mut data, "session_id", s(&sess, "session_id"));
            for k in ["nama", "nim", "tujuan", "keterangan", "job_type", "job_id"] {
                put(&mut data, k, s(&sess, k));
            }
            data.insert("anydesk_detected".into(), Value::from(crate::util::truthy(&s(&sess, "anydesk_detected"))));
            put(&mut data, "identity_source", s(&sess, "identity_source"));
            put(&mut data, "person_role", s(&sess, "person_role"));
            let payload = crate::payload_from_data(&data, &Map::new(), reason);
            match crate::record_event(&cfg, &cfg.default_db(), &payload) {
                Ok(id) => info(&format!("Closed active session sid={} reason={reason} (row {id}).", s(&sess, "session_id"))),
                Err(e) => {
                    log(&format!("Close of sid={} failed to record: {e}", s(&sess, "session_id")));
                    ok = false;
                }
            }
            if std::fs::remove_file(sp("session.json")).is_err() && sp("session.json").exists() {
                log("Could NOT remove session.json -- run windows\\repair_logbook_permissions.ps1 as admin.");
                ok = false;
            }
        }
        stop_timer();
        let _ = std::fs::remove_file(sp("session_ending.flag"));
        ok
    }

    fn max_session_secs(cfg: &Config) -> i64 {
        match cfg.get("LOGIX_MAX_SESSION_HOURS").trim().parse::<f64>() {
            Ok(h) if h > 0.0 => (h * 3600.0) as i64,
            _ => 8 * 3600,
        }
    }

    /// A session.json older than the last boot is a machine that went down
    /// mid-session: close it AT the boot, not hours later at discovery.
    fn close_stale_if_any() -> bool {
        let Some(sess) = session() else { return false };
        let Some(start) = parse_time(&s(&sess, "start_time")) else { return false };
        let boot = boot_time();
        if boot > start {
            info(&format!("Stale session sid={} started before boot; auto-closing at boot time.", s(&sess, "session_id")));
            return close_session("AUTO_CLOSE", Some(boot));
        }
        false
    }

    fn close_overage_if_any(cfg: &Config) -> bool {
        let Some(sess) = session() else { return false };
        let Some(start) = parse_time(&s(&sess, "start_time")) else { return false };
        let max = max_session_secs(cfg);
        let age = (chrono::Local::now() - start).num_seconds();
        if max > 0 && age >= max {
            info(&format!("Session age {age}s exceeds cap {max}s; auto-closing."));
            return close_session("AUTO_CLOSE", Some(start + chrono::Duration::seconds(max)));
        }
        false
    }

    /// devices.idle_auto_end.<category> from the cached server config, then
    /// LOGIX_IDLE_TIMEOUT_HOURS, then 4 h. 0 = policy off, never close.
    fn idle_limit_secs(cfg: &Config) -> i64 {
        if let Some(c) = read_json(&sp("server_config_cache.json")) {
            let devices = c.get("devices");
            let category = devices.and_then(|d| d.get("category")).and_then(|v| v.as_str()).filter(|s| !s.is_empty()).unwrap_or("custom");
            if let Some(p) = devices.and_then(|d| d.get("idle_auto_end")).and_then(|m| m.get(category)) {
                if !p.get("enabled").and_then(|v| v.as_bool()).unwrap_or(false) {
                    return 0;
                }
                let hours = p.get("hours").and_then(|v| v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok())));
                if let Some(h) = hours.filter(|h| *h > 0.0) {
                    return (h * 3600.0) as i64;
                }
            }
        }
        match cfg.get("LOGIX_IDLE_TIMEOUT_HOURS").trim().parse::<f64>() {
            Ok(h) if h > 0.0 => (h * 3600.0) as i64,
            _ => 4 * 3600,
        }
    }

    // ---- Task Manager gate watchdog ------------------------------------

    /// The popup disables Task Manager while it covers the screen and records
    /// the previous value. If the popup died without restoring it, restore it
    /// here -- otherwise one crash leaves Task Manager off for good.
    fn restore_task_manager_if_stale() {
        let marker = sp("taskmgr_prev_value.txt");
        if !marker.exists() || popup_running() {
            return;
        }
        let prev = std::fs::read_to_string(&marker).unwrap_or_default();
        let prev = prev.trim().trim_start_matches('\u{feff}').to_string();
        let path = wide(r"Software\Microsoft\Windows\CurrentVersion\Policies\System");
        let name = wide("DisableTaskMgr");
        unsafe {
            let mut key: HKEY = std::ptr::null_mut();
            if RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, KEY_QUERY_VALUE | KEY_SET_VALUE, &mut key) != 0 {
                return;
            }
            match prev.parse::<u32>() {
                Ok(v) => {
                    let bytes = v.to_le_bytes();
                    RegSetValueExW(key, name.as_ptr(), 0, REG_DWORD, bytes.as_ptr(), 4);
                }
                Err(_) => {
                    RegDeleteValueW(key, name.as_ptr());
                }
            }
            RegCloseKey(key);
        }
        let _ = std::fs::remove_file(&marker);
        info("Task Manager gate restored by the agent watchdog (popup was gone).");
    }

    // ---- inbox, acks, replies --------------------------------------------

    fn inbox_message(text: &str, reason: &str, command_id: &str, allow_reply: bool) {
        let dir = sp("inbox");
        let _ = std::fs::create_dir_all(&dir);
        let now = chrono::Local::now();
        let name = format!("{}_{}", now.format("%Y%m%d%H%M%S%3f"), &crate::util::uuid4_hex()[..8]);
        let body = json!({
            "text": text, "reason": reason, "command_id": command_id,
            "allow_reply": allow_reply, "received_at": crate::util::iso_o(&now),
        });
        let _ = write_atomic(&dir.join(format!("{name}.json")), body.to_string().as_bytes());
        // Keep the newest 50, like Set-LogbookIncomingMessage.
        if let Ok(rd) = std::fs::read_dir(&dir) {
            let mut files: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.extension().map(|x| x == "json").unwrap_or(false)).collect();
            files.sort();
            if files.len() > 50 {
                for f in &files[..files.len() - 50] {
                    let _ = std::fs::remove_file(f);
                }
            }
        }
    }

    /// A JSON array file, accepting the {"value": [...], "Count": n} wrapper
    /// that Windows PowerShell 5.1 wrote before the -InputObject fix.
    fn read_list(path: &Path) -> Vec<Value> {
        match read_json(path) {
            Some(Value::Array(a)) => a,
            Some(Value::Object(o)) if o.contains_key("value") && o.contains_key("Count") && !o.contains_key("text") => {
                o.get("value").and_then(|v| v.as_array().cloned()).unwrap_or_default()
            }
            Some(v @ Value::Object(_)) => vec![v],
            Some(Value::String(s)) => vec![Value::String(s)],
            _ => vec![],
        }
    }

    fn write_list(path: &Path, items: &[Value]) {
        if items.is_empty() {
            let _ = std::fs::remove_file(path);
        } else {
            let _ = write_atomic(path, Value::Array(items.to_vec()).to_string().as_bytes());
        }
    }

    fn executed_ids() -> Vec<String> {
        read_list(&sp("executed_commands.json")).iter().filter_map(|v| v.as_str().map(String::from)).collect()
    }

    fn add_executed(id: &str) {
        let mut ids: Vec<Value> = executed_ids().into_iter().map(Value::String).collect();
        ids.push(Value::String(id.to_string()));
        if ids.len() > 200 {
            ids.drain(..ids.len() - 200);
        }
        write_list(&sp("executed_commands.json"), &ids);
    }

    fn flush_pending_replies(agent: &ureq::Agent, cfg: &Config, base: &str) {
        let path = sp("pending_replies.json");
        let queued = read_list(&path);
        if queued.is_empty() {
            return;
        }
        let mut remaining = Vec::new();
        let mut sent = 0;
        for item in queued {
            if !remaining.is_empty() {
                remaining.push(item);
                continue;
            }
            let body = json!({
                "hostname": crate::host_name(), "device_name": device_name(cfg),
                "message": item.get("text").and_then(|v| v.as_str()).unwrap_or(""),
                "command_id": item.get("command_id").and_then(|v| v.as_str()).unwrap_or(""),
            });
            match post_json(agent, &format!("{base}/api/replies"), &cfg.api_key(), &body.to_string()) {
                Outcome::Status(200..=299, _) => sent += 1,
                _ => remaining.push(item),
            }
        }
        write_list(&path, &remaining);
        if sent > 0 {
            info(&format!("Flushed {sent} queued repl{} to the server.", if sent == 1 { "y" } else { "ies" }));
        }
    }

    // ---- heartbeat ---------------------------------------------------------

    fn device_name(cfg: &Config) -> String {
        let n = cfg.get("LOGIX_DEVICE_NAME");
        if n.trim().is_empty() { crate::host_name() } else { n.trim().to_string() }
    }

    fn agent_version() -> String {
        static V: OnceLock<String> = OnceLock::new();
        V.get_or_init(|| {
            let dir = install_dir();
            for d in [Some(dir.clone()), dir.parent().map(Path::to_path_buf)].into_iter().flatten() {
                if let Ok(v) = std::fs::read_to_string(d.join("VERSION")) {
                    let v = v.trim().trim_start_matches('\u{feff}').to_string();
                    if !v.is_empty() {
                        return v;
                    }
                }
            }
            env!("CARGO_PKG_VERSION").to_string()
        })
        .clone()
    }

    /// Get-AnyDeskId, but cached: the old monitor read the config files --
    /// and, without them, launched AnyDesk.exe --get-id -- on every heartbeat.
    fn anydesk_id() -> String {
        static CACHE: Mutex<Option<(Instant, String)>> = Mutex::new(None);
        let mut c = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, id)) = c.as_ref() {
            if at.elapsed() < Duration::from_secs(600) {
                return id.clone();
            }
        }
        let mut found = String::new();
        let confs = [
            std::env::var("PROGRAMDATA").ok().map(|p| PathBuf::from(p).join(r"AnyDesk\system.conf")),
            std::env::var("APPDATA").ok().map(|p| PathBuf::from(p).join(r"AnyDesk\system.conf")),
        ];
        'outer: for p in confs.into_iter().flatten() {
            if let Ok(text) = std::fs::read_to_string(&p) {
                for line in text.lines() {
                    if let Some(rest) = line.trim().strip_prefix("ad.anydesk.id=") {
                        let id: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
                        if !id.is_empty() {
                            found = id;
                            break 'outer;
                        }
                    }
                }
            }
        }
        if found.is_empty() {
            let exes = [
                std::env::var("ProgramFiles").ok().map(|p| PathBuf::from(p).join(r"AnyDesk\AnyDesk.exe")),
                std::env::var("ProgramFiles(x86)").ok().map(|p| PathBuf::from(p).join(r"AnyDesk\AnyDesk.exe")),
            ];
            for exe in exes.into_iter().flatten().filter(|p| p.exists()) {
                if let Ok(out) = Command::new(&exe).arg("--get-id").creation_flags(CREATE_NO_WINDOW).output() {
                    let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    if !id.is_empty() && id.chars().all(|c| c.is_ascii_digit()) {
                        found = id;
                        break;
                    }
                }
            }
        }
        *c = Some((Instant::now(), found.clone()));
        found
    }

    fn pulse() {
        static EV: OnceLock<usize> = OnceLock::new();
        let h = *EV.get_or_init(|| {
            let name = wide("Local\\LogixHeartbeatPulse");
            unsafe { CreateEventW(std::ptr::null(), 0, 0, name.as_ptr()) as usize }
        });
        if h != 0 {
            unsafe { SetEvent(h as HANDLE) };
        }
    }

    fn heartbeat(cfg: &Config) {
        let base = cfg.server_url().trim_end_matches('/').to_string();
        if base.is_empty() {
            return;
        }
        let sess = session();
        let mut username = std::env::var("USERNAME").unwrap_or_default();
        let mut payload = Map::new();
        if let Some(sess) = &sess {
            let (n, u) = (s(sess, "nama"), s(sess, "username"));
            if !n.is_empty() { username = n } else if !u.is_empty() { username = u }
            for (from, to) in [("start_time", "session_started_at"), ("session_type", "access_type"), ("tujuan", "purpose")] {
                let v = s(sess, from);
                if !v.is_empty() {
                    payload.insert(to.into(), Value::String(v));
                }
            }
        }
        let status = if sess.is_some() { "ACTIVE" } else { "LOCKED" };
        let acks_path = sp("pending_acks.json");
        let acks = read_list(&acks_path);
        payload.insert("hostname".into(), Value::String(crate::host_name()));
        payload.insert("device_name".into(), Value::String(device_name(cfg)));
        payload.insert("status".into(), Value::String(status.into()));
        payload.insert("username".into(), Value::String(username));
        payload.insert("anydesk_id".into(), Value::String(anydesk_id()));
        if !acks.is_empty() {
            payload.insert("acks".into(), Value::Array(acks.clone()));
        }
        payload.insert("agent_version".into(), Value::String(agent_version()));
        payload.insert("agent_os".into(), Value::String("windows".into()));
        let mode = cfg.privacy_mode().unwrap_or_else(|_| "local_only".into());
        payload.insert("privacy_mode".into(), Value::String(mode));
        payload.insert("client_time".into(), Value::String(crate::util::iso_o(&chrono::Local::now())));

        let agent = http_agent(3);
        let body = match post_json(&agent, &format!("{base}/api/heartbeat"), &cfg.api_key(), &Value::Object(payload).to_string()) {
            Outcome::Status(200..=299, body) => body,
            Outcome::Status(code, _) => {
                log(&format!("Heartbeat refused: HTTP {code}"));
                return;
            }
            Outcome::Failed(_, _) => return, // offline: the next round retries
        };
        pulse();
        if !acks.is_empty() {
            let _ = std::fs::remove_file(&acks_path);
        }
        flush_pending_replies(&agent, cfg, &base);

        let commands = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|v| v.get("commands").and_then(|c| c.as_array().cloned()))
            .unwrap_or_default();
        if commands.is_empty() {
            return;
        }
        let mut done = executed_ids();
        let mut new_acks = Vec::new();
        for cmd in commands {
            let id = cmd.get("command_id").map(|v| crate::util::norm(Some(v), "")).unwrap_or_default();
            if !id.is_empty() && done.contains(&id) {
                info(&format!("Skipping redelivered command {id} (already executed)."));
                continue;
            }
            // Recorded BEFORE running: LOGOFF/SHUTDOWN can take this process
            // down, and an unrecorded LOGOFF would replay into the next sign-in.
            if !id.is_empty() {
                add_executed(&id);
                done.push(id.clone());
            }
            let name = cmd.get("command").and_then(|v| v.as_str()).unwrap_or("").to_uppercase();
            let param = cmd.get("param").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let reason = cmd.get("reason").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).unwrap_or("Direction Message").to_string();
            info(&format!("Received remote command: {name}"));
            let (status, detail) = match execute(&name, &param, &reason, &id) {
                Ok(d) => ("done", d),
                Err(e) => ("failed", e),
            };
            new_acks.push(json!({ "command_id": cmd.get("command_id").cloned().unwrap_or(Value::Null), "status": status, "detail": detail }));
        }
        if !new_acks.is_empty() {
            // Append: an earlier round's acks may still be waiting to go out.
            let mut all = read_list(&acks_path);
            all.extend(new_acks);
            write_list(&acks_path, &all);
        }
    }

    fn shutdown_exe(args: &[&str]) -> Result<(), String> {
        let st = Command::new("shutdown.exe").args(args).creation_flags(CREATE_NO_WINDOW).status().map_err(|e| e.to_string())?;
        if st.success() { Ok(()) } else { Err(format!("shutdown.exe exited {}", st.code().unwrap_or(-1))) }
    }

    fn execute(name: &str, param: &str, reason: &str, id: &str) -> Result<String, String> {
        match name {
            "LOCK" => {
                close_session("LOCK", None);
                start_popup(true);
                Ok(String::new())
            }
            "BROADCAST" => {
                inbox_message(param, reason, id, true);
                Ok("delivered to device inbox".into())
            }
            "SCREENSHOT" => {
                // Transparency first: the person at the device always sees it.
                inbox_message("Admin baru saja mengambil tangkapan layar perangkat ini untuk keperluan pemantauan.", "Screen View Notice", "", false);
                let result = sp("screenshot_result.json");
                let _ = std::fs::remove_file(&result);
                let mut child = powershell("logbook_screenshot.ps1", &["-CommandId", id], true).map_err(|e| e.to_string())?;
                let deadline = Instant::now() + Duration::from_secs(60);
                loop {
                    if let Ok(Some(_)) = child.try_wait() { break; }
                    if Instant::now() > deadline {
                        let _ = child.kill();
                        return Err("screenshot helper timed out".into());
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
                let r = read_json(&result).ok_or("screenshot helper produced no result (it may have been blocked from starting)")?;
                if r.get("command_id").map(|v| crate::util::norm(Some(v), "")) != Some(id.to_string()) {
                    return Err("screenshot helper wrote a result for a different command".into());
                }
                if r.get("ok").and_then(|v| v.as_bool()) != Some(true) {
                    return Err(format!("screenshot capture failed: {}", r.get("error").and_then(|v| v.as_str()).unwrap_or("")));
                }
                Ok("screenshot uploaded".into())
            }
            "SHUTDOWN" => {
                inbox_message("Perangkat ini akan dimatikan oleh admin dalam 30 detik. Simpan pekerjaan Anda sekarang.", "Emergency Alert", "", false);
                shutdown_exe(&["/s", "/t", "30", "/c", "Logix: perangkat dimatikan oleh admin. Simpan pekerjaan Anda."])?;
                Ok("shutdown scheduled (30s)".into())
            }
            "RESTART" => {
                inbox_message("Perangkat ini akan dimulai ulang oleh admin dalam 30 detik. Simpan pekerjaan Anda sekarang.", "Emergency Alert", "", false);
                shutdown_exe(&["/r", "/t", "30", "/c", "Logix: perangkat dimulai ulang oleh admin. Simpan pekerjaan Anda."])?;
                Ok("restart scheduled (30s)".into())
            }
            "LOGOFF" => {
                close_session("END", None);
                shutdown_exe(&["/l", "/f"])?;
                Ok("user logged off".into())
            }
            other => {
                log(&format!("Unknown remote command: {other}"));
                Err(format!("unknown command {other}"))
            }
        }
    }

    /// GET /api/config into server_config_cache.json -- the file the popup and
    /// the widget already read. Every 5 minutes, not on every loop: the old
    /// idle check fetched it every heartbeat.
    fn refresh_server_config(cfg: &Config) {
        let base = cfg.server_url().trim_end_matches('/').to_string();
        if base.is_empty() {
            return;
        }
        let agent = http_agent(3);
        if let Ok(mut resp) = agent.get(&format!("{base}/api/config")).header("X-API-Key", &cfg.api_key()).call() {
            if resp.status().as_u16() == 200 {
                if let Ok(text) = resp.body_mut().read_to_string() {
                    if serde_json::from_str::<Value>(&text).is_ok() {
                        let _ = write_atomic(&sp("server_config_cache.json"), text.as_bytes());
                    }
                }
            }
        }
    }

    fn sync_retry(cfg: &Config) {
        if cfg.server_url().is_empty() || cfg.privacy_mode().map(|m| m != "admin_full_sync").unwrap_or(true) {
            return;
        }
        let db_path = cfg.default_db();
        if !db_path.exists() {
            return;
        }
        if let Ok(con) = crate::db::connect(&db_path) {
            if crate::db::migrate(&con).is_ok() && crate::db::pending_count(&con) > 0 {
                let _ = crate::sync::sync_unsynced(&con, &db_path, cfg, 10, 1);
            }
        }
    }

    // ---- session / power events ------------------------------------------

    enum Ev {
        Ended,
        Locked,
        Unlocked,
        Suspend,
        Resume,
        ShuttingDown(mpsc::Sender<()>),
    }

    static EVENTS: OnceLock<Mutex<mpsc::Sender<Ev>>> = OnceLock::new();

    fn emit(ev: Ev) {
        if let Some(tx) = EVENTS.get() {
            let _ = tx.lock().unwrap_or_else(|e| e.into_inner()).send(ev);
        }
    }

    unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        match msg {
            WM_WTSSESSION_CHANGE => {
                match wp as u32 {
                    WTS_CONSOLE_DISCONNECT | WTS_REMOTE_DISCONNECT | WTS_SESSION_LOGOFF => emit(Ev::Ended),
                    WTS_SESSION_LOCK => emit(Ev::Locked),
                    WTS_SESSION_UNLOCK | WTS_CONSOLE_CONNECT | WTS_REMOTE_CONNECT | WTS_SESSION_LOGON => emit(Ev::Unlocked),
                    _ => {}
                }
                0
            }
            WM_POWERBROADCAST => {
                match wp as u32 {
                    PBT_APMSUSPEND => emit(Ev::Suspend),
                    PBT_APMRESUMESUSPEND | PBT_APMRESUMEAUTOMATIC => emit(Ev::Resume),
                    _ => {}
                }
                1
            }
            WM_QUERYENDSESSION => {
                // Windows gives us a few seconds here. Close the session NOW,
                // natively, and only then let the shutdown proceed.
                let (tx, rx) = mpsc::channel();
                emit(Ev::ShuttingDown(tx));
                let _ = rx.recv_timeout(Duration::from_secs(4));
                1
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }

    fn handle_events(rx: mpsc::Receiver<Ev>) {
        let mut ended_once = false;
        for ev in rx {
            match ev {
                Ev::Ended => {
                    let _ = std::fs::remove_file(sp("workstation_locked.flag"));
                    info("SessionSwitch: logoff/disconnect -- closing session.");
                    close_session("END", None);
                }
                Ev::Locked | Ev::Suspend => {
                    let _ = std::fs::write(sp("workstation_locked.flag"), "");
                }
                Ev::Unlocked | Ev::Resume => {
                    let _ = std::fs::remove_file(sp("workstation_locked.flag"));
                    if popup_running() {
                        info("Unlock: a sign-in popup is already open.");
                    } else {
                        start_popup(false);
                    }
                }
                Ev::ShuttingDown(done) => {
                    if !ended_once {
                        ended_once = true;
                        info("SessionEnding -- closing session before Windows goes down.");
                        close_session("END", None);
                    }
                    let _ = done.send(());
                }
            }
        }
    }

    fn message_loop() {
        unsafe {
            let class = wide("LogixAgentWindow");
            let hinst = windows_sys::Win32::System::LibraryLoader::GetModuleHandleW(std::ptr::null());
            let wc = WNDCLASSW {
                style: 0,
                lpfnWndProc: Some(wndproc),
                cbClsExtra: 0,
                cbWndExtra: 0,
                hInstance: hinst,
                hIcon: std::ptr::null_mut(),
                hCursor: std::ptr::null_mut(),
                hbrBackground: std::ptr::null_mut(),
                lpszMenuName: std::ptr::null(),
                lpszClassName: class.as_ptr(),
            };
            RegisterClassW(&wc);
            // A real (never shown) top-level window, not a message-only one:
            // shutdown and power broadcasts only reach top-level windows.
            let title = wide("Logix Agent");
            let hwnd = CreateWindowExW(0, class.as_ptr(), title.as_ptr(), 0, 0, 0, 0, 0,
                std::ptr::null_mut(), std::ptr::null_mut(), hinst, std::ptr::null());
            if hwnd.is_null() {
                log("Agent could not create its event window; lock/unlock events will be missed.");
                return;
            }
            if WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION) == 0 {
                log("WTSRegisterSessionNotification failed; lock/unlock events will be missed.");
            }
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }

    // ---- main loop -----------------------------------------------------------

    fn initial_popup_or_timer() {
        let cfg = Config::load();
        if close_stale_if_any() || close_overage_if_any(&cfg) {
            start_popup(false);
            return;
        }
        match session() {
            Some(sess) => {
                let sid = s(&sess, "session_id");
                if !sid.is_empty() && !timer_running() {
                    start_timer(&sid);
                }
            }
            None => start_popup(false),
        }
    }

    fn tick(last_sync: &mut Option<Instant>, last_cfg: &mut Option<Instant>) {
        let cfg = Config::load();
        if last_cfg.map(|t| t.elapsed() >= Duration::from_secs(300)).unwrap_or(true) {
            refresh_server_config(&cfg);
            *last_cfg = Some(Instant::now());
        }
        heartbeat(&cfg);
        if let Some(sess) = session() {
            if !timer_running() && !sp("session_ending.flag").exists() {
                start_timer(&s(&sess, "session_id"));
            }
        }
        let retry = match cfg.get("LOGIX_SYNC_RETRY_SECONDS").trim().parse::<u64>() {
            Ok(v) if v >= 30 => v,
            _ => 120,
        };
        if last_sync.map(|t| t.elapsed() >= Duration::from_secs(retry)).unwrap_or(true) {
            sync_retry(&cfg);
            *last_sync = Some(Instant::now());
        }
        close_overage_if_any(&cfg);
        if session().is_some() && !sp("workstation_locked.flag").exists() {
            let limit = idle_limit_secs(&cfg);
            if let Some(idle) = idle_seconds() {
                if limit > 0 && idle >= limit as f64 {
                    info(&format!("Idle timeout reached ({idle:.0}s >= {limit}s); auto-closing session."));
                    close_session("AUTO_CLOSE", None);
                }
            }
        }
        restore_task_manager_if_stale();
    }

    pub fn run(args: &[String]) -> i32 {
        let _ = std::fs::create_dir_all(state_dir());
        if args.iter().any(|a| a == "--once") {
            initial_popup_or_timer();
            return 0;
        }
        // Same mutex name as logbook_monitor.ps1: never both, never two.
        let name = wide("Global\\LogixAgentMonitor");
        let mutex = unsafe { CreateMutexW(std::ptr::null(), 1, name.as_ptr()) };
        if mutex.is_null() || unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
            info("Agent: monitor already running; exiting duplicate instance.");
            return 0;
        }
        let _ = std::fs::remove_file(sp("workstation_locked.flag"));
        info(&format!("Agent started (native, v{}). User={} PID={}", agent_version(), std::env::var("USERNAME").unwrap_or_default(), std::process::id()));

        let (tx, rx) = mpsc::channel();
        let _ = EVENTS.set(Mutex::new(tx));
        std::thread::spawn(move || handle_events(rx));
        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(2));
            initial_popup_or_timer();
            let mut last_sync = None;
            let mut last_cfg = None;
            loop {
                tick(&mut last_sync, &mut last_cfg);
                let secs = match Config::load().get("LOGIX_HEARTBEAT_SECONDS").trim().parse::<u64>() {
                    Ok(v) if v >= 2 => v,
                    _ => 5,
                };
                std::thread::sleep(Duration::from_secs(secs));
            }
        });
        message_loop();
        0
    }
}
