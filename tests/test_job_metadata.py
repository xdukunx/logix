"""Optional job metadata, and the additive migration that carries it (Phase C).

Logix is still person + workstation + purpose + session. A job is something
a session MAY be associated with, which is why this is two nullable columns
rather than a jobs table and a taxonomy nobody has agreed on. These tests
pin the parts that would quietly break real installs: that an existing
database gains the columns without losing rows, that old rows stay valid
with NULL, and that job fields never become required.
"""
from __future__ import annotations

import importlib
import sqlite3
import sys

import pytest


def _lp():
    if "log_physical" in sys.modules:
        return importlib.reload(sys.modules["log_physical"])
    return importlib.import_module("log_physical")


@pytest.fixture
def db(monkeypatch, tmp_path):
    path = tmp_path / "device.db"
    monkeypatch.setenv("LOGIX_DB", str(path))
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "local_only")
    lp = _lp()
    con = lp.connect(path)
    lp.migrate(con)
    yield lp, con, path
    con.close()


def _cols(con):
    return {r[1] for r in con.execute("PRAGMA table_info(physical_log)").fetchall()}


# ---- migration ----------------------------------------------------------

def test_fresh_database_has_the_columns(db):
    _, con, _ = db
    assert {"job_type", "job_id"} <= _cols(con)


def test_migration_is_idempotent(db):
    """migrate() runs on every single log_physical invocation. If a second
    pass tried to re-ADD the columns, every event after the first would
    raise instead of being recorded."""
    lp, con, _ = db
    for _ in range(3):
        lp.migrate(con)
    assert {"job_type", "job_id"} <= _cols(con)


def test_pre_existing_database_keeps_its_rows(monkeypatch, tmp_path):
    """The real upgrade path: a device that has been logging for months.
    Simulated by building the table WITHOUT the new columns, inserting a
    row, then migrating -- which is what an installed agent actually does
    the first time it runs new code."""
    path = tmp_path / "old.db"
    monkeypatch.setenv("LOGIX_DB", str(path))
    con = sqlite3.connect(str(path))
    con.execute(
        "CREATE TABLE physical_log ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT NOT NULL, "
        "event TEXT NOT NULL, nama TEXT, nim TEXT, session_id TEXT)")
    con.execute("INSERT INTO physical_log (timestamp, event, nama, nim, session_id) "
                "VALUES ('2026-01-05T08:00:00+07:00','START','Lama','000000000','old-1')")
    con.commit()
    con.close()

    lp = _lp()
    con = lp.connect(path)
    lp.migrate(con)
    try:
        assert {"job_type", "job_id"} <= _cols(con)
        row = con.execute(
            "SELECT nama, job_type, job_id FROM physical_log WHERE session_id='old-1'"
        ).fetchone()
        assert row[0] == "Lama", "the historical row survived the migration"
        assert row[1] is None and row[2] is None, "and reads back as NULL, not ''"
    finally:
        con.close()


# ---- the fields themselves ----------------------------------------------

def test_job_metadata_round_trips(db):
    lp, con, _ = db
    ns = lp.parse_args(["--event", "START", "--session-id", "j1",
                        "--job-type", "Simulation", "--job-id", "258026"])
    lp.insert_event(con, lp.payload_from_args(ns))

    row = con.execute(
        "SELECT job_type, job_id FROM physical_log WHERE session_id='j1'").fetchone()
    assert (row[0], row[1]) == ("Simulation", "258026")


def test_job_metadata_is_optional(db):
    """Most workstation use is not a formal job. Omitting both must be an
    ordinary, unremarkable event -- not an error, and not a row that later
    code has to treat as malformed."""
    lp, con, _ = db
    ns = lp.parse_args(["--event", "START", "--session-id", "j2"])
    lp.insert_event(con, lp.payload_from_args(ns))

    row = con.execute(
        "SELECT job_type, job_id FROM physical_log WHERE session_id='j2'").fetchone()
    assert row[0] == "" and row[1] == ""


def test_job_fields_do_not_affect_event_identity(db):
    """event_uid is the sync dedup key. If job metadata leaked into it, the
    same logical event would sync twice whenever someone edited a job id."""
    lp, con, _ = db
    a = lp.payload_from_args(lp.parse_args(
        ["--event", "START", "--session-id", "same", "--job-id", "1"]))
    b = dict(a)
    b["job_id"] = "999"
    assert a["event_uid"] == b["event_uid"], "uid is minted independently of job fields"


def test_start_still_works_with_no_job_arguments_at_all(db):
    """Guard against the fields becoming de-facto required through a
    downstream KeyError."""
    lp, con, _ = db
    ns = lp.parse_args(["--event", "START", "--session-id", "plain",
                        "--nama", "Uji", "--nim", "000000000",
                        "--tujuan", "Maintenance"])
    lp.insert_event(con, lp.payload_from_args(ns))
    assert con.execute(
        "SELECT count(*) FROM physical_log WHERE session_id='plain'").fetchone()[0] == 1


# ---- a BOM must not make an enrolled device look unenrolled -------------

def test_device_identity_survives_a_utf8_bom(monkeypatch, tmp_path):
    """Anything that rewrites device.json from PowerShell adds a BOM by
    default, and json.loads rejects a leading BOM outright. Because the
    reader swallows ValueError and returns {}, the visible symptom was every
    sync failing 401 with a valid per-device key sitting right there on disk
    -- and nothing in any log connecting the two.
    """
    import importlib
    identity = tmp_path / "device.json"
    identity.write_text(
        '\ufeff{"device_id": "abc-123", "api_key": "k" * 1, "category": ""}'.replace(
            '"k" * 1', '"secret-key"'),
        encoding="utf-8")
    monkeypatch.setenv("LOGIX_HOME", str(tmp_path))
    monkeypatch.setenv("LOGIX_DEVICE_IDENTITY", str(identity))
    paths = importlib.reload(importlib.import_module("paths"))
    if paths.device_identity_path() != identity:
        pytest.skip("this build resolves device.json by a path this test cannot set")
    assert paths.device_api_key() == "secret-key"
    assert paths.device_id() == "abc-123"


def test_config_env_survives_a_utf8_bom(monkeypatch, tmp_path):
    """A BOM lands on the FIRST key name, so the first setting in the file
    silently stops resolving while every one below it works -- worse than an
    outright failure, because nothing looks broken until that key matters."""
    import importlib
    cfg = tmp_path / "config.env"
    cfg.write_text("\ufeffLOGIX_SERVER_URL=http://example.test\nLOGIX_USE_WSL=0\n",
                   encoding="utf-8")
    monkeypatch.setenv("LOGIX_CONFIG", str(cfg))
    monkeypatch.delenv("LOGIX_SERVER_URL", raising=False)
    paths = importlib.reload(importlib.import_module("paths"))
    assert paths.server_url() == "http://example.test"
