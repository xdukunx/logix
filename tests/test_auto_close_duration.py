"""AUTO_CLOSE must not bill machine downtime to the person (Phase 2B).

Duration is not stored. logbook_report.py derives it by subtracting the
START row's timestamp from the END row's, so whatever timestamp the closing
event carries IS the session length as far as every report is concerned.

That made the automatic closers wrong in a way nothing detected: both dated
the close at the moment they NOTICED, not at the moment the session
plausibly ended. A workstation locked at 07:00 Monday and unlocked at 08:00
Tuesday produced a 25-hour session from an 8-hour cap; a session left open
across a shutdown was billed for every hour the machine spent powered off.

The fix is in windows/logbook_common.ps1 (the closers now pass -EndTime),
but the invariant belongs here, because this is the layer that turns two
timestamps into the number a human reads.
"""
from __future__ import annotations

import importlib
import sys
from datetime import datetime, timedelta

import pytest


def _lp():
    if "log_physical" in sys.modules:
        return importlib.reload(sys.modules["log_physical"])
    return importlib.import_module("log_physical")


def _report():
    if "logbook_report" in sys.modules:
        return importlib.reload(sys.modules["logbook_report"])
    return importlib.import_module("logbook_report")


def _event(lp, con, event, session_id, when: datetime):
    """Insert one event dated exactly `when` -- the same route the PowerShell
    bridge takes, which writes a payload file carrying an explicit timestamp
    that payload_from_args prefers over now."""
    ns = lp.parse_args(["--event", event, "--hostname", "LAB-03",
                        "--session-id", session_id])
    payload = lp.payload_from_args(ns)
    payload["timestamp"] = when.isoformat()
    lp.insert_event(con, payload)


@pytest.fixture
def device(monkeypatch, tmp_path):
    db_path = tmp_path / "device.db"
    monkeypatch.setenv("LOGIX_DB", str(db_path))
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "local_only")
    lp = _lp()
    con = lp.connect(db_path)
    lp.migrate(con)
    yield lp, con
    con.close()


# ---- the bridge honours an explicit timestamp ---------------------------

def test_explicit_timestamp_survives_into_the_row(device):
    """Everything below depends on this: if payload_from_args ignored the
    supplied timestamp and stamped now(), the PowerShell fix would be
    silently inert."""
    lp, con = device
    when = datetime(2026, 8, 10, 7, 0, 0)
    _event(lp, con, "START", "s1", when)

    row = con.execute(
        "SELECT timestamp FROM physical_log WHERE session_id='s1'").fetchone()
    assert str(row[0]).startswith("2026-08-10T07:00:00")


# ---- the invariant ------------------------------------------------------

def test_overnight_lock_does_not_become_a_25_hour_session(device):
    """The regression, stated as the product rule it broke: an 8-hour cap
    must produce an 8-hour session, whatever time the machine was unlocked."""
    lp, con = device
    start = datetime(2026, 8, 10, 7, 0, 0)
    cap = timedelta(hours=8)

    _event(lp, con, "START", "capped", start)
    # What the closers do now: start + cap, NOT now.
    _event(lp, con, "AUTO_CLOSE", "capped", start + cap)

    rep = _report()
    rows = con.execute(
        "SELECT event, timestamp FROM physical_log "
        "WHERE session_id='capped' ORDER BY id").fetchall()
    dur = rep.fmt_duration(str(rows[0][1]), str(rows[1][1]))

    # Exact prefix, not a substring test: "2" is in "25j" too, and a loose
    # assertion here would pass for the very bug this file exists to catch.
    assert dur.startswith("8j 0m"), f"expected an 8-hour session, got {dur!r}"


def test_shutdown_gap_is_not_billed_to_the_user(device):
    """Reboot case. The session ended at or before the machine went down;
    dating the close at the next boot bounds it without inventing precision
    we do not have. Dating it at "now" would charge the user for however
    long the workstation sat powered off."""
    lp, con = device
    start = datetime(2026, 8, 10, 7, 0, 0)
    boot = datetime(2026, 8, 10, 9, 30, 0)     # machine came back 2.5h later
    noticed = datetime(2026, 8, 11, 8, 0, 0)   # nobody signed in until Tuesday

    _event(lp, con, "START", "reboot", start)
    _event(lp, con, "AUTO_CLOSE", "reboot", boot)

    rep = _report()
    rows = con.execute(
        "SELECT timestamp FROM physical_log "
        "WHERE session_id='reboot' ORDER BY id").fetchall()
    dur = rep.fmt_duration(str(rows[0][0]), str(rows[1][0]))

    naive = rep.fmt_duration(start.isoformat(), noticed.isoformat())
    assert naive.startswith("25j"), "sanity: closing at discovery really is 25h"
    assert dur.startswith("2j 30m"), f"expected 2h30m, got {dur!r}"


def test_a_normal_manual_close_is_still_dated_now(device):
    """The fix must not leak into the ordinary path. Someone pressing
    SELESAI really is ending the session at that moment, and nothing should
    be clamped or back-dated for them."""
    lp, con = device
    start = datetime(2026, 8, 10, 7, 0, 0)
    _event(lp, con, "START", "manual", start)

    ns = lp.parse_args(["--event", "END", "--hostname", "LAB-03",
                        "--session-id", "manual"])
    payload = lp.payload_from_args(ns)   # no timestamp override at all
    lp.insert_event(con, payload)

    row = con.execute(
        "SELECT timestamp FROM physical_log "
        "WHERE session_id='manual' AND event='END'").fetchone()
    # Not the back-dated start: it was stamped when the event was created.
    assert not str(row[0]).startswith("2026-08-10T07:00:00")


def test_close_never_predates_start(device):
    """Guard on the guard. The PowerShell side clamps an EndTime earlier
    than start_time, because a clock change or a caller's own arithmetic
    must not be able to mint a negative duration."""
    lp, con = device
    start = datetime(2026, 8, 10, 7, 0, 0)
    _event(lp, con, "START", "clamp", start)
    _event(lp, con, "AUTO_CLOSE", "clamp", start)  # clamped to start

    rep = _report()
    rows = con.execute(
        "SELECT timestamp FROM physical_log "
        "WHERE session_id='clamp' ORDER BY id").fetchall()
    dur = rep.fmt_duration(str(rows[0][0]), str(rows[1][0]))

    assert not dur.strip().startswith("-"), f"negative duration rendered: {dur!r}"
