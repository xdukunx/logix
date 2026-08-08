"""A whole lab, not one workstation.

Every test so far exercised a single device. A real deployment is twenty-odd
machines enrolling, heartbeating and being broadcast to at once, and the bugs
that only appear at that scale -- an invite reused on a second machine, two
devices claiming the same hostname, a per-device key that works on the wrong
box -- are exactly the ones that matter, because they are silent and they are
security-relevant.
"""
import importlib
import sys
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

LAB_SIZE = 24


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
    module.REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    module.ACTIVE_TOKENS.clear()
    module.HEARTBEATS.clear()
    module.PENDING_COMMANDS.clear()
    return module


def _login(client):
    token = client.post("/api/auth/dev-login").json()["token"]
    return {"Authorization": f"Bearer {token}"}


def _enrol(client, headers, hostname, display_name=None):
    invite = client.post("/api/enroll/invite", headers=headers, json={
        "category": "lab_workstation",
        "display_name": display_name or hostname,
        "hostname": hostname,
    })
    assert invite.status_code in (200, 201), invite.text
    code = invite.json()["invite_code"]
    res = client.post("/api/enroll", json={
        "invite_code": code, "hostname": hostname, "os": "windows",
        "agent_version": "1.1.1",
    })
    assert res.status_code in (200, 201), res.text
    return code, res.json()["api_key"]


def _fill_lab(client, headers, size=LAB_SIZE):
    keys = {}
    for i in range(1, size + 1):
        hostname = f"WS-{i:02d}"
        _, keys[hostname] = _enrol(client, headers, hostname, f"{hostname} - GPU-A100")
    return keys


