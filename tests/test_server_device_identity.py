"""One machine must be one registry row.

Reported as: registering a new PC produced TWO devices on the dashboard -- one
under the machine's default name and one under the name typed into the
installer. Two independent causes, both covered here:

1. Enrolment discarded the typed device name. install.py, logbook_setup.ps1 and
   install_logbook_tasks.ps1 all collected it and none of them sent it, so the
   row was created under the bare hostname and the real name only turned up on
   a later heartbeat.

2. Hostname lookups were case-sensitive (`WHERE hostname = ?` in SQLite). The
   enrolment paths did not agree on where the hostname came from --
   socket.gethostname() in install.py versus $env:COMPUTERNAME in PowerShell --
   so two spellings of one name produced two rows.

Plus the one-time merge for databases that already have duplicates.
"""
import importlib
import sys
import uuid
from datetime import datetime

from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "")
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", "")
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


def _login(client):
    return {"Authorization": f"Bearer {client.post('/api/auth/dev-login').json()['token']}"}


def _invite(client, headers):
    return client.post("/api/enroll/invite", json={"category": "lab_workstation"},
                       headers=headers).json()["invite_code"]


def test_enrolment_uses_the_typed_device_name(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/enroll", json={"invite_code": _invite(client, headers),
                                         "hostname": "DESKTOP-8H2K1L",
                                         "device_name": "WS-07"})
        devices = client.get("/api/devices", headers=headers).json()
    assert len(devices) == 1
    assert devices[0]["hostname"] == "DESKTOP-8H2K1L"
    # The name the operator typed, from the moment the row exists -- not the
    # raw hostname that used to sit here until the first heartbeat.
    assert devices[0]["display_name"] == "WS-07"


def test_an_invite_display_name_still_outranks_the_typed_one(monkeypatch, tmp_path):
    """An admin who names the device on the invite is being deliberate; the
    workstation-side box is the fallback, not an override."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        code = client.post("/api/enroll/invite",
                           json={"category": "lab_workstation", "display_name": "WS-01 - GPU"},
                           headers=headers).json()["invite_code"]
        client.post("/api/enroll", json={"invite_code": code, "hostname": "DESKTOP-8H2K1L",
                                         "device_name": "laptop budi"})
        devices = client.get("/api/devices", headers=headers).json()
    assert devices[0]["display_name"] == "WS-01 - GPU"


def test_enrolment_then_a_differently_cased_heartbeat_is_one_device(monkeypatch, tmp_path):
    """install.py enrols as socket.gethostname() ("desktop-8h2k1l"); the agent
    heartbeats as $env:COMPUTERNAME ("DESKTOP-8H2K1L")."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/enroll", json={"invite_code": _invite(client, headers),
                                         "hostname": "desktop-8h2k1l",
                                         "device_name": "WS-07"})
        client.post("/api/heartbeat", json={"hostname": "DESKTOP-8H2K1L", "status": "ACTIVE",
                                            "device_name": "WS-07"})
        devices = client.get("/api/devices", headers=headers).json()
    assert len(devices) == 1, [d["hostname"] for d in devices]
    assert devices[0]["display_name"] == "WS-07"


def test_rename_and_control_also_match_case_insensitively(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-01", "status": "ACTIVE"})

        res = client.put("/api/devices/rename",
                         json={"hostname": "lab-pc-01", "display_name": "WS-01"}, headers=headers)
        assert res.status_code == 200
        assert client.get("/api/devices", headers=headers).json()[0]["display_name"] == "WS-01"

        assert client.post("/api/control/lock", json={"hostname": "lab-pc-01"},
                           headers=headers).status_code == 200


def test_startup_merges_pre_existing_case_duplicates(monkeypatch, tmp_path):
    """The one-time cleanup for a database that already has the split rows."""
    module = _load_main(monkeypatch, tmp_path)

    # Build the exact shape the bug produced: an enrolled row under the
    # lowercase DNS name, and a heartbeat-created row under the uppercase
    # NetBIOS name carrying the name the admin actually typed.
    with TestClient(module.app):
        pass  # runs init_control_tables so the schema exists

    conn = module.get_db()
    now = datetime.now().isoformat()
    conn.execute("DELETE FROM devices")
    # Put the schema back the way it was BEFORE the fix: the case-sensitive
    # unique index is what allowed the two rows to coexist in the first place,
    # and the NOCASE one that replaced it rejects the insert outright.
    conn.execute("DROP INDEX IF EXISTS idx_devices_hostname_nocase")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_hostname ON devices(hostname)")
    enrolled_id, drifted_id = str(uuid.uuid4()), str(uuid.uuid4())
    conn.execute(
        "INSERT INTO devices (device_id, hostname, display_name, category, api_key, enrolled_at, "
        "last_seen, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (enrolled_id, "desktop-8h2k1l", "desktop-8h2k1l", "lab_workstation", "key-abc", now,
         "2026-08-20T09:00:00", now, now),
    )
    conn.execute(
        "INSERT INTO devices (device_id, hostname, display_name, category, last_seen, "
        "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (drifted_id, "DESKTOP-8H2K1L", "WS-07", "custom", "2026-08-20T11:00:00", now, now),
    )
    conn.commit()
    conn.close()

    module.init_control_tables()

    conn = module.get_db()
    rows = conn.execute("SELECT * FROM devices").fetchall()
    conn.close()
    assert len(rows) == 1
    survivor = dict(rows[0])
    # The enrolled row survives (it holds the credential the agent is using)...
    assert survivor["device_id"] == enrolled_id
    assert survivor["api_key"] == "key-abc"
    assert survivor["category"] == "lab_workstation"
    # ...but takes the real name and the newer last_seen off the row it absorbed.
    assert survivor["display_name"] == "WS-07"
    assert survivor["last_seen"] == "2026-08-20T11:00:00"


def test_the_unique_index_is_case_insensitive_after_migration(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app):
        pass
    conn = module.get_db()
    indexes = {r["name"] for r in conn.execute("PRAGMA index_list(devices)")}
    conn.close()
    assert "idx_devices_hostname_nocase" in indexes
    assert "idx_devices_hostname" not in indexes
