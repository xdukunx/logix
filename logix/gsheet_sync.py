#!/usr/bin/env python3
"""Logix -> Google Sheet one-way sync (PRIVACY-FIRST).

The local SQLite database is the source of truth. This module pushes a
REDACTED, AGGREGATED mirror to a Google Sheet so a lab can see usage without
any personal data leaving the workstation.

Design: docs/GSHEET_SYNC_DESIGN.md. The hard requirements are enforced here:

  * Redaction gate (`redact`) is a WHITELIST: it emits only date, an opaque
    member token, session_type, and hours. Client IP and raw NIM are never
    read into the output, so they cannot leak even if they appear in unexpected
    columns (e.g. an IP embedded in a free-text `keterangan`).
  * One-way only. The DB is opened READ-ONLY; this module never writes to it,
    so a missing-creds or network failure cannot corrupt local data.
  * Idempotent upsert keyed by date|member|session_type, so re-running updates
    in place instead of duplicating rows.
  * The Google dependency (`gspread`) is isolated to `GSheetClient` and imported
    lazily — the rest of Logix (and this module's tested core) needs no
    third-party libraries.

Config (via env or config.env, see logix/paths.py):
    LOGIX_GSHEET_ID       target spreadsheet id
    LOGIX_GSHEET_CREDS    path to service_account.json (gitignored, never committed)
    LOGIX_REDACT_MODE     initials | hash | code   (default: initials)
    LOGIX_GSHEET_SALT     salt for hash/code modes  (keep stable across runs)
"""
from __future__ import annotations

import hmac
import sqlite3
import sys
from hashlib import sha256
from pathlib import Path
from typing import Any, Iterable

import paths
import logbook_report as report

# Fields the redaction gate is allowed to emit. Anything not here never leaves
# the box. This is the privacy contract — keep it tight.
SAFE_FIELDS = ("date", "member", "session_type", "hours")

REDACT_MODES = ("initials", "hash", "code")


# --------------------------------------------------------------------------- #
# Redaction gate (pure, no I/O, no third-party deps)
# --------------------------------------------------------------------------- #
def member_token(name: str, mode: str = "initials", salt: str = "") -> str:
    """Map a name to a non-identifying, STABLE token.

    Same (name, mode, salt) always yields the same token; the hash/code modes
    are one-way (cannot be reversed to the name without brute force, and the
    salt is never published).
    """
    name = (name or "").strip()
    if not name:
        return "ANON"
    if mode == "initials":
        parts = [p for p in name.split() if p]
        return ".".join(p[0].upper() for p in parts) + "." if parts else "ANON"
    digest = hmac.new(salt.encode("utf-8"), name.lower().encode("utf-8"), sha256).hexdigest()
    if mode == "hash":
        return "u-" + digest[:10]
    if mode == "code":
        return "M-" + digest[:4].upper()
    raise ValueError(f"unknown LOGIX_REDACT_MODE: {mode!r} (expected one of {REDACT_MODES})")


def _session_hours(session: dict[str, Any]) -> float:
    """Numeric hours for a session, from explicit 'hours' or paired timestamps."""
    if session.get("hours") is not None:
        try:
            return round(float(session["hours"]), 4)
        except (TypeError, ValueError):
            return 0.0
    start = report.parse_ts(session.get("start_ts"))
    end = report.parse_ts(session.get("end_ts")) if session.get("end_ts") else None
    if not start or not end:
        return 0.0  # active / unterminated sessions contribute no closed hours
    return round(max(0.0, (end - start).total_seconds()) / 3600.0, 4)


def _session_date(session: dict[str, Any]) -> str:
    if session.get("date"):
        return str(session["date"])[:10]
    ts = session.get("start_ts") or session.get("timestamp") or ""
    return str(ts)[:10]


def redact(row: dict[str, Any], mode: str = "initials", salt: str = "") -> dict[str, Any]:
    """WHITELIST gate: a session/row in, a safe dict out.

    Reads ONLY name, session_type, date and duration. Never reads client_ip,
    nim, keterangan, raw_json, hostname, username — so none of them can appear
    in the result regardless of how the input is shaped.
    """
    name = row.get("nama") or row.get("name") or ""
    stype = (row.get("tipe") or row.get("session_type") or "").upper() or "UNKNOWN"
    out = {
        "date": _session_date(row),
        "member": member_token(name, mode, salt),
        "session_type": stype,
        "hours": _session_hours(row),
    }
    # Defensive: guarantee the output never carries anything outside the contract.
    return {k: out[k] for k in SAFE_FIELDS}


# --------------------------------------------------------------------------- #
# Aggregation + idempotent upsert keying (pure)
# --------------------------------------------------------------------------- #
def row_key(r: dict[str, Any]) -> str:
    return f"{r['date']}|{r['member']}|{r['session_type']}"


