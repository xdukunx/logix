//! The local session store. Same table, same columns, same migrations as
//! logix/log_physical.py: a database written by either core is read by the
//! other, and by logbook_report.py / report_server.py, unchanged.

use crate::util::{norm, now_iso, py_dumps, truthy};
use rusqlite::{params_from_iter, types::Value as SqlValue, Connection};
use serde_json::{Map, Value};
use std::path::Path;

/// (name, declaration) in the exact order log_physical.BASE_COLUMNS uses.
pub const BASE_COLUMNS: &[(&str, &str)] = &[
    ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
    ("timestamp", "TEXT NOT NULL"),
    ("event", "TEXT NOT NULL"),
    ("username", "TEXT"),
    ("nama", "TEXT"),
    ("nim", "TEXT"),
    ("tujuan", "TEXT"),
    ("keterangan", "TEXT"),
    ("session_type", "TEXT"),
    ("source", "TEXT"),
    ("session_id", "TEXT"),
    ("windows_user", "TEXT"),
    ("hostname", "TEXT"),
    ("client_ip", "TEXT"),
    ("anydesk_detected", "INTEGER DEFAULT 0"),
    ("raw_json", "TEXT"),
    ("job_type", "TEXT"),
    ("job_id", "TEXT"),
    ("event_uid", "TEXT"),
    ("synced", "INTEGER DEFAULT 0"),
    ("identity_source", "TEXT"),
    ("person_role", "TEXT"),
];

const CLOSE_EVENTS_SQL: &str = "'END','LOCK','AUTO_FINISH','AUTO_CLOSE','DISCONNECT','LOGOFF'";

pub fn connect(path: &Path) -> rusqlite::Result<Connection> {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let con = Connection::open(path)?;
    con.busy_timeout(std::time::Duration::from_secs(30))?;
    let _: String = con.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))?;
    Ok(con)
}

fn existing_columns(con: &Connection, table: &str) -> Vec<String> {
    let Ok(mut st) = con.prepare(&format!("PRAGMA table_info({table})")) else { return vec![] };
    st.query_map([], |r| r.get::<_, String>(1))
        .map(|it| it.flatten().collect())
        .unwrap_or_default()
}

fn alter_decl(decl: &str) -> String {
    let upper = decl.to_uppercase();
    if upper.contains("NOT NULL") && !upper.contains("DEFAULT") {
        let stripped = decl.replace("NOT NULL", "").trim().to_string();
        if upper.starts_with("TEXT") {
            return format!("{stripped} DEFAULT ''");
        }
        if upper.starts_with("INTEGER") {
            return format!("{stripped} DEFAULT 0");
        }
        return stripped;
    }
    decl.to_string()
}

pub fn migrate(con: &Connection) -> rusqlite::Result<()> {
    let defs: Vec<String> = BASE_COLUMNS.iter().map(|(k, v)| format!("{k} {v}")).collect();
    con.execute_batch(&format!(
        "CREATE TABLE IF NOT EXISTS physical_log (\n        {}\n    )",
        defs.join(",\n        ")
    ))?;
    let cols = existing_columns(con, "physical_log");
    for (name, decl) in BASE_COLUMNS {
        if !cols.iter().any(|c| c == name) && !decl.to_uppercase().contains("PRIMARY KEY") {
            con.execute_batch(&format!("ALTER TABLE physical_log ADD COLUMN {name} {}", alter_decl(decl)))?;
        }
    }
    con.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_physical_log_timestamp ON physical_log(timestamp);
         CREATE INDEX IF NOT EXISTS idx_physical_log_session ON physical_log(session_id);
         CREATE INDEX IF NOT EXISTS idx_physical_log_event_uid ON physical_log(event_uid);
         CREATE INDEX IF NOT EXISTS idx_physical_log_type ON physical_log(session_type);
         CREATE INDEX IF NOT EXISTS idx_physical_log_event ON physical_log(event);",
    )?;
    rekey_auto_close_rows(con)?;
    let jobs = existing_columns(con, "jobs");
    if !jobs.is_empty() {
        for name in ["session_type", "source", "client_ip"] {
            if !jobs.iter().any(|c| c == name) {
                con.execute_batch(&format!("ALTER TABLE jobs ADD COLUMN {name} TEXT"))?;
            }
        }
    }
    Ok(())
}

