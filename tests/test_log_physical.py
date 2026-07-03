"""Tests for logix/log_physical.py -- event_uid generation (roadmap item D)
and, once added, --sync-preview / retry-backoff.

Deliberately import log_physical INSIDE each test function, not at module
top-level -- log_physical.DEFAULT_DB is a module-level constant computed
once at import time from paths.default_db(), and tests/test_gsheet_sync.py
depends on being the first importer (after its own monkeypatch sets
LOGIX_DB) so that constant reflects its synthetic tmp_path DB. A top-level
import here would run during pytest's collection phase, before any
monkeypatch fixture executes, permanently poisoning that constant for the
rest of the test session.
"""


def test_payload_from_args_generates_event_uid_when_absent():
    import log_physical
    ns = log_physical.parse_args(["--event", "START", "--hostname", "PC-1"])
    payload = log_physical.payload_from_args(ns)
    assert payload["event_uid"]
    assert len(payload["event_uid"]) == 32  # uuid4().hex


def test_payload_from_args_generates_different_uids_each_call():
    import log_physical
    ns = log_physical.parse_args(["--event", "START"])
    a = log_physical.payload_from_args(ns)
    b = log_physical.payload_from_args(ns)
    assert a["event_uid"] != b["event_uid"]


def test_payload_from_args_preserves_event_uid_from_json_file(tmp_path):
    """The JSON file is the unit of retry -- a crashed/retried process
    re-reads the same file, so an existing event_uid must be kept, not
    regenerated (that's what makes a retry actually idempotent)."""
    import log_physical
    json_path = tmp_path / "payload.json"
    json_path.write_text(
        '{"event": "START", "hostname": "PC-1", "event_uid": "fixed-uid-123"}',
        encoding="utf-8",
    )
    ns = log_physical.parse_args(["--json-file", str(json_path)])
    payload = log_physical.payload_from_args(ns)
    assert payload["event_uid"] == "fixed-uid-123"


def test_event_uid_column_in_base_columns():
    import log_physical
    assert "event_uid" in log_physical.BASE_COLUMNS


def test_migrate_adds_event_uid_to_pre_existing_table(tmp_path):
    """A DB created before event_uid shipped must still migrate cleanly."""
    import sqlite3
    import log_physical

    db_path = tmp_path / "legacy.db"
    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    pre_migration_columns = {k: v for k, v in log_physical.BASE_COLUMNS.items() if k != "event_uid"}
    col_defs = ",\n        ".join(f"{k} {v}" for k, v in pre_migration_columns.items())
    con.execute(f"CREATE TABLE physical_log (\n        {col_defs}\n    )")
    con.commit()
    con.close()

    con = log_physical.connect(db_path)
    try:
        log_physical.migrate(con)  # must not raise
        cols = log_physical.existing_columns(con, "physical_log")
        assert "event_uid" in cols
    finally:
        con.close()


def test_insert_event_stores_event_uid(tmp_path):
    import log_physical
    db_path = tmp_path / "test.db"
    con = log_physical.connect(db_path)
    try:
        log_physical.migrate(con)
        ns = log_physical.parse_args(["--event", "START", "--hostname", "PC-1"])
        payload = log_physical.payload_from_args(ns)
        row_id = log_physical.insert_event(con, payload)
        row = con.execute("SELECT event_uid FROM physical_log WHERE id = ?", (row_id,)).fetchone()
        assert row["event_uid"] == payload["event_uid"]
    finally:
        con.close()
