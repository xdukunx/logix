//! Delivery of local rows to the server (/api/log), and the sync status a UI
//! reads. Behaviour mirrors log_physical.sync_unsynced_logs / sync_status:
//! only admin_full_sync ever sends; 5xx and network failures retry with
//! backoff, 4xx fails fast; the outcome is written to sync_state.json beside
//! the database with the same keys and failure classes.

use crate::config::Config;
use crate::db;
use crate::util::{now_iso, py_dumps, write_atomic};
use rusqlite::Connection;
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub fn http_agent(timeout_secs: u64) -> ureq::Agent {
    use ureq::tls::{RootCerts, TlsConfig, TlsProvider};
    let tls = TlsConfig::builder()
        .provider(TlsProvider::NativeTls)
        .root_certs(RootCerts::PlatformVerifier)
        .build();
    let cfg = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(timeout_secs)))
        .http_status_as_error(false)
        .tls_config(tls)
        .build();
    cfg.into()
}

pub enum Outcome {
    Status(u16, String),
    Failed(&'static str, String),
}

/// One request. A status code means the server answered; anything else is a
/// reachability failure ("network") unless it is plainly our own fault.
pub fn post_json(agent: &ureq::Agent, url: &str, key: &str, body: &str) -> Outcome {
    let req = agent
        .post(url)
        .header("Content-Type", "application/json")
        .header("X-API-Key", key);
    match req.send(body) {
        Ok(mut resp) => {
            let code = resp.status().as_u16();
            let text = resp.body_mut().read_to_string().unwrap_or_default();
            Outcome::Status(code, text)
        }
        Err(e) => {
            let class = match e {
                ureq::Error::BadUri(_) | ureq::Error::InvalidProxyUrl => "unknown",
                _ => "network",
            };
            Outcome::Failed(class, e.to_string())
        }
    }
}

fn classify_http(code: u16) -> &'static str {
    match code {
        401 | 403 => "auth",
        400..=499 => "rejected",
        _ => "server",
    }
}

fn state_path(db_path: &Path) -> PathBuf {
    db_path.parent().map(|d| d.join("sync_state.json")).unwrap_or_else(|| PathBuf::from("sync_state.json"))
}

fn record_attempt(db_path: &Path, ok: bool, detail: &str, class: &str) {
    let path = state_path(db_path);
    let mut state = crate::config::read_json(&path)
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    let now = now_iso();
    state.insert("last_attempt".into(), Value::String(now.clone()));
    if ok {
        state.insert("last_success".into(), Value::String(now));
        state.insert("last_error".into(), Value::Null);
        state.insert("last_error_class".into(), Value::Null);
    } else {
        state.insert("last_error".into(), Value::String(detail.to_string()));
        state.insert("last_error_class".into(), Value::String(class.to_string()));
    }
    let _ = write_atomic(&path, py_dumps(&Value::Object(state), true).as_bytes());
}

