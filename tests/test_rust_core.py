"""Parity between the native core (agent/, logix.exe) and logix/log_physical.py.

The Windows client now records sessions and syncs them through logix.exe
because it costs a few milliseconds and ~3 MB where starting Python cost
~100 ms and ~24 MB. That swap is only safe if the two cores are
interchangeable: same rows in the same table, same sync_state.json, same
answers from --sync-status, same refusal to send anything under local_only.
These tests run identical scenarios through both and compare.

Skipped when the binary has not been built (cargo build --release in agent/),
or point LOGIX_RUST_BIN at one.
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from test_sync_integration import live_server  # noqa: F401  (fixture)

REPO = Path(__file__).resolve().parent.parent
RUST_BIN = Path(os.environ.get("LOGIX_RUST_BIN") or REPO / "agent" / "target" / "release" / ("logix.exe" if os.name == "nt" else "logix"))
PY_CORE = REPO / "logix" / "log_physical.py"

pytestmark = pytest.mark.skipif(not RUST_BIN.exists(), reason=f"native core not built: {RUST_BIN}")


def _env(home: Path, **extra) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("LOGIX_") and k != "LOGBOOK_SESSION_JSON"}
    env.update({
        "LOGIX_HOME": str(home),
        "LOGIX_CONFIG": str(home / "config.env"),
        "LOGIX_DEVICE_IDENTITY_FILE": str(home / "device.json"),
        "LOGBOOK_SESSION_JSON": str(home / "session.json"),
        "PYTHONIOENCODING": "utf-8",
    })
    env.update({k: str(v) for k, v in extra.items()})
    return env


def _run(core: str, home: Path, *args, **env):
    cmd = [str(RUST_BIN), *args] if core == "rust" else [sys.executable, str(PY_CORE), *args]
    return subprocess.run(cmd, env=_env(home, **env), capture_output=True, text=True, encoding="utf-8", timeout=60)


def _rows(db: Path, mask_minted: bool = True):
    """Rows in id order. An auto-close row's event_uid is minted fresh by
    design (see rekey_auto_close_rows), so it is compared for shape, not value."""
    con = sqlite3.connect(db)
    con.row_factory = sqlite3.Row
    try:
        rows = [dict(r) for r in con.execute("SELECT * FROM physical_log ORDER BY id")]
    finally:
        con.close()
    if mask_minted:
        for r in rows:
            if r["source"] == "auto_close_before_new_start":
                assert len(r["event_uid"]) == 32
                r["event_uid"] = "<minted>"
    return rows


def _payload(home: Path, name: str, **fields) -> str:
    p = home / f"{name}.json"
    p.write_text(json.dumps(fields, ensure_ascii=False), encoding="utf-8-sig")
    return str(p)


SCENARIO = [
    dict(event="START", session_id="win-a", session_type="Physical", timestamp="2026-10-01T08:00:00+07:00",
         event_uid="uid-1", nama="Ayu Lestari", nim="X1", tujuan="Praktikum", username="lab", hostname="WS-01",
         anydesk_detected=0, job_type="", job_id=""),
    # A second START while win-a is still open: both cores must auto-close it.
    dict(event="START", session_id="win-b", session_type="AnyDesk", timestamp="2026-10-01T09:00:00+07:00",
         event_uid="uid-2", nama="Budi Ś", nim="X2", tujuan="Riset", keterangan="DFT \"run\"", username="lab",
         hostname="WS-01", anydesk_detected=True),
    dict(event="END", session_id="win-b", session_type="AnyDesk", timestamp="2026-10-01T10:30:00+07:00",
         event_uid="uid-3", username="lab", hostname="WS-01"),
]


def _play(core: str, home: Path):
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.env").write_text("LOGIX_PRIVACY_MODE=local_only\n", encoding="utf-8")
    for i, ev in enumerate(SCENARIO):
        r = _run(core, home, "--json-file", _payload(home, f"e{i}", **ev))
        assert r.returncode == 0, (core, r.stdout, r.stderr)
    return _rows(home / "logix.db")


def test_both_cores_write_identical_rows(tmp_path):
    py = _play("python", tmp_path / "py")
    rs = _play("rust", tmp_path / "rs")
    assert len(py) == 4  # 3 events + the auto-close of win-a
    assert [r["event"] for r in rs] == ["START", "AUTO_FINISH", "START", "END"]
    assert rs == py


def test_close_open_and_repair_active_match(tmp_path):
    results = {}
    for core in ("python", "rust"):
        home = tmp_path / core
        _play(core, home)
        # An open START with blank identity, then session.json carrying it.
        r = _run(core, home, "--json-file", _payload(home, "blank", event="START", session_id="win-c",
                                                       session_type="Physical", timestamp="2026-10-01T11:00:00+07:00",
                                                       event_uid="uid-4", hostname="WS-01", username="lab"))
        assert r.returncode == 0, r.stderr
        (home / "session.json").write_text(json.dumps({
            "session_id": "win-c", "start_time": "2026-10-01T11:00:00+07:00", "session_type": "Physical",
            "nama": "Citra", "nim": "X3", "tujuan": "Tugas", "hostname": "WS-01", "username": "lab",
        }), encoding="utf-8-sig")
        r = _run(core, home, "--repair-active")
        assert r.returncode == 0 and "OK repaired active rows: 1" in r.stdout, (core, r.stdout, r.stderr)
        r = _run(core, home, "--close-open", "--json-file", _payload(home, "close", event="AUTO_CLOSE",
                                                                    timestamp="2026-10-01T12:00:00+07:00",
                                                                    event_uid="uid-5", hostname="WS-01", username="lab"))
        assert r.returncode == 0 and "OK closed open workstation sessions: 1" in r.stdout, (core, r.stdout, r.stderr)
        results[core] = _rows(home / "logix.db")
    assert results["rust"] == results["python"]
    assert results["rust"][-1]["event"] == "AUTO_CLOSE" and results["rust"][-1]["nama"] == "Citra"


def test_local_only_never_sends(tmp_path, live_server):  # noqa: F811
    home = tmp_path / "rs"
    _play("rust", home)
    r = _run("rust", home, "--sync-to-server", LOGIX_SERVER_URL=live_server.base_url, LOGIX_SERVER_API_KEY="dev-test-key")
    assert r.returncode == 0 and "OK synced logs to server: 0" in r.stdout
    assert "Sync skipped" in r.stderr
    con = sqlite3.connect(live_server.module.DB_PATH)
    try:
        sent = con.execute("SELECT COUNT(*) FROM physical_log").fetchone()[0]
    except sqlite3.OperationalError:
        sent = 0
    finally:
        con.close()
    assert sent == 0


def test_full_sync_delivers_once_and_status_agrees(tmp_path, live_server):  # noqa: F811
    home = tmp_path / "rs"
    _play("rust", home)
    env = dict(LOGIX_SERVER_URL=live_server.base_url, LOGIX_SERVER_API_KEY="dev-test-key",
               LOGIX_PRIVACY_MODE="admin_full_sync")
    r = _run("rust", home, "--sync-to-server", **env)
    assert r.returncode == 0 and "OK synced logs to server: 4" in r.stdout, r.stderr
    assert all(row["synced"] == 1 for row in _rows(home / "logix.db"))
    # Nothing left: a second run sends nothing and the server still has 4.
    r = _run("rust", home, "--sync-to-server", **env)
    assert "OK synced logs to server: 0" in r.stdout
    con = sqlite3.connect(live_server.module.DB_PATH)
    try:
        assert con.execute("SELECT COUNT(*) FROM physical_log").fetchone()[0] == 4
        names = {n for (n,) in con.execute("SELECT nama FROM physical_log")}
    finally:
        con.close()
    assert "Budi Ś" in names  # non-ASCII survives the trip
    st_rs = json.loads(_run("rust", home, "--sync-status", **env).stdout)
    st_py = json.loads(_run("python", home, "--sync-status", **env).stdout)
    assert st_rs == st_py
    assert st_rs["connection_state"] == "connected" and st_rs["pending_count"] == 0


def test_failure_classes_match_python(tmp_path, live_server):  # noqa: F811
    home = tmp_path / "rs"
    _play("rust", home)
    base = dict(LOGIX_PRIVACY_MODE="admin_full_sync")
    # Nothing listening -> network.
    r = _run("rust", home, "--json-file", _payload(home, "x", event="UNLOCK", event_uid="uid-x", hostname="WS-01"),
             LOGIX_SERVER_URL="http://127.0.0.1:9", LOGIX_SERVER_API_KEY="k", **base)
    assert r.returncode == 0  # the event itself is recorded regardless
    st = json.loads(_run("python", home, "--sync-status", LOGIX_SERVER_URL="http://127.0.0.1:9", **base).stdout)
    assert st["connection_state"] == "offline" and st["last_error_class"] == "network"
    # Server answers 401 -> auth, and the rows stay unsynced.
    _run("rust", home, "--sync-to-server", LOGIX_SERVER_URL=live_server.base_url, LOGIX_SERVER_API_KEY="wrong", **base)
    st = json.loads(_run("rust", home, "--sync-status", LOGIX_SERVER_URL=live_server.base_url, **base).stdout)
    assert st["last_error_class"] == "auth" and st["pending_count"] == 5


def test_bad_privacy_mode_is_an_error_not_a_guess(tmp_path):
    home = tmp_path / "rs"
    _play("rust", home)
    r = _run("rust", home, "--sync-to-server", LOGIX_SERVER_URL="http://127.0.0.1:9", LOGIX_PRIVACY_MODE="admin_ful_sync")
    assert r.returncode == 2 and "LOGIX_PRIVACY_MODE" in r.stderr


def test_config_env_with_bom_and_export(tmp_path, live_server):  # noqa: F811
    home = tmp_path / "rs"
    _play("rust", home)
    (home / "config.env").write_text(
        f"LOGIX_PRIVACY_MODE=admin_full_sync\nexport LOGIX_SERVER_URL=\"{live_server.base_url}\"\nLOGIX_SERVER_API_KEY='dev-test-key'\n",
        encoding="utf-8-sig",
    )
    r = _run("rust", home, "--sync-to-server")
    assert "OK synced logs to server: 4" in r.stdout, r.stderr


@pytest.mark.parametrize("core", ["python", "rust"])
def test_auto_close_rows_get_their_own_uid_and_old_ones_are_repaired(core, tmp_path):
    home = tmp_path / core
    rows = _play(core, home)
    uids = [r["event_uid"] for r in _rows(home / "logix.db", mask_minted=False)]
    assert len(set(uids)) == len(uids), "every row must be its own event to the server"
    # Recreate the old bug: an auto-close carrying the next START's uid, already synced.
    con = sqlite3.connect(home / "logix.db")
    con.execute("UPDATE physical_log SET event_uid='uid-2', synced=1 WHERE source='auto_close_before_new_start'")
    con.commit()
    con.close()
    assert _run(core, home, "--migrate").returncode == 0
    fixed = [r for r in _rows(home / "logix.db", mask_minted=False) if r["source"] == "auto_close_before_new_start"]
    assert fixed[0]["event_uid"] != "uid-2" and fixed[0]["synced"] == 0
    again = _rows(home / "logix.db", mask_minted=False)
    assert _run(core, home, "--migrate").returncode == 0
    assert _rows(home / "logix.db", mask_minted=False) == again  # idempotent