/// Auto-close rows used to inherit the new START's event_uid, so the server
/// (which dedups on it) dropped every one of them and the replaced session
/// stayed open there. Give each its own uid and queue it again. Same SQL as
/// log_physical.rekey_auto_close_rows; idempotent.
pub fn rekey_auto_close_rows(con: &Connection) -> rusqlite::Result<usize> {
    con.execute(
        "UPDATE physical_log
            SET event_uid = lower(hex(randomblob(16))), synced = 0
          WHERE source = 'auto_close_before_new_start'
            AND COALESCE(event_uid, '') <> ''
            AND event_uid IN (SELECT event_uid FROM physical_log o
                               WHERE o.id <> physical_log.id)",
        [],
    )
}

/// Old installs carried a UNIQUE index on session_id, which makes the END of a
/// session impossible to record. Dropped on first collision, as in Python.
fn drop_bad_unique_session_indexes(con: &Connection) {
    let Ok(mut st) = con.prepare("PRAGMA index_list(physical_log)") else { return };
    let idx: Vec<(String, i64)> = st
        .query_map([], |r| Ok((r.get::<_, String>(1)?, r.get::<_, i64>(2).unwrap_or(0))))
        .map(|it| it.flatten().collect())
        .unwrap_or_default();
    for (name, unique) in idx {
        if unique != 1 {
            continue;
        }
        let cols: Vec<String> = con
            .prepare(&format!("PRAGMA index_info({name})"))
            .and_then(|mut s| s.query_map([], |r| r.get::<_, String>(2)).map(|it| it.flatten().collect()))
            .unwrap_or_default();
        if cols == ["session_id"] || (cols.iter().any(|c| c == "session_id") && cols.len() <= 2) {
            let _ = con.execute_batch(&format!("DROP INDEX IF EXISTS \"{name}\""));
        }
    }
}

fn values_for(payload: &Map<String, Value>, cols: &[&str]) -> Vec<SqlValue> {
    cols.iter()
        .map(|c| {
            let decl = BASE_COLUMNS.iter().find(|(n, _)| n == c).map(|(_, d)| *d).unwrap_or("TEXT");
            let integer = decl.to_uppercase().starts_with("INTEGER");
            match payload.get(*c) {
                None | Some(Value::Null) => if integer { SqlValue::Integer(0) } else { SqlValue::Text(String::new()) },
                Some(Value::String(s)) if s.is_empty() => {
                    if integer { SqlValue::Integer(0) } else { SqlValue::Text(String::new()) }
                }
                Some(Value::String(s)) => SqlValue::Text(s.clone()),
                Some(Value::Number(n)) => n.as_i64().map(SqlValue::Integer).unwrap_or_else(|| SqlValue::Real(n.as_f64().unwrap_or(0.0))),
                Some(Value::Bool(b)) => SqlValue::Integer(*b as i64),
                Some(other) => SqlValue::Text(other.to_string()),
            }
        })
        .collect()
}

pub fn insert_event(con: &Connection, payload: &Map<String, Value>) -> rusqlite::Result<i64> {
    let cols: Vec<&str> = BASE_COLUMNS.iter().map(|(n, _)| *n).filter(|n| *n != "id").collect();
    let sql = format!(
        "INSERT INTO physical_log ({}) VALUES ({})",
        cols.join(","),
        vec!["?"; cols.len()].join(",")
    );
    let run = |p: &Map<String, Value>| -> rusqlite::Result<i64> {
        con.execute(&sql, params_from_iter(values_for(p, &cols)))?;
        Ok(con.last_insert_rowid())
    };
    match run(payload) {
        Err(e) if e.to_string().contains("session_id") => {
            drop_bad_unique_session_indexes(con);
            match run(payload) {
                Err(rusqlite::Error::SqliteFailure(_, _)) => {
                    let mut p = payload.clone();
                    let base = norm(p.get("session_id"), "session");
                    let suffix = chrono::Local::now().format("%H%M%S%6f").to_string();
                    p.insert("session_id".into(), Value::String(format!("{base}-{suffix}")));
                    run(&p)
                }
                other => other,
            }
        }
        other => other,
    }
}