def aggregate(redacted: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Sum hours per (date, member, session_type). No raw session rows escape."""
    totals: dict[str, dict[str, Any]] = {}
    for r in redacted:
        key = row_key(r)
        bucket = totals.setdefault(key, {
            "key": key,
            "date": r["date"],
            "member": r["member"],
            "session_type": r["session_type"],
            "hours": 0.0,
        })
        bucket["hours"] = round(bucket["hours"] + float(r.get("hours") or 0.0), 4)
    return sorted(totals.values(), key=lambda x: x["key"])


def merge_rows(existing: Iterable[dict[str, Any]], desired: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Idempotent upsert: desired rows overwrite existing by key; no duplicates.

    merge_rows(merge_rows(X, D), D) == merge_rows(X, D) for any X, D.
    """
    by_key: dict[str, dict[str, Any]] = {}
    for r in existing:
        if r.get("key"):
            by_key[r["key"]] = dict(r)
    for r in desired:
        by_key[row_key(r) if "key" not in r else r["key"]] = dict(r)
    return sorted(by_key.values(), key=lambda x: x["key"])


def build_export(rows: list[Any], mode: str = "initials", salt: str = "") -> list[dict[str, Any]]:
    """Full pure pipeline: DB rows -> sessions -> redact -> aggregate."""
    sessions = report.build_sessions(rows)
    redacted = [redact(s, mode, salt) for s in sessions]
    return aggregate(redacted)


# --------------------------------------------------------------------------- #
# DB read (strictly read-only — enforces "one-way")
# --------------------------------------------------------------------------- #
def read_rows(db_path: Path) -> list[Any]:
    """Read physical_log via a READ-ONLY connection. Never writes to the DB."""
    if not db_path.exists():
        raise FileNotFoundError(f"database not found: {db_path}")
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        con.row_factory = sqlite3.Row
        return report.fetch_physical(con, None, None)
    finally:
        con.close()


# --------------------------------------------------------------------------- #
# Google adapter — the ONLY part needing a third-party lib (lazy import)
# --------------------------------------------------------------------------- #
SHEET_HEADER = ["date", "member", "session_type", "hours", "key"]


class GSheetClient:
    """Thin one-way Sheets adapter. gspread is imported lazily so importing this
    module (and unit-testing the core above) needs no Google dependency."""

    def __init__(self, sheet_id: str, creds_path: Path):
        if not creds_path.exists():
            raise FileNotFoundError(
                f"service-account creds not found: {creds_path}. "
                "Set LOGIX_GSHEET_CREDS to the JSON key path (never commit it)."
            )
        try:
            import gspread  # noqa: F401
            from google.oauth2.service_account import Credentials
        except ImportError as exc:  # pragma: no cover - environment dependent
            raise RuntimeError(
                "Google sync requires 'gspread' and 'google-auth'. Install them "
                "only where you run the sync: pip install gspread google-auth"
            ) from exc
        scopes = ["https://www.googleapis.com/auth/spreadsheets"]
        creds = Credentials.from_service_account_file(str(creds_path), scopes=scopes)
        self._gc = gspread.authorize(creds)
        self._sheet = self._gc.open_by_key(sheet_id).sheet1

    def read_existing(self) -> list[dict[str, Any]]:
        records = self._sheet.get_all_records()
        return [r for r in records if r.get("key")]

    def write_all(self, rows: list[dict[str, Any]]) -> None:
        values = [SHEET_HEADER] + [[r["date"], r["member"], r["session_type"], r["hours"], r["key"]] for r in rows]
        self._sheet.clear()
        self._sheet.update(values, "A1")


def sync(db_path: Path, sheet_id: str, creds_path: Path, mode: str = "initials", salt: str = "") -> int:
    """Read DB (read-only) -> redact/aggregate -> idempotent upsert to the Sheet.

    Returns the number of rows written. The DB is never modified; any failure
    before the write leaves the Sheet untouched and the DB intact.
    """
    rows = read_rows(db_path)            # read-only; safe to do before touching the network
    desired = build_export(rows, mode, salt)
    client = GSheetClient(sheet_id, creds_path)   # raises cleanly if creds/libs missing
    merged = merge_rows(client.read_existing(), desired)
    client.write_all(merged)
    return len(merged)


def main(argv: list[str] | None = None) -> int:
    sheet_id = paths.get("LOGIX_GSHEET_ID")
    creds = paths.get("LOGIX_GSHEET_CREDS")
    mode = paths.get("LOGIX_REDACT_MODE", "initials")
    salt = paths.get("LOGIX_GSHEET_SALT", "")
    if not sheet_id or not creds:
        print("Sync not configured: set LOGIX_GSHEET_ID and LOGIX_GSHEET_CREDS "
              "in config.env. (DB untouched.)", file=sys.stderr)
        return 1
    try:
        n = sync(paths.default_db(), sheet_id, Path(creds), mode, salt)
    except Exception as exc:
        print(f"Sync failed (local DB untouched): {exc}", file=sys.stderr)
        return 2
    print(f"OK synced {n} aggregated rows to sheet {sheet_id} (mode={mode})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
