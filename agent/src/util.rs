//! Small things the Python core got from its standard library.

use serde_json::Value;
use std::io::Write;

/// `datetime.now().astimezone().isoformat(timespec="seconds")`
pub fn now_iso() -> String {
    chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

/// `uuid.uuid4().hex`
pub fn uuid4_hex() -> String {
    let mut b = [0u8; 16];
    if getrandom::fill(&mut b).is_err() {
        // Never fail an event over its id: fall back to time + pid entropy.
        let n = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
            ^ ((std::process::id() as u128) << 64);
        b = n.to_le_bytes();
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Python's `str(v).strip()` for a JSON value, `None` -> default.
pub fn norm(v: Option<&Value>, default: &str) -> String {
    match v {
        None | Some(Value::Null) => default.to_string(),
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Bool(b)) => if *b { "True".into() } else { "False".into() },
        Some(Value::Number(n)) => n.to_string(),
        Some(other) => py_dumps(other, false),
    }
}

/// `1 if str(v).strip().lower() in {"1","true","yes","y","anydesk"} else 0`
pub fn truthy(v: &str) -> i64 {
    match v.trim().to_lowercase().as_str() {
        "1" | "true" | "yes" | "y" | "anydesk" => 1,
        _ => 0,
    }
}

/// `json.dumps(value, ensure_ascii=...)` with Python's default separators
/// (", " and ": "), so raw_json reads the same whichever core wrote it.
pub fn py_dumps(v: &Value, ensure_ascii: bool) -> String {
    let mut out = Vec::new();
    write_value(&mut out, v, ensure_ascii);
    String::from_utf8(out).unwrap_or_default()
}

fn write_str(out: &mut Vec<u8>, s: &str, ensure_ascii: bool) {
    out.push(b'"');
    for c in s.chars() {
        match c {
            '"' => out.extend_from_slice(b"\\\""),
            '\\' => out.extend_from_slice(b"\\\\"),
            '\n' => out.extend_from_slice(b"\\n"),
            '\r' => out.extend_from_slice(b"\\r"),
            '\t' => out.extend_from_slice(b"\\t"),
            '\u{08}' => out.extend_from_slice(b"\\b"),
            '\u{0c}' => out.extend_from_slice(b"\\f"),
            c if (c as u32) < 0x20 || (ensure_ascii && (c as u32) > 0x7e) => {
                let mut buf = [0u16; 2];
                for unit in c.encode_utf16(&mut buf) {
                    let _ = write!(out, "\\u{:04x}", unit);
                }
            }
            c => {
                let mut buf = [0u8; 4];
                out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
            }
        }
    }
    out.push(b'"');
}

fn write_value(out: &mut Vec<u8>, v: &Value, ascii: bool) {
    match v {
        Value::Null => out.extend_from_slice(b"null"),
        Value::Bool(b) => out.extend_from_slice(if *b { b"true" } else { b"false" }),
        Value::Number(n) => out.extend_from_slice(n.to_string().as_bytes()),
        Value::String(s) => write_str(out, s, ascii),
        Value::Array(a) => {
            out.push(b'[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.extend_from_slice(b", ");
                }
                write_value(out, x, ascii);
            }
            out.push(b']');
        }
        Value::Object(m) => {
            out.push(b'{');
            for (i, (k, x)) in m.iter().enumerate() {
                if i > 0 {
                    out.extend_from_slice(b", ");
                }
                write_str(out, k, ascii);
                out.extend_from_slice(b": ");
                write_value(out, x, ascii);
            }
            out.push(b'}');
        }
    }
}

/// Write a file atomically: temp + rename, so a reader never sees half of it.
pub fn write_atomic(path: &std::path::Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)
}

/// .NET's `ToString('o')` -- seven fractional digits and the offset -- the
/// shape every PowerShell-written timestamp in the state directory uses.
pub fn iso_o(t: &chrono::DateTime<chrono::Local>) -> String {
    use chrono::Timelike;
    format!(
        "{}.{:07}{}",
        t.format("%Y-%m-%dT%H:%M:%S"),
        t.nanosecond() % 1_000_000_000 / 100,
        t.format("%:z")
    )
}
