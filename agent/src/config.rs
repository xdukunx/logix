//! Setting resolution, the twin of logix/paths.py and the PowerShell
//! Get-LogbookConfigEnv: environment variable, then config.env, then the
//! system default. Read fresh on every call that matters (the resident agent
//! must notice a pairing or a privacy-mode change without a restart), but
//! cheap: config.env is a handful of lines.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub fn system_data_home() -> PathBuf {
    if cfg!(windows) {
        let base = std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into());
        PathBuf::from(base).join("Logix")
    } else if cfg!(target_os = "macos") {
        PathBuf::from("/Library/Application Support/Logix")
    } else {
        PathBuf::from("/opt/software/logix")
    }
}

fn env_nonempty(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

/// Where config.env lives. LOGIX_CONFIG, then LOGIX_HOME (from the
/// environment only -- reading it from config.env would be circular), then
/// the system data home, then next to this executable.
pub fn config_path() -> Option<PathBuf> {
    if let Some(p) = env_nonempty("LOGIX_CONFIG") {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }
    let mut cands = Vec::new();
    if let Some(h) = env_nonempty("LOGIX_HOME") {
        cands.push(PathBuf::from(h).join("config.env"));
    }
    cands.push(system_data_home().join("config.env"));
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            cands.push(dir.join("config.env"));
        }
    }
    cands.into_iter().find(|p| p.is_file())
}

/// Parse a config.env. utf-8 with or without BOM (PowerShell writes one), and
/// `export KEY=VALUE` lines, and quoted values -- same rules as paths.py.
pub fn parse_env_file(path: &Path) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Ok(text) = std::fs::read_to_string(path) else { return out };
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
    for raw in text.lines() {
        let mut line = raw.trim();
        if line.is_empty() || line.starts_with('#') || !line.contains('=') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("export ") {
            line = rest;
        }
        let (k, v) = line.split_once('=').unwrap();
        let key = k.trim();
        let val = v.trim().trim_matches('"').trim_matches('\'');
        if !key.is_empty() {
            out.insert(key.to_string(), val.to_string());
        }
    }
    out
}

/// A snapshot of every setting source, taken once per decision.
pub struct Config {
    file: HashMap<String, String>,
}

impl Config {
    pub fn load() -> Self {
        let file = config_path().map(|p| parse_env_file(&p)).unwrap_or_default();
        Config { file }
    }

    pub fn get(&self, name: &str) -> String {
        if let Some(v) = env_nonempty(name) {
            return v;
        }
        self.file.get(name).cloned().unwrap_or_default()
    }

    pub fn data_home(&self) -> PathBuf {
        let v = self.get("LOGIX_HOME");
        if v.is_empty() { system_data_home() } else { PathBuf::from(v) }
    }

    pub fn default_db(&self) -> PathBuf {
        let v = self.get("LOGIX_DB");
        if v.is_empty() { self.data_home().join("logix.db") } else { PathBuf::from(v) }
    }

    pub fn session_json(&self) -> PathBuf {
        let v = self.get("LOGBOOK_SESSION_JSON");
        if !v.is_empty() {
            return PathBuf::from(v);
        }
        if cfg!(windows) {
            system_data_home().join("session.json")
        } else {
            PathBuf::from("/mnt/c/ProgramData/Logix/session.json")
        }
    }

    pub fn server_url(&self) -> String {
        self.get("LOGIX_SERVER_URL").trim().to_string()
    }

    pub fn server_api_key(&self) -> String {
        self.get("LOGIX_SERVER_API_KEY")
    }

    /// docs/PRIVACY.md: local_only unless explicitly set. An unknown value is
    /// an error, never silently coerced -- a typo must not pick a mode.
    pub fn privacy_mode(&self) -> Result<String, String> {
        let raw = self.get("LOGIX_PRIVACY_MODE");
        let mode = if raw.trim().is_empty() { "local_only".to_string() } else { raw.trim().to_lowercase() };
        match mode.as_str() {
            "local_only" | "redacted_sync" | "admin_full_sync" => Ok(mode),
            other => Err(format!(
                "LOGIX_PRIVACY_MODE: unrecognized value '{other}', expected one of ['admin_full_sync', 'local_only', 'redacted_sync']"
            )),
        }
    }

    pub fn device_identity_path(&self) -> PathBuf {
        let v = self.get("LOGIX_DEVICE_IDENTITY_FILE");
        if v.is_empty() { self.data_home().join("device.json") } else { PathBuf::from(v) }
    }

    fn device_identity(&self) -> serde_json::Value {
        read_json(&self.device_identity_path()).unwrap_or(serde_json::Value::Null)
    }

    /// Per-device key first, the shared bootstrap key as the fallback --
    /// the server's own verify_api_key order.
    pub fn api_key(&self) -> String {
        let id = self.device_identity();
        match id.get("api_key").and_then(|v| v.as_str()) {
            Some(k) if !k.is_empty() => k.to_string(),
            _ => self.server_api_key(),
        }
    }
}

/// JSON from a file written by PowerShell (BOM or not).
pub fn read_json(path: &Path) -> Option<serde_json::Value> {
    let text = std::fs::read_to_string(path).ok()?;
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
    serde_json::from_str(text).ok()
}