fn row_text(row: &rusqlite::Row, name: &str) -> String {
    match row.get::<_, SqlValue>(name) {
        Ok(SqlValue::Text(s)) => s.trim().to_string(),
        Ok(SqlValue::Integer(i)) => i.to_string(),
        Ok(SqlValue::Real(f)) => f.to_string(),
        _ => String::new(),
    }
}

fn first_nonempty(vals: &[&str]) -> String {
    vals.iter().map(|v| v.trim()).find(|v| !v.is_empty()).unwrap_or("").to_string()
}

/// A new START closes every workstation session that never got a closing
/// event -- the guard against START stacks when lock/disconnect did not fire.
pub fn close_open_workstation_sessions(con: &Connection, closing: &Map<String, Value>, reason: &str) -> rusqlite::Result<usize> {
    if existing_columns(con, "physical_log").is_empty() {
        return Ok(0);
    }
    struct Open {
        id: i64,
        sid: String,
        session_type: String,
        username: String,
        nama: String,
        nim: String,
        tujuan: String,
        keterangan: String,
        windows_user: String,
        hostname: String,
        anydesk: Option<i64>,
    }
    let sql = format!(
        "SELECT s.* FROM physical_log s
          WHERE UPPER(COALESCE(s.event,''))='START'
            AND UPPER(COALESCE(s.session_type,'')) IN ('PHYSICAL','ANYDESK')
            AND COALESCE(s.session_id,'') <> ''
            AND NOT EXISTS (SELECT 1 FROM physical_log e
                             WHERE e.session_id = s.session_id
                               AND UPPER(COALESCE(e.event,'')) IN ({CLOSE_EVENTS_SQL}))
          ORDER BY s.timestamp ASC, s.id ASC"
    );
    let open: Vec<Open> = {
        let mut st = con.prepare(&sql)?;
        let rows = st.query_map([], |r| {
            Ok(Open {
                id: r.get("id")?,
                sid: row_text(r, "session_id"),
                session_type: row_text(r, "session_type"),
                username: row_text(r, "username"),
                nama: row_text(r, "nama"),
                nim: row_text(r, "nim"),
                tujuan: row_text(r, "tujuan"),
                keterangan: row_text(r, "keterangan"),
                windows_user: row_text(r, "windows_user"),
                hostname: row_text(r, "hostname"),
                anydesk: r.get::<_, Option<i64>>("anydesk_detected").unwrap_or(None),
            })
        })?;
        rows.flatten().collect()
    };
    let current = norm(closing.get("session_id"), "");
    let c = |k: &str| norm(closing.get(k), "");
    let mut count = 0;
    for row in open {
        if row.sid.is_empty() || row.sid == current {
            continue;
        }
        let mut p = closing.clone();
        let raw: Value = serde_json::json!({
            "auto_close": true,
            "reason": reason,
            "closed_session_id": row.sid,
            "new_session_id": current,
            "source_start_id": row.id,
        });
        let host_default = crate::host_name();
        let set = |p: &mut Map<String, Value>, k: &str, v: String| {
            p.insert(k.into(), Value::String(v));
        };
        set(&mut p, "event", reason.to_string());
        set(&mut p, "event_uid", crate::util::uuid4_hex());
        set(&mut p, "session_id", row.sid.clone());
        set(&mut p, "session_type", first_nonempty(&[&row.session_type, &c("session_type"), "Physical"]));
        set(&mut p, "source", "auto_close_before_new_start".into());
        set(&mut p, "username", first_nonempty(&[&row.username, &c("username")]));
        set(&mut p, "nama", first_nonempty(&[&row.nama, &c("nama")]));
        set(&mut p, "nim", first_nonempty(&[&row.nim, &c("nim")]));
        set(&mut p, "tujuan", first_nonempty(&[&row.tujuan, &c("tujuan")]));
        set(&mut p, "keterangan", first_nonempty(&[&row.keterangan, &c("keterangan"), "Auto-closed by new workstation session"]));
        set(&mut p, "windows_user", first_nonempty(&[&row.windows_user, &c("windows_user")]));
        set(&mut p, "hostname", first_nonempty(&[&row.hostname, &c("hostname"), &host_default]));
        let anydesk = match row.anydesk {
            Some(v) => Value::from(v),
            None => closing.get("anydesk_detected").cloned().unwrap_or(Value::from(0)),
        };
        p.insert("anydesk_detected".into(), anydesk);
        set(&mut p, "raw_json", py_dumps(&raw, false));
        insert_event(con, &p)?;
        count += 1;
    }
    Ok(count)
}

