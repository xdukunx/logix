"""Tests for /api/log's event_uid-based dedup (roadmap item D). The old
session_id+event+timestamp tuple match is fragile -- a retry with a
slightly different timestamp (clock drift, or a retry hours later) would
create a duplicate row instead of being recognized as the same event.
event_uid is generated once agent-side (logix/log_physical.py's
payload_from_args) and carried through any retry unchanged.
"""
import importlib
import sys

from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "dev-test-key")
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", "")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.org")

    if "main" in sys.modules:
        module = importlib.reload(sys.modules["main"])
    else:
        module = importlib.import_module("main")

    module.DB_PATH = tmp_path / "test.db"
    module.CONFIG_PATH = tmp_path / "server_config.json"
    module.REPORTS_DIR = tmp_path / "reports"
    module.ACTIVE_TOKENS.clear()
    module.HEARTBEATS.clear()
    module.PENDING_COMMANDS.clear()
    return module


def _post_log(client, rows):
    return client.post("/api/log", json=rows, headers={"X-API-Key": "dev-test-key"})


def test_resent_event_uid_with_different_timestamp_is_a_no_op(monkeypatch, tmp_path):
    """The exact case the old dedup couldn't handle: same logical event,
    a later retry with a different timestamp (clock drift / delayed retry).
    event_uid alone must be enough to recognize it."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        row = {
            "timestamp": "2026-01-01T10:00:00", "event": "START",
            "session_id": "sess-1", "hostname": "PC-1", "event_uid": "uid-fixed-1",
        }
        first = _post_log(client, [row])
        retried = dict(row, timestamp="2026-01-01T10:05:00")  # different timestamp
        second = _post_log(client, [retried])

    assert first.json()["inserted"] == 1
    assert second.json()["inserted"] == 0


def test_two_different_event_uids_never_collide(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = _post_log(client, [
            {"timestamp": "2026-01-01T10:00:00", "event": "START", "event_uid": "uid-a"},
            {"timestamp": "2026-01-01T10:00:00", "event": "START", "event_uid": "uid-b"},
        ])
    assert res.json()["inserted"] == 2


def test_legacy_payload_without_event_uid_still_dedups_by_tuple(monkeypatch, tmp_path):
    """Backward compat: an agent that hasn't upgraded yet sends no
    event_uid at all -- must keep working exactly as before."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        row = {"timestamp": "2026-01-01T10:00:00", "event": "START", "session_id": "sess-legacy"}
        first = _post_log(client, [row])
        second = _post_log(client, [row])  # identical tuple, no event_uid

    assert first.json()["inserted"] == 1
    assert second.json()["inserted"] == 0


def test_legacy_payload_with_different_timestamp_creates_duplicate(monkeypatch, tmp_path):
    """Documents the known limitation this item fixes for upgraded agents
    only -- a legacy payload with no event_uid is still exposed to the old
    tuple-match fragility. Not a regression; a boundary of what backward
    compat can guarantee."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        row = {"timestamp": "2026-01-01T10:00:00", "event": "START", "session_id": "sess-legacy-2"}
        first = _post_log(client, [row])
        retried = dict(row, timestamp="2026-01-01T10:05:00")
        second = _post_log(client, [retried])

    assert first.json()["inserted"] == 1
    assert second.json()["inserted"] == 1  # duplicate row, as before this change


def test_event_uid_column_migrated_onto_existing_table(monkeypatch, tmp_path):
    """A physical_log table created before this shipped (no event_uid
    column) must still work -- init_db()'s additive ALTER TABLE."""
    module = _load_main(monkeypatch, tmp_path)
    conn = module.get_db()
    try:
        # Simulate a pre-migration table: every column this shipped with
        # BEFORE event_uid existed, just missing that one column -- not an
        # unrealistic bare-bones table (a real deployment's table would
        # already have nama/nim/tujuan/etc., just not event_uid).
        pre_migration_columns = {k: v for k, v in module.BASE_COLUMNS.items() if k != "event_uid"}
        conn.execute("DROP TABLE IF EXISTS physical_log")
        col_defs = ",\n            ".join(f"{k} {v}" for k, v in pre_migration_columns.items())
        conn.execute(f"CREATE TABLE physical_log (\n            {col_defs}\n        )")
        conn.commit()
    finally:
        conn.close()

    module.init_db()  # should ALTER TABLE ADD COLUMN event_uid without error

    with TestClient(module.app) as client:
        res = _post_log(client, [{"timestamp": "2026-01-01T10:00:00", "event": "START", "event_uid": "uid-post-migration"}])
    assert res.json()["inserted"] == 1
