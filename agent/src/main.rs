//! logix.exe -- the Windows workstation core in one small native binary.
//!
//!   logix.exe --json-file payload.json     record one session event (START/END/...)
//!   logix.exe --sync-to-server             deliver unsynced rows (3 attempts)
//!   logix.exe --sync-status | --sync-preview | --repair-active | --close-open | --migrate
//!   logix.exe agent                        the resident workstation agent
//!
//! The flags are log_physical.py's, unchanged, so every caller can switch
//! between the two cores without knowing which one answered. The point of
//! this one is cost: a session event here is a few milliseconds and a couple
//! of megabytes, where starting Python for it was ~120 ms and ~24 MB, on the
//! exact click a student is waiting on.

mod agent;
mod config;
mod db;
mod sync;
mod util;

use config::Config;
use serde_json::{Map, Value};
use std::path::PathBuf;
use util::{norm, now_iso, py_dumps, truthy, uuid4_hex};

pub fn host_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "localhost".into())
}

fn current_user() -> String {
    std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_default()
}

#[derive(Default)]
struct Args {
    db: Option<String>,
    flags: Vec<String>,
    fields: Map<String, Value>,
    json_file: String,
    event: String,
}

const FIELD_FLAGS: &[(&str, &str)] = &[
    ("--username", "username"),
    ("--nama", "nama"),
    ("--nim", "nim"),
    ("--tujuan", "tujuan"),
    ("--keterangan", "keterangan"),
    ("--job-type", "job_type"),
    ("--job-id", "job_id"),
    ("--session-type", "session_type"),
    ("--source", "source"),
    ("--session-id", "session_id"),
    ("--windows-user", "windows_user"),
    ("--hostname", "hostname"),
    ("--client-ip", "client_ip"),
    ("--anydesk-detected", "anydesk_detected"),
    ("--raw-json", "raw_json"),
];

fn parse(argv: &[String]) -> Result<Args, String> {
    let mut a = Args { event: "START".into(), ..Default::default() };
    let mut i = 0;
    while i < argv.len() {
        let arg = &argv[i];
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n.to_string(), Some(v.to_string())),
            _ => (arg.clone(), None),
        };
        let mut value = || -> Result<String, String> {
            if let Some(v) = &inline {
                return Ok(v.clone());
            }
            i += 1;
            argv.get(i).cloned().ok_or_else(|| format!("{name} needs a value"))
        };
        match name.as_str() {
            "--db" => a.db = Some(value()?),
            "--json-file" => a.json_file = value()?,
            "--event" => a.event = value()?,
            "--migrate" | "--repair-active" | "--close-open" | "--sync-to-server" | "--sync-preview" | "--sync-status" => {
                a.flags.push(name.clone())
            }
            "-h" | "--help" => a.flags.push("--help".into()),
            other => match FIELD_FLAGS.iter().find(|(f, _)| *f == other) {
                Some((_, key)) => {
                    let v = value()?;
                    a.fields.insert((*key).into(), Value::String(v));
                }
                None => return Err(format!("unrecognized argument: {other}")),
            },
        }
        i += 1;
    }
    Ok(a)
}

/// log_physical.payload_from_args: JSON file first, CLI flags as fallback.
fn build_payload(a: &Args) -> Result<Map<String, Value>, String> {
    let data: Map<String, Value> = if a.json_file.is_empty() {
        Map::new()
    } else {
        let p = PathBuf::from(&a.json_file);
        if !p.exists() {
            return Err(format!("json file not found: {}", p.display()));
        }
        config::read_json(&p)
            .and_then(|v| v.as_object().cloned())
            .ok_or_else(|| format!("invalid json file: {}", p.display()))?
    };
    Ok(payload_from_data(&data, &a.fields, &a.event))
}

/// The event row for `data` (a session-event JSON object), with `fields`
/// (CLI flags) and `event` as fallbacks. Shared by the CLI and the agent.
pub fn payload_from_data(data: &Map<String, Value>, fields: &Map<String, Value>, event: &str) -> Map<String, Value> {
    let flag = |k: &str| norm(fields.get(k), "");
    let pick = |k: &str, fallback: String| norm(data.get(k), &fallback);

    let mut p = Map::new();
    let s = |v: String| Value::String(v);
    p.insert("timestamp".into(), s(pick("timestamp", now_iso())));
    p.insert("event".into(), s(pick("event", if event.trim().is_empty() { "START".into() } else { event.trim().into() }).to_uppercase()));
    p.insert("event_uid".into(), s(pick("event_uid", uuid4_hex())));
    let user_flag = { let u = flag("username"); if u.is_empty() { current_user() } else { u } };
    p.insert("username".into(), s(pick("username", user_flag)));
    for k in ["nama", "nim", "tujuan", "keterangan", "job_type", "job_id", "session_type", "source", "session_id", "windows_user"] {
        p.insert(k.into(), s(pick(k, flag(k))));
    }
    let host_flag = { let h = flag("hostname"); if h.is_empty() { host_name() } else { h } };
    p.insert("hostname".into(), s(pick("hostname", host_flag)));
    p.insert("client_ip".into(), s(pick("client_ip", flag("client_ip"))));
    let anydesk_src = match data.get("anydesk_detected") {
        Some(v) => norm(Some(v), ""),
        None => { let f = flag("anydesk_detected"); if f.is_empty() { "0".into() } else { f } }
    };
    p.insert("anydesk_detected".into(), Value::from(truthy(&anydesk_src)));
    p.insert("identity_source".into(), s(pick("identity_source", "self_declared".into())));
    p.insert("person_role".into(), s(pick("person_role", String::new())));
    let raw = flag("raw_json");
    let raw = if !raw.is_empty() {
        raw
    } else if !data.is_empty() {
        py_dumps(&Value::Object(data.clone()), false)
    } else {
        let env = |k: &str| std::env::var(k).map(Value::String).unwrap_or(Value::Null);
        let mut m = Map::new();
        m.insert("argv_source".into(), Value::String("logix.exe".into()));
        m.insert("env_user".into(), env("USER"));
        m.insert("ssh_connection".into(), env("SSH_CONNECTION"));
        m.insert("pwd".into(), env("PWD"));
        py_dumps(&Value::Object(m), false)
    };
    p.insert("raw_json".into(), s(raw));

    let empty = |p: &Map<String, Value>, k: &str| p.get(k).and_then(|v| v.as_str()).map(|v| v.is_empty()).unwrap_or(true);
    if empty(&p, "timestamp") { p.insert("timestamp".into(), s(now_iso())); }
    if empty(&p, "event") { p.insert("event".into(), s("START".into())); }
    if empty(&p, "username") { p.insert("username".into(), s(current_user())); }
    if empty(&p, "hostname") { p.insert("hostname".into(), s(host_name())); }
    p
}

