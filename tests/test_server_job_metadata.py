"""Job metadata must survive the sync round trip (server side).

It did not, and nothing caught it: the client gained job_type/job_id, the
agent posted them, and the server dropped them on the floor -- so the same
session read one way on the device and another way on the central
dashboard, with nothing on either screen to explain the difference.

The second test guards the mechanism that made the first failure so
confusing to diagnose: /api/log builds its column list from BASE_COLUMNS
but its value list by hand, so adding a column to one without the other
produces a blanket HTTP 500 with the real cause buried in a sqlite message
the agent never sees.
"""
from __future__ import annotations

import importlib
import sys

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "test-key")
    monkeypatch.setenv("LOGIX_DB_PATH", str(tmp_path / "central.db"))
    monkeypatch.chdir(tmp_path)
    main = importlib.reload(sys.modules["main"]) if "main" in sys.modules \
        else importlib.import_module("main")
    with TestClient(main.app) as c:
        yield c, main


def _post(client, **kw):
    payload = {"timestamp": "2026-08-18T08:41:00", "event": "START",
               "session_id": "s1", "hostname": "LAB-09", "event_uid": "uid-1"}
    payload.update(kw)
    return client.post("/api/log", json=[payload], headers={"X-API-Key": "test-key"})


def test_job_metadata_is_stored(client):
    c, main = client
    r = _post(c, nama="Rani", tujuan="DFTB Parameterization",
              job_type="Simulation", job_id="258026")
    assert r.status_code == 200, r.text

    conn = main.get_db()
    try:
        row = conn.execute(
            "SELECT job_type, job_id FROM physical_log WHERE session_id='s1'"
        ).fetchone()
    finally:
        conn.close()
    assert (row["job_type"], row["job_id"]) == ("Simulation", "258026")


def test_agent_without_job_fields_still_posts(client):
    """The fields are nullable on both sides precisely so an agent that
    predates them keeps working."""
    c, _ = client
    r = _post(c, nama="Rani", tujuan="Maintenance")
    assert r.status_code == 200, r.text


def test_insert_column_and_value_lists_stay_in_step(client):
    """Arity is checked at the seam, so the next column added to
    BASE_COLUMNS fails with a message naming the cause instead of a 500."""
    c, main = client
    conn = main.get_db()
    try:
        cols = [r[1] for r in conn.execute("PRAGMA table_info(physical_log)").fetchall()]
    finally:
        conn.close()
    assert set(main.BASE_COLUMNS.keys()) <= set(cols)
    r = _post(c, nama="Rani", job_type="Analysis", job_id="1")
    assert r.status_code == 200, r.text
