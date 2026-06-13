"""Tests for the GSheet redaction gate and upsert logic.

Per docs/CLAUDE_CODE_HANDOFF.md, the gating requirement is: no client IP and no
raw NIM may ever appear in redact()'s output. These tests must pass before any
live Google sync is shipped. No third-party / network dependency here.
"""
import json

import pytest

import gsheet_sync as gs


# A deliberately hostile row: PII is sprinkled across many fields, including a
# free-text note that embeds the client IP (as the SSH hook actually does).
HOSTILE_ROW = {
    "nama": "Budi Santoso",
    "nim": "20231234567",
    "client_ip": "192.168.40.12",
    "username": "budi",
    "windows_user": "MINDLAB\\budi",
    "hostname": "mindlab-01",
    "keterangan": "SSH login from 192.168.40.12",
    "tujuan": "simulasi DFT untuk NIM 20231234567",
    "raw_json": json.dumps({"ssh_connection": "192.168.40.12 51000 10.0.0.1 22", "nim": "20231234567"}),
    "tipe": "SSH",
    "start_ts": "2026-06-13T09:00:00+07:00",
    "end_ts": "2026-06-13T10:30:00+07:00",
}

IP = "192.168.40.12"
NIM = "20231234567"


@pytest.mark.parametrize("mode", gs.REDACT_MODES)
def test_redact_never_emits_ip_or_nim(mode):
    out = gs.redact(HOSTILE_ROW, mode=mode, salt="pepper")
    blob = json.dumps(out)
    assert IP not in blob, f"client IP leaked in mode={mode}: {out}"
    assert NIM not in blob, f"raw NIM leaked in mode={mode}: {out}"
    # Also: the second IP octet sequence from raw_json must not survive.
    assert "10.0.0.1" not in blob


@pytest.mark.parametrize("mode", gs.REDACT_MODES)
def test_redact_output_is_whitelist_only(mode):
    out = gs.redact(HOSTILE_ROW, mode=mode, salt="pepper")
    assert set(out.keys()) == set(gs.SAFE_FIELDS)
    # Forbidden keys must be entirely absent.
    for forbidden in ("nim", "client_ip", "keterangan", "raw_json", "hostname", "username"):
        assert forbidden not in out


def test_redact_keeps_audit_signal():
    out = gs.redact(HOSTILE_ROW, mode="initials", salt="")
    assert out["date"] == "2026-06-13"
    assert out["session_type"] == "SSH"
    assert out["hours"] == pytest.approx(1.5)
    assert out["member"] == "B.S."


def test_member_token_is_stable_and_one_way():
    # Same input -> same token across calls (required for stable sheet keys).
    assert gs.member_token("Budi Santoso", "code", "pepper") == gs.member_token("Budi Santoso", "code", "pepper")
    assert gs.member_token("Budi Santoso", "hash", "pepper") == gs.member_token("Budi Santoso", "hash", "pepper")
    # Different people -> different tokens.
    assert gs.member_token("Budi Santoso", "code", "pepper") != gs.member_token("Ani Wijaya", "code", "pepper")
    # The hashed token does not contain the raw name.
    tok = gs.member_token("Budi Santoso", "hash", "pepper")
    assert "budi" not in tok.lower() and "santoso" not in tok.lower()
    # Salt matters (different salt -> different token).
    assert gs.member_token("Budi Santoso", "hash", "a") != gs.member_token("Budi Santoso", "hash", "b")


def test_member_token_initials_and_empty():
    assert gs.member_token("Ani Wijaya", "initials") == "A.W."
    assert gs.member_token("", "initials") == "ANON"
    assert gs.member_token("   ", "hash", "x") == "ANON"


def test_unknown_mode_raises():
    with pytest.raises(ValueError):
        gs.member_token("X", "rot13", "")