/// Record one event exactly as `logix.exe --json-file` does: a workstation
/// START first closes any session left open, then the row, then a
/// best-effort inline sync. Returns the new row id.
pub fn record_event(cfg: &Config, db_path: &std::path::Path, payload: &Map<String, Value>) -> Result<i64, String> {
    let con = db::connect(db_path).map_err(|e| e.to_string())?;
    db::migrate(&con).map_err(|e| e.to_string())?;
    let event = payload.get("event").and_then(|v| v.as_str()).unwrap_or("START");
    let session_type = payload.get("session_type").and_then(|v| v.as_str()).unwrap_or("").trim().to_uppercase();
    if event == "START" && (session_type == "PHYSICAL" || session_type == "ANYDESK") {
        db::close_open_workstation_sessions(&con, payload, "AUTO_FINISH").map_err(|e| e.to_string())?;
    }
    let rowid = db::insert_event(&con, payload).map_err(|e| e.to_string())?;
    // Best-effort inline delivery with a short timeout; the agent's periodic
    // retry picks up anything this misses.
    if !cfg.server_url().is_empty() {
        let _ = sync::sync_unsynced(&con, db_path, cfg, 3, 1);
    }
    Ok(rowid)
}

fn run_logging(argv: &[String]) -> Result<(), String> {
    let a = parse(argv)?;
    if a.flags.iter().any(|f| f == "--help") {
        println!("usage: logix.exe [--db DB] [--migrate] [--json-file JSON_FILE] [--repair-active] [--close-open]
                 [--sync-to-server] [--sync-preview] [--sync-status] [--event EVENT] [field flags]
       logix.exe agent [--once]");
        return Ok(());
    }
    let cfg = Config::load();
    let db_path = a.db.clone().map(PathBuf::from).unwrap_or_else(|| cfg.default_db());
    let has = |f: &str| a.flags.iter().any(|x| x == f);
    if !has("--close-open") && !has("--migrate") && !has("--sync-preview") && !has("--sync-status")
        && !has("--sync-to-server") && !has("--repair-active")
    {
        let payload = build_payload(&a)?;
        let event = payload.get("event").and_then(|v| v.as_str()).unwrap_or("START").to_string();
        let rowid = record_event(&cfg, &db_path, &payload)?;
        println!("OK logged {event} id={rowid} -> {}", db_path.display());
        return Ok(());
    }
    let con = db::connect(&db_path).map_err(|e| e.to_string())?;
    db::migrate(&con).map_err(|e| e.to_string())?;
    if has("--migrate") {
        println!("OK migrated: {}", db_path.display());
        return Ok(());
    }
    if has("--sync-preview") {
        return sync::preview(&con, &cfg);
    }
    if has("--sync-status") {
        let st = sync::sync_status(&con, &db_path, &cfg)?;
        println!("{}", py_dumps(&st, true));
        return Ok(());
    }
    if has("--sync-to-server") {
        let n = sync::sync_unsynced(&con, &db_path, &cfg, 10, 3)?;
        println!("OK synced logs to server: {n}");
        return Ok(());
    }
    if has("--repair-active") {
        let n = db::repair_active_from_session(&con, &cfg.session_json()).map_err(|e| e.to_string())?;
        println!("OK repaired active rows: {n}");
        return Ok(());
    }
    // --close-open
    let payload = build_payload(&a)?;
    let event = payload.get("event").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let reason = if event.is_empty() { "AUTO_FINISH".to_string() } else { event };
    let n = db::close_open_workstation_sessions(&con, &payload, &reason).map_err(|e| e.to_string())?;
    println!("OK closed open workstation sessions: {n}");
    Ok(())
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.first().map(|s| s.as_str()) == Some("agent") {
        std::process::exit(agent::run(&argv[1..]));
    }
    if let Err(e) = run_logging(&argv) {
        eprintln!("ERROR logix.exe: {e}");
        std::process::exit(2);
    }
}