/// Fill the active Windows session's row back in from session.json -- the
/// recovery path for a START whose (asynchronous) write never landed.
pub fn repair_active_from_session(con: &Connection, session_path: &Path) -> rusqlite::Result<usize> {
    let Some(data) = crate::config::read_json(session_path) else { return Ok(0) };
    let g = |k: &str| norm(data.get(k), "");
    let sid = g("session_id");
    if sid.is_empty() {
        return Ok(0);
    }
    let start = norm(data.get("start_time"), &now_iso());
    let username = { let u = g("username"); if u.is_empty() { g("windows_user") } else { u } };
    let session_type = norm(data.get("session_type"), "Physical");
    let hostname = norm(data.get("hostname"), &crate::host_name());
    let anydesk = truthy(&norm(data.get("anydesk_detected"), ""));
    let raw = py_dumps(&data, false);
    let named: Vec<(&str, SqlValue)> = vec![
        (":timestamp", SqlValue::Text(start)),
        (":event", SqlValue::Text("START".into())),
        (":username", SqlValue::Text(username)),
        (":nama", SqlValue::Text(g("nama"))),
        (":nim", SqlValue::Text(g("nim"))),
        (":tujuan", SqlValue::Text(g("tujuan"))),
        (":keterangan", SqlValue::Text(g("keterangan"))),
        (":session_type", SqlValue::Text(session_type)),
        (":source", SqlValue::Text("windows_wpf_repair".into())),
        (":session_id", SqlValue::Text(sid)),
        (":windows_user", SqlValue::Text(g("windows_user"))),
        (":hostname", SqlValue::Text(hostname)),
        (":client_ip", SqlValue::Text(g("client_ip"))),
        (":anydesk_detected", SqlValue::Integer(anydesk)),
        (":raw_json", SqlValue::Text(raw)),
    ];
    let pick = |keys: &[&str]| -> Vec<(&str, &dyn rusqlite::ToSql)> {
        named.iter().filter(|(k, _)| keys.contains(k)).map(|(k, v)| (*k, v as &dyn rusqlite::ToSql)).collect()
    };
    let upd = "UPDATE physical_log
           SET timestamp = CASE WHEN COALESCE(timestamp,'')='' THEN :timestamp ELSE timestamp END,
               event = CASE WHEN COALESCE(event,'')='' THEN :event ELSE event END,
               username = CASE WHEN COALESCE(username,'')='' THEN :username ELSE username END,
               nama = CASE WHEN COALESCE(nama,'')='' THEN :nama ELSE nama END,
               nim = CASE WHEN COALESCE(nim,'')='' THEN :nim ELSE nim END,
               tujuan = CASE WHEN COALESCE(tujuan,'')='' THEN :tujuan ELSE tujuan END,
               keterangan = CASE WHEN COALESCE(keterangan,'')='' THEN :keterangan ELSE keterangan END,
               session_type = CASE WHEN COALESCE(session_type,'')='' THEN :session_type ELSE session_type END,
               source = CASE WHEN COALESCE(source,'')='' THEN :source ELSE source END,
               windows_user = CASE WHEN COALESCE(windows_user,'')='' THEN :windows_user ELSE windows_user END,
               hostname = CASE WHEN COALESCE(hostname,'')='' THEN :hostname ELSE hostname END,
               anydesk_detected = :anydesk_detected,
               raw_json = :raw_json
         WHERE session_id = :session_id";
    let all: Vec<&str> = vec![
        ":timestamp", ":event", ":username", ":nama", ":nim", ":tujuan", ":keterangan", ":session_type",
        ":source", ":windows_user", ":hostname", ":anydesk_detected", ":raw_json", ":session_id",
    ];
    let mut changed = con.execute(upd, pick(&all).as_slice())?;
    if changed == 0 {
        let id: Option<i64> = con
            .query_row(
                "SELECT id FROM physical_log
                  WHERE (COALESCE(timestamp,'')='' OR COALESCE(nama,'')='' OR COALESCE(tujuan,'')='')
                    AND UPPER(COALESCE(session_type,'')) IN ('PHYSICAL','ANYDESK')
                  ORDER BY id DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .ok();
        if let Some(id) = id {
            let mut p: Vec<(&str, &dyn rusqlite::ToSql)> = named.iter().map(|(k, v)| (*k, v as &dyn rusqlite::ToSql)).collect();
            p.push((":id", &id));
            changed = con.execute(
                "UPDATE physical_log
                    SET timestamp=:timestamp, event=:event, username=:username, nama=:nama, nim=:nim,
                        tujuan=:tujuan, keterangan=:keterangan, session_type=:session_type,
                        source=:source, session_id=:session_id, windows_user=:windows_user,
                        hostname=:hostname, client_ip=:client_ip, anydesk_detected=:anydesk_detected,
                        raw_json=:raw_json
                  WHERE id=:id",
                p.as_slice(),
            )?;
        }
    }
    Ok(changed)
}

/// Every not-yet-synced row as a JSON object, columns in table order, without
/// id/synced -- the /api/log body. Returns (row ids, objects).
pub fn unsynced(con: &Connection) -> rusqlite::Result<(Vec<i64>, Vec<Value>)> {
    let mut st = con.prepare("SELECT * FROM physical_log WHERE COALESCE(synced, 0) = 0 ORDER BY id ASC")?;
    let names: Vec<String> = st.column_names().iter().map(|s| s.to_string()).collect();
    let mut ids = Vec::new();
    let mut rows = Vec::new();
    let mut q = st.query([])?;
    while let Some(r) = q.next()? {
        let mut obj = Map::new();
        for (i, n) in names.iter().enumerate() {
            let v: SqlValue = r.get(i)?;
            if n == "id" {
                if let SqlValue::Integer(id) = v {
                    ids.push(id);
                }
                continue;
            }
            if n == "synced" {
                continue;
            }
            let jv = match v {
                SqlValue::Null => Value::Null,
                SqlValue::Integer(i) => Value::from(i),
                SqlValue::Real(f) => Value::from(f),
                SqlValue::Text(s) => Value::String(s),
                SqlValue::Blob(_) => Value::Null,
            };
            obj.insert(n.clone(), jv);
        }
        rows.push(Value::Object(obj));
    }
    Ok((ids, rows))
}

pub fn pending_count(con: &Connection) -> i64 {
    con.query_row("SELECT COUNT(*) FROM physical_log WHERE COALESCE(synced, 0) = 0", [], |r| r.get(0))
        .unwrap_or(0)
}

pub fn mark_synced(con: &Connection, ids: &[i64]) -> rusqlite::Result<()> {
    if ids.is_empty() {
        return Ok(());
    }
    let sql = format!(
        "UPDATE physical_log SET synced = 1 WHERE id IN ({})",
        vec!["?"; ids.len()].join(",")
    );
    con.execute(&sql, params_from_iter(ids.iter()))?;
    Ok(())
}