def test_aggregate_sums_hours_per_member_type_day():
    redacted = [
        {"date": "2026-06-13", "member": "B.S.", "session_type": "SSH", "hours": 1.5},
        {"date": "2026-06-13", "member": "B.S.", "session_type": "SSH", "hours": 0.5},
        {"date": "2026-06-13", "member": "B.S.", "session_type": "PHYSICAL", "hours": 2.0},
        {"date": "2026-06-14", "member": "A.W.", "session_type": "SSH", "hours": 3.0},
    ]
    agg = gs.aggregate(redacted)
    by_key = {r["key"]: r["hours"] for r in agg}
    assert by_key["2026-06-13|B.S.|SSH"] == pytest.approx(2.0)
    assert by_key["2026-06-13|B.S.|PHYSICAL"] == pytest.approx(2.0)
    assert by_key["2026-06-14|A.W.|SSH"] == pytest.approx(3.0)
    assert len(agg) == 3  # three distinct (date, member, type) buckets


def test_upsert_is_idempotent():
    desired = gs.aggregate([
        {"date": "2026-06-13", "member": "B.S.", "session_type": "SSH", "hours": 2.0},
        {"date": "2026-06-14", "member": "A.W.", "session_type": "SSH", "hours": 3.0},
    ])
    first = gs.merge_rows([], desired)
    second = gs.merge_rows(first, desired)        # re-run: must not duplicate
    assert first == second
    keys = [r["key"] for r in second]
    assert len(keys) == len(set(keys)), "duplicate rows produced"


def test_upsert_updates_in_place_not_append():
    existing = gs.merge_rows([], gs.aggregate(
        [{"date": "2026-06-13", "member": "B.S.", "session_type": "SSH", "hours": 1.0}]))
    updated = gs.merge_rows(existing, gs.aggregate(
        [{"date": "2026-06-13", "member": "B.S.", "session_type": "SSH", "hours": 5.0}]))
    assert len(updated) == 1
    assert updated[0]["hours"] == pytest.approx(5.0)


def test_module_imports_without_google_dep():
    # The pure core must be usable with no gspread/google-auth installed.
    assert not hasattr(gs, "gspread")


def test_sync_reads_db_readonly(tmp_path, monkeypatch):
    # A missing DB must raise (and never create/modify a file).
    missing = tmp_path / "nope.db"
    with pytest.raises(FileNotFoundError):
        gs.read_rows(missing)
    assert not missing.exists()


def test_dry_run_against_synthetic_db(tmp_path, monkeypatch, capsys):
    """End-to-end: --dry-run on a real (synthetic) DB exits 0 and leaks no PII."""
    db = tmp_path / "synthetic.db"
    monkeypatch.setenv("LOGIX_DB", str(db))      # env wins in paths.default_db()
    import log_physical as lp
    lp.main(["--event", "START", "--session-type", "SSH", "--nama", "Budi Santoso",
             "--nim", "20231234567", "--client-ip", "192.168.40.12", "--session-id", "s1"])
    lp.main(["--event", "END", "--session-type", "SSH", "--session-id", "s1"])
    rc = gs.main(["--dry-run"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "DRY RUN" in out
    assert "192.168.40.12" not in out and "20231234567" not in out
    assert "B.S." in out  # redacted member token is present


def test_check_and_sync_unconfigured_returns_1(tmp_path, monkeypatch):
    """Without creds/sheet id, --check / sync refuse cleanly (DB untouched)."""
    db = tmp_path / "synthetic.db"
    db.write_bytes(b"")  # presence only; code must bail before reading it
    monkeypatch.setenv("LOGIX_DB", str(db))
    for var in ("LOGIX_GSHEET_ID", "LOGIX_GSHEET_CREDS"):
        monkeypatch.delenv(var, raising=False)
    # paths also consults config.env; force empty resolution via monkeypatch on get
    monkeypatch.setattr(gs.paths, "get", lambda name, default="":
                        {"LOGIX_REDACT_MODE": "initials"}.get(name, default))
    assert gs.main(["--check"]) == 1
    assert gs.main([]) == 1