/// POST every unsynced row. Returns how many were confirmed.
pub fn sync_unsynced(con: &Connection, db_path: &Path, cfg: &Config, timeout: u64, max_attempts: u32) -> Result<usize, String> {
    let url = cfg.server_url();
    if url.is_empty() {
        return Ok(0);
    }
    let mode = cfg.privacy_mode()?;
    if mode != "admin_full_sync" {
        eprintln!(
            "Sync skipped: LOGIX_PRIVACY_MODE='{mode}' (default local_only). No session data leaves this device unless privacy mode is explicitly set to admin_full_sync. See docs/PRIVACY.md."
        );
        return Ok(0);
    }
    let (ids, rows) = db::unsynced(con).map_err(|e| e.to_string())?;
    if ids.is_empty() {
        return Ok(0);
    }
    let body = py_dumps(&Value::Array(rows), true);
    let endpoint = format!("{}/api/log", url.trim_end_matches('/'));
    let key = cfg.api_key();
    let agent = http_agent(timeout);

    let mut backoff = 1u64;
    let mut last_error = String::from("unknown failure");
    let mut last_class = "unknown";
    let attempts = max_attempts.max(1);
    for attempt in 1..=attempts {
        match post_json(&agent, &endpoint, &key, &body) {
            Outcome::Status(200 | 201, _) => {
                db::mark_synced(con, &ids).map_err(|e| e.to_string())?;
                record_attempt(db_path, true, "", "");
                return Ok(ids.len());
            }
            Outcome::Status(code, text) if code >= 400 => {
                last_error = format!("HTTP {code}: {}", text.chars().take(200).collect::<String>());
                last_class = classify_http(code);
                if code >= 500 && attempt < attempts {
                    eprintln!("Sync to server failed (HTTP {code}, retrying)");
                    std::thread::sleep(Duration::from_secs(backoff));
                    backoff *= 2;
                    continue;
                }
                eprintln!("Sync to server failed (HTTP {code}, not retrying)");
                break;
            }
            Outcome::Status(code, _) => {
                last_error = format!("unexpected HTTP status {code}");
                last_class = "server";
                break;
            }
            Outcome::Failed(class, msg) => {
                last_error = msg.clone();
                last_class = class;
                eprintln!("Sync to server failed (attempt {attempt}/{attempts}): {msg}");
                if attempt < attempts {
                    std::thread::sleep(Duration::from_secs(backoff));
                    backoff *= 2;
                }
            }
        }
    }
    record_attempt(db_path, false, &last_error, last_class);
    Ok(0)
}

pub fn sync_status(con: &Connection, db_path: &Path, cfg: &Config) -> Result<Value, String> {
    let pending = db::pending_count(con);
    let url = cfg.server_url();
    let mode = cfg.privacy_mode()?;
    let state: Map<String, Value> = crate::config::read_json(&state_path(db_path))
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    let has = |k: &str| state.get(k).map(|v| !v.is_null() && v.as_str() != Some("")).unwrap_or(false);
    let connection_state = if url.is_empty() {
        "disabled"
    } else if mode != "admin_full_sync" {
        "blocked"
    } else if !has("last_attempt") {
        "pending"
    } else if has("last_error") {
        "offline"
    } else {
        "connected"
    };
    let get = |k: &str| state.get(k).cloned().unwrap_or(Value::Null);
    let err_class = if has("last_error") {
        match state.get("last_error_class").and_then(|v| v.as_str()) {
            Some(s) if !s.is_empty() => Value::String(s.into()),
            _ => Value::String("unknown".into()),
        }
    } else {
        Value::Null
    };
    Ok(json!({
        "connection_state": connection_state,
        "server_configured": !url.is_empty(),
        "privacy_mode": mode,
        "pending_count": pending,
        "last_attempt": get("last_attempt"),
        "last_success": get("last_success"),
        "last_error": get("last_error"),
        "last_error_class": err_class,
    }))
}

pub fn preview(con: &Connection, cfg: &Config) -> Result<(), String> {
    let mut st = con
        .prepare("SELECT id, timestamp, event, hostname, session_type FROM physical_log WHERE COALESCE(synced,0)=0 ORDER BY id ASC")
        .map_err(|e| e.to_string())?;
    let rows: Vec<(i64, String, String, String, String)> = st
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                r.get::<_, Option<String>>(4)?.unwrap_or_default(),
            ))
        })
        .map_err(|e| e.to_string())?
        .flatten()
        .collect();
    let mode = cfg.privacy_mode()?;
    if mode != "admin_full_sync" {
        println!(
            "{} unsynced event(s) exist, but none would actually be sent: LOGIX_PRIVACY_MODE='{mode}' (must be 'admin_full_sync' for /api/log). See docs/PRIVACY.md.",
            rows.len()
        );
        return Ok(());
    }
    let url = cfg.server_url();
    println!(
        "{} unsynced event(s) would be sent to {}:",
        rows.len(),
        if url.is_empty() { "(no server configured)".to_string() } else { url }
    );
    for (id, ts, ev, host, ty) in rows {
        println!("  #{id} {ts} {ev} host={host} type={ty}");
    }
    Ok(())
}