def test_a_whole_lab_enrols_and_every_key_is_distinct(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        keys = _fill_lab(client, headers)
        devices = client.get("/api/devices", headers=headers).json()

    assert len(keys) == LAB_SIZE
    # A collision here would let one workstation act as another.
    assert len(set(keys.values())) == LAB_SIZE
    assert len({d["hostname"] for d in devices}) == LAB_SIZE
    # The registry must never hand a device key back over the API.
    assert all(not d.get("api_key") for d in devices)


def test_one_workstations_key_cannot_speak_for_another(monkeypatch, tmp_path):
    """Authentication is not authorization.

    verify_api_key only established that SOME enrolled device holds the key.
    Until assert_device_scope existed, WS-01's key could file heartbeats and
    session records as WS-02 -- so one workstation whose config.env a student
    could read was enough to forge data for the whole room.
    """
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        keys = _fill_lab(client, headers, size=3)

        # Enrolment itself stamps last_seen, so the question is whether the
        # forged beat MOVES it -- not whether it is set at all.
        before = {d["hostname"]: d["last_seen"]
                  for d in client.get("/api/devices", headers=headers).json()}

        beat = client.post("/api/heartbeat", headers={"X-API-Key": keys["WS-01"]},
                           json={"hostname": "WS-02", "status": "ACTIVE"})
        forged = client.post("/api/log", headers={"X-API-Key": keys["WS-01"]}, json=[{
            "timestamp": "2026-05-01T08:00:00", "event": "START", "hostname": "WS-03",
            "session_id": "forged", "nama": "Bukan Saya",
        }])
        after = {d["hostname"]: d["last_seen"]
                 for d in client.get("/api/devices", headers=headers).json()}
        spans = client.get("/api/sessions/spans", headers=headers).json()

    assert beat.status_code == 403, "a device key must not heartbeat for another host"
    assert forged.status_code == 403, "a device key must not log a session for another host"
    assert after["WS-02"] == before["WS-02"], "the forged beat must not revive WS-02"
    assert not any(s["session_id"] == "forged" for s in spans["sessions"])


def test_a_device_key_still_works_for_its_own_machine(monkeypatch, tmp_path):
    """The scope check must not break the ordinary path it wraps."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        keys = _fill_lab(client, headers, size=2)
        beat = client.post("/api/heartbeat", headers={"X-API-Key": keys["WS-01"]},
                           json={"hostname": "WS-01", "status": "ACTIVE"})
        logged = client.post("/api/log", headers={"X-API-Key": keys["WS-01"]}, json=[{
            "timestamp": "2026-05-01T08:00:00", "event": "START", "hostname": "WS-01",
            "session_id": "mine", "nama": "Dhana",
        }])
        devices = {d["hostname"]: d for d in client.get("/api/devices", headers=headers).json()}

    assert beat.status_code in (200, 201), beat.text
    assert logged.status_code in (200, 201), logged.text
    assert devices["WS-01"]["last_seen"] is not None


def test_hostname_scope_is_case_insensitive(monkeypatch, tmp_path):
    """Windows reports COMPUTERNAME in whatever case it feels like; rejecting
    ws-01 for a device enrolled as WS-01 would break real agents."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        keys = _fill_lab(client, headers, size=1)
        beat = client.post("/api/heartbeat", headers={"X-API-Key": keys["WS-01"]},
                           json={"hostname": "ws-01", "status": "ACTIVE"})
    assert beat.status_code in (200, 201), beat.text


def test_an_invite_is_single_use_across_a_busy_lab(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        code, first_key = _enrol(client, headers, "WS-01")
        # A second machine trying the same code -- a student copying an
        # install command, or an imaging script run twice.
        again = client.post("/api/enroll", json={
            "invite_code": code, "hostname": "WS-99", "os": "windows",
        })
    assert again.status_code >= 400, "an invite code must not enrol a second machine"


def test_hostname_pinning_survives_a_lab_full_of_similar_names(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        invite = client.post("/api/enroll/invite", headers=headers, json={
            "category": "lab_workstation", "display_name": "WS-07", "hostname": "WS-07",
        }).json()["invite_code"]
        # WS-07 and WS-17 differ by one character; the pin must not be fuzzy.
        wrong = client.post("/api/enroll", json={
            "invite_code": invite, "hostname": "WS-17", "os": "windows",
        })
    assert wrong.status_code >= 400


def test_a_lab_wide_broadcast_reaches_every_machine(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        keys = _fill_lab(client, headers)
        for hostname, key in keys.items():
            client.post("/api/heartbeat", headers={"X-API-Key": key},
                        json={"hostname": hostname, "status": "ACTIVE"})

        # hostname "ALL" is the fan-out form the Emergency broadcast dialog uses.
        res = client.post("/api/control/broadcast", headers=headers, json={
            "hostname": "ALL",
            "param": "Evakuasi: alarm kebakaran gedung C.",
            "reason": "Kebakaran",
        })
        assert res.status_code in (200, 201), res.text

        # Each machine must actually be handed the message on its next beat.
        delivered = 0
        for hostname, key in keys.items():
            beat = client.post("/api/heartbeat", headers={"X-API-Key": key},
                               json={"hostname": hostname, "status": "ACTIVE"}).json()
            commands = beat.get("commands") or []
            if any("broadcast" in str(c).lower() for c in commands):
                delivered += 1

    assert delivered == LAB_SIZE, f"only {delivered}/{LAB_SIZE} machines got the broadcast"


def test_summary_stays_consistent_with_the_table_for_a_full_lab(monkeypatch, tmp_path):
    """The three headline numbers on Riwayat are supposed to be derivable from
    the table beneath them. With one device that is hard to get wrong."""
    module = _load_main(monkeypatch, tmp_path)
    base = datetime.now() - timedelta(days=1)
    with TestClient(module.app) as client:
        headers = _login(client)
        for i in range(1, LAB_SIZE + 1):
            host = f"WS-{i:02d}"
            start = base + timedelta(minutes=i)
            client.post("/api/log", headers=headers, json=[{
                "timestamp": start.isoformat(), "event": "START", "hostname": host,
                "session_id": f"s{i}", "nama": f"Mahasiswa {i}", "nim": f"1622210{i:02d}",
                "tujuan": "Komputasi DFT", "session_type": "SSH",
            }, {
                "timestamp": (start + timedelta(hours=1)).isoformat(), "event": "END",
                "hostname": host, "session_id": f"s{i}",
            }])

        summary = client.get("/api/sessions/summary", headers=headers).json()
        spans = client.get("/api/sessions/spans", headers=headers,
                           params={"limit": 500}).json()

    assert summary["sessions"] == LAB_SIZE == spans["total"]
    assert summary["users"] == LAB_SIZE
    assert summary["hours"] == pytest.approx(LAB_SIZE, abs=0.2)
    manual = sum(s["duration_seconds"] or 0 for s in spans["sessions"]) / 3600
    assert summary["hours"] == pytest.approx(round(manual, 1), abs=0.2)


def test_the_device_list_is_one_query_not_one_per_device(monkeypatch, tmp_path):
    """The Devices tab polls. An N+1 that is invisible with one workstation
    becomes 24 round-trips a poll with a real lab."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _fill_lab(client, headers)

        real_connect = module.sqlite3.connect
        calls = {"n": 0}

        def counting_connect(*args, **kwargs):
            calls["n"] += 1
            return real_connect(*args, **kwargs)

        module.sqlite3.connect = counting_connect
        try:
            res = client.get("/api/devices", headers=headers)
        finally:
            module.sqlite3.connect = real_connect

    assert res.status_code == 200
    assert len(res.json()) == LAB_SIZE
    # Generous ceiling -- this is guarding against per-device growth, not
    # pinning an exact implementation.
    assert calls["n"] <= 4, f"listing {LAB_SIZE} devices opened {calls['n']} connections"
