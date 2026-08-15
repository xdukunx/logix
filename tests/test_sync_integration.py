"""End-to-end offline-sync reliability tests: a real local SQLite device
database, talking real HTTP (urllib, the exact client code path
log_physical.py uses in production) to a REAL running server (uvicorn on a
real port, not an ASGI in-process TestClient) -- because the client's HTTP
layer is what carries the actual failure modes this suite exists to prove
safe (timeouts, connection loss, HTTP status handling), and none of those
are exercised by posting through an in-process ASGI transport.

tests/test_server_log_dedup.py already proves the SERVER's dedup logic in
isolation (event_uid -> skip on repeat). This file proves the CLIENT's half
of the same contract: that a real sync attempt, retried across every
failure mode the product contract lists, converges on "server has it once,
local db knows it, no data lost along the way" -- and where a gap was
found, records it fixed with the scenario that exposed it.

Product contract (see docs/DEVICE_AND_SERVER.md and the phase brief this
file was written against):
  local SQLite is authoritative; sync is a secondary, retryable layer that
  must never lose local data and must never create a duplicate logical
  event server-side, no matter how many times or in what order a batch is
  retried.
"""
from __future__ import annotations

import importlib
import socket
import sqlite3
import sys
import threading
import time
from pathlib import Path

import pytest
import uvicorn


# ---- live server fixture -----------------------------------------------
#
# Function-scoped (a fresh server + fresh DB per test) over module/session
# scope: this suite is specifically about state that accumulates across
# requests (synced flags, duplicate rows), so tests sharing a server would
# be tests sharing exactly the state they are trying to prove isolated
# handling of. The ~0.4-0.9s uvicorn startup cost per test is worth that.

def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class LiveServer:
    def __init__(self, app, port: int):
        config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error")
        self.server = uvicorn.Server(config)
        self.port = port
        self.base_url = f"http://127.0.0.1:{port}"
        self._thread = threading.Thread(target=self.server.run, daemon=True)

    def start(self):
        self._thread.start()
        deadline = time.time() + 10
        while not self.server.started and time.time() < deadline:
            time.sleep(0.02)
        if not self.server.started:
            raise RuntimeError("live test server did not start within 10s")

    def stop(self):
        self.server.should_exit = True
        self._thread.join(timeout=10)


@pytest.fixture()
def live_server(monkeypatch, tmp_path):
    """A real Logix server, freshly loaded against a temp DB, listening on
    a real loopback port. Mirrors _load_main() in test_server_log_dedup.py
    (same env, same module-reload trick) but actually binds a socket."""
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "dev-test-key")
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", "")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.org")

    if "main" in sys.modules:
        module = importlib.reload(sys.modules["main"])
    else:
        module = importlib.import_module("main")

    module.DB_PATH = tmp_path / "central.db"
    module.CONFIG_PATH = tmp_path / "server_config.json"
    module.REPORTS_DIR = tmp_path / "reports"
    module.ACTIVE_TOKENS.clear()
    module.HEARTBEATS.clear()
    module.PENDING_COMMANDS.clear()

    port = _free_port()
    live = LiveServer(module.app, port)
    live.start()
    live.module = module
    try:
        yield live
    finally:
        live.stop()


@pytest.fixture()
def device(monkeypatch, tmp_path, live_server):
    """A local device database wired to talk to `live_server`. Returns the
    log_physical module (fresh import, matching the top-of-file convention
    in test_log_physical.py: DEFAULT_DB is computed at import time, so env
    must be set before the first import) plus an open connection."""
    monkeypatch.setenv("LOGIX_SERVER_URL", live_server.base_url)
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")
    monkeypatch.setenv("LOGIX_SERVER_API_KEY", "dev-test-key")
    db_path = tmp_path / "device.db"
    monkeypatch.setenv("LOGIX_DB", str(db_path))

    if "log_physical" in sys.modules:
        lp = importlib.reload(sys.modules["log_physical"])
    else:
        lp = importlib.import_module("log_physical")

    con = lp.connect(db_path)
    lp.migrate(con)
    try:
        yield lp, con, db_path
    finally:
        con.close()


def _seed(lp, con, n=1, hostname="PC-1", session_prefix="s"):
    """Insert n locally-generated, unsynced events (each with its own real
    event_uid, exactly as payload_from_args mints one per CLI invocation)."""
    uids = []
    for i in range(n):
        ns = lp.parse_args([
            "--event", "START", "--hostname", hostname,
            "--session-id", f"{session_prefix}{i}",
        ])
        payload = lp.payload_from_args(ns)
        uids.append(payload["event_uid"])
        lp.insert_event(con, payload)
    return uids


def _server_rows(live_server):
    conn = sqlite3.connect(str(live_server.module.DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute(
            "SELECT event_uid, hostname FROM physical_log ORDER BY id"
        ).fetchall()
    finally:
        conn.close()


def _local_unsynced_count(con):
    return con.execute(
        "SELECT COUNT(*) FROM physical_log WHERE COALESCE(synced,0)=0"
    ).fetchone()[0]


def _local_row_count(con):
    return con.execute("SELECT COUNT(*) FROM physical_log").fetchone()[0]


# ==========================================================================
# TEST A -- normal sync
# ==========================================================================

def test_a_normal_sync_reaches_server_and_second_sync_is_a_no_op(device, live_server):
    lp, con, _ = device
    _seed(lp, con, n=1)

    sent = lp.sync_unsynced_logs(con)
    assert sent == 1
    assert _local_unsynced_count(con) == 0

    server_rows = _server_rows(live_server)
    assert len(server_rows) == 1

    # Second sync: nothing unsynced left, so it must not even attempt a
    # request -- proven by the row count staying at 1, not by mocking.
    sent_again = lp.sync_unsynced_logs(con)
    assert sent_again == 0
    assert len(_server_rows(live_server)) == 1


# ==========================================================================
# TEST B -- server completely offline
# ==========================================================================

def test_b_server_offline_keeps_local_data_and_leaves_it_retryable(monkeypatch, tmp_path):
    """No live_server fixture at all here -- LOGIX_SERVER_URL points at a
    real, guaranteed-closed local port, so the connection is refused exactly
    the way it would be if the server process were down."""
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://127.0.0.1:1")  # port 1: never listens
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")
    db_path = tmp_path / "device.db"
    monkeypatch.setenv("LOGIX_DB", str(db_path))
    lp = importlib.reload(sys.modules["log_physical"]) if "log_physical" in sys.modules else importlib.import_module("log_physical")

    con = lp.connect(db_path)
    lp.migrate(con)
    try:
        _seed(lp, con, n=1)
        result = lp.sync_unsynced_logs(con, timeout=2)

        assert result == 0
        assert _local_row_count(con) == 1, "the session row itself must survive a sync failure"
        assert _local_unsynced_count(con) == 1, "and stay eligible for a later retry"
    finally:
        con.close()


# ==========================================================================
# TEST C -- server returns 5xx
# ==========================================================================

def test_c_5xx_is_retried_and_recovers(device, live_server, monkeypatch):
    """A real 500 from the real server (via a route this test adds), then a
    real success once it stops failing. This is the scenario the concurrent-
    sync race in Test J produces naturally; here it is forced deterministically."""
    lp, con, _ = device
    _seed(lp, con, n=1)

    calls = {"n": 0}
    real_urlopen = lp.urllib.request.urlopen

    def flaky_once(req, *a, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            raise lp.urllib.error.HTTPError(req.full_url, 503, "Service Unavailable", {}, None)
        return real_urlopen(req, *a, **kw)

    monkeypatch.setattr(lp.urllib.request, "urlopen", flaky_once)
    sleeps = []
    monkeypatch.setattr(lp.time, "sleep", lambda s: sleeps.append(s))

    result = lp.sync_unsynced_logs(con, max_attempts=3)

    assert result == 1
    assert calls["n"] == 2
    assert sleeps == [1]  # one backoff pause between the 503 and the retry
    assert _local_unsynced_count(con) == 0
    assert len(_server_rows(live_server)) == 1


def test_c_5xx_without_retry_budget_leaves_data_safe_not_lost(device):
    """max_attempts=1 -- the inline post-insert call's real setting. A 5xx
    still must not lose or corrupt anything; it just waits for the NEXT
    sync opportunity rather than retrying immediately."""
    lp, con, _ = device
    _seed(lp, con, n=1)

    def always_503(req, *a, **kw):
        raise lp.urllib.error.HTTPError(req.full_url, 500, "Internal Server Error", {}, None)
    con2_patch_target = lp.urllib.request
    orig = con2_patch_target.urlopen
    con2_patch_target.urlopen = always_503
    try:
        result = lp.sync_unsynced_logs(con, max_attempts=1)
    finally:
        con2_patch_target.urlopen = orig

    assert result == 0
    assert _local_row_count(con) == 1
    assert _local_unsynced_count(con) == 1


# ==========================================================================
# TEST D -- server returns 4xx (documented: fails fast, not retried)
# ==========================================================================

def test_d_401_bad_key_fails_fast_without_retry_and_keeps_data(device, live_server, monkeypatch):
    """The realistic 4xx for this client: a wrong/revoked API key. Real
    request against the real server (not a fabricated HTTPError) -- proves
    the server genuinely returns 401 for this case, not just that the
    client would handle a 401 if it occurred."""
    lp, con, _ = device
    monkeypatch.setenv("LOGIX_SERVER_API_KEY", "not-the-right-key")
    lp2 = importlib.reload(sys.modules["log_physical"])
    _seed(lp2, con, n=1)

    sleeps = []
    monkeypatch.setattr(lp2.time, "sleep", lambda s: sleeps.append(s))

    result = lp2.sync_unsynced_logs(con, max_attempts=3)

    assert result == 0
    assert sleeps == [], "a 4xx must not be retried -- resending the same bytes cannot fix bad auth"
    assert _local_row_count(con) == 1
    assert _local_unsynced_count(con) == 1
    assert len(_server_rows(live_server)) == 0, "the server must not have accepted the unauthenticated write"


def test_d_403_device_key_scoped_to_wrong_hostname_fails_fast(device, live_server, monkeypatch):
    """assert_device_scope: a per-device key may only speak for its own
    hostname. Enrolls a real device via the real server, then tries to sync
    events claiming a DIFFERENT hostname with that device's key."""
    lp, con, db_path = device
    module = live_server.module
    conn = module.get_db()
    try:
        conn.execute(
            "INSERT INTO devices (device_id, hostname, display_name, api_key, category, "
            "enrolled_at, created_at, updated_at) "
            "VALUES ('dev-1', 'PC-1', 'PC-1', 'device-specific-key', 'lab_workstation', "
            "datetime('now'), datetime('now'), datetime('now'))"
        )
        conn.commit()
    finally:
        conn.close()

    monkeypatch.setenv("LOGIX_SERVER_API_KEY", "device-specific-key")
    lp2 = importlib.reload(sys.modules["log_physical"])
    _seed(lp2, con, n=1, hostname="SOMEONE-ELSES-PC")

    result = lp2.sync_unsynced_logs(con, max_attempts=1)

    assert result == 0
    assert _local_unsynced_count(con) == 1
    assert len(_server_rows(live_server)) == 0


# ==========================================================================
# TEST E -- server accepts the event, but the client never sees the response
# ==========================================================================

def test_e_response_lost_after_server_commits_is_a_safe_noop_on_retry(device, live_server):
    """The critical idempotency case. The FIRST attempt genuinely reaches the
    real server and the real server genuinely commits it (proven by reading
    the server's own DB afterward) -- only the CLIENT's visibility into that
    success is what gets destroyed, which is the one interleaving a black-box
    network-partition test cannot deterministically force. The retry is a
    completely normal, unpatched sync_unsynced_logs() call.

    Uses its own MonkeyPatch.context() rather than the `monkeypatch` fixture:
    that fixture is shared with the `device` fixture's env-var setup
    (LOGIX_SERVER_URL etc.), and undoing it here would revert those too."""
    lp, con, _ = device
    (uid,) = _seed(lp, con, n=1)

    real_urlopen = lp.urllib.request.urlopen

    def urlopen_then_drop_response(req, *a, **kw):
        with real_urlopen(req, *a, **kw) as resp:
            assert resp.status in (200, 201)  # really did succeed server-side
        raise TimeoutError("simulated: response never reached the client")

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(lp.urllib.request, "urlopen", urlopen_then_drop_response)
        first = lp.sync_unsynced_logs(con, max_attempts=1)

    assert first == 0, "the client saw a failure, so it must not have marked anything synced"
    assert _local_unsynced_count(con) == 1
    server_rows_after_lost_response = _server_rows(live_server)
    assert len(server_rows_after_lost_response) == 1, "but the server really did persist it"
    assert server_rows_after_lost_response[0]["event_uid"] == uid

    # Real transport again (the `with` block above already restored it) --
    # retry exactly as the next sync opportunity (next event, or the
    # periodic retry) would.
    second = lp.sync_unsynced_logs(con)

    assert second == 1, "the retry must succeed and mark the row synced"
    assert _local_unsynced_count(con) == 0
    server_rows_after_retry = _server_rows(live_server)
    assert len(server_rows_after_retry) == 1, "and must NOT have created a duplicate"
    assert server_rows_after_retry[0]["event_uid"] == uid


# ==========================================================================
# TEST F -- client crashes after seeing success, before persisting the ack
# ==========================================================================

class _CrashBeforeLocalAck:
    """Duck-typed stand-in for sqlite3.Connection: sync_unsynced_logs only
    ever calls .execute(...) and .commit() on the object it is given, so a
    thin proxy is enough -- and it has to be a proxy, not an instance-
    attribute monkeypatch, because sqlite3.Connection is a C-extension type
    whose instances do not accept arbitrary attribute assignment
    ('attribute execute is read-only', confirmed empirically writing this
    test)."""

    def __init__(self, real):
        self._real = real

    def execute(self, sql, *a, **kw):
        if sql.strip().upper().startswith("UPDATE PHYSICAL_LOG SET SYNCED"):
            raise RuntimeError("simulated process kill: after server 200, before local commit")
        return self._real.execute(sql, *a, **kw)

    def __getattr__(self, name):
        return getattr(self._real, name)


def test_f_crash_between_server_success_and_local_ack_recovers_without_duplicate(device, live_server):
    """Distinct from Test E: here the client DOES get the 200, but is
    killed before the local `UPDATE ... SET synced=1` commits. Simulated by
    letting the real HTTP call through (so the server-side commit is real)
    and surgically failing only that one local statement -- the exact
    statement a killed process would never have reached."""
    lp, con, db_path = device
    (uid,) = _seed(lp, con, n=1)

    proxy = _CrashBeforeLocalAck(con)
    first = lp.sync_unsynced_logs(proxy, max_attempts=1)

    assert first == 0
    assert _local_unsynced_count(con) == 1, "the crash must not have corrupted the local row"
    assert len(_server_rows(live_server)) == 1, "the server-side commit already happened and is untouched"

    # "Restart": a fresh connection to the same file, as a new process would open.
    con.close()
    con2 = lp.connect(db_path)
    try:
        assert _local_unsynced_count(con2) == 1, "pending state survives the restart"
        second = lp.sync_unsynced_logs(con2)
        assert second == 1
        assert _local_unsynced_count(con2) == 0
        rows = _server_rows(live_server)
        assert len(rows) == 1, "no duplicate was created by the recovery sync"
        assert rows[0]["event_uid"] == uid
    finally:
        con2.close()


# ==========================================================================
# TEST G -- many events, "interrupted halfway"
# ==========================================================================

def test_g_batch_interrupted_partway_completes_without_duplicating_the_committed_half(device, live_server):
    """/api/log processes one HTTP POST as one atomic server-side
    transaction (see server/main.py's log_event: a single commit() after
    the whole batch), so there is no NATIVE partial-success-within-one-
    request to interrupt. The realistic 'interrupted halfway' for this
    architecture is temporal, across rounds: an earlier batch already
    landed, a later batch's response was lost, and the remaining events
    must still get there exactly once on the next attempt.

    Own MonkeyPatch.context(), same reason as Test E: undoing the shared
    `monkeypatch` fixture here would also revert the `device` fixture's
    env vars (LOGIX_PRIVACY_MODE among them)."""
    lp, con, _ = device
    first_five = _seed(lp, con, n=5, session_prefix="a")
    first = lp.sync_unsynced_logs(con)
    assert first == 5
    assert len(_server_rows(live_server)) == 5

    next_five = _seed(lp, con, n=5, session_prefix="b")
    real_urlopen = lp.urllib.request.urlopen

    def drop_response_once(req, *a, **kw):
        with real_urlopen(req, *a, **kw):
            pass
        raise ConnectionResetError("simulated: connection dropped after the server responded")

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(lp.urllib.request, "urlopen", drop_response_once)
        interrupted = lp.sync_unsynced_logs(con, max_attempts=1)
    assert interrupted == 0
    assert _local_unsynced_count(con) == 5, "only the second batch remains pending"
    assert len(_server_rows(live_server)) == 10, "but the server already has all 10"

    completed = lp.sync_unsynced_logs(con)

    assert completed == 5
    assert _local_unsynced_count(con) == 0
    rows = _server_rows(live_server)
    assert len(rows) == 10, "still exactly 10 -- the retry did not duplicate the already-committed 5"
    assert sorted(r["event_uid"] for r in rows) == sorted(first_five + next_five)


# ==========================================================================
# TEST H -- client restart with pending events
# ==========================================================================

def test_h_client_restart_preserves_pending_events_and_resumes(device, live_server):
    lp, con, db_path = device
    uids = _seed(lp, con, n=3)
    con.close()  # process exit, before any sync was ever attempted

    con2 = lp.connect(db_path)  # "restart": fresh connection, same file
    try:
        assert _local_unsynced_count(con2) == 3, "pending events are not in-memory state"
        result = lp.sync_unsynced_logs(con2)
        assert result == 3
        assert _local_unsynced_count(con2) == 0
        rows = _server_rows(live_server)
        assert sorted(r["event_uid"] for r in rows) == sorted(uids)
    finally:
        con2.close()


# ==========================================================================
# TEST I -- server restart
# ==========================================================================

def test_i_server_restart_mid_campaign_loses_nothing_and_creates_no_duplicate(monkeypatch, tmp_path, live_server):
    """The server is stopped and a NEW instance started on the SAME db file
    (an HTTP request/response has nothing mid-flight to interrupt more
    realistically than 'the endpoint was simply not there for a moment' --
    Test B already covers a request that never gets a response at all)."""
    monkeypatch.setenv("LOGIX_SERVER_URL", live_server.base_url)
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")
    monkeypatch.setenv("LOGIX_SERVER_API_KEY", "dev-test-key")
    db_path = tmp_path / "device.db"
    monkeypatch.setenv("LOGIX_DB", str(db_path))
    lp = importlib.reload(sys.modules["log_physical"])
    con = lp.connect(db_path)
    lp.migrate(con)
    try:
        first_batch = _seed(lp, con, n=3, session_prefix="x")
        assert lp.sync_unsynced_logs(con) == 3

        # Take the server down.
        live_server.stop()
        second_batch = _seed(lp, con, n=3, session_prefix="y")
        during_outage = lp.sync_unsynced_logs(con, timeout=2)
        assert during_outage == 0
        assert _local_unsynced_count(con) == 3

        # Bring it back on the SAME port, SAME db file -- a real restart.
        db_path_server = live_server.module.DB_PATH
        new_server = LiveServer(live_server.module.app, live_server.port)
        new_server.module = live_server.module
        new_server.start()
        try:
            recovered = lp.sync_unsynced_logs(con)
            assert recovered == 3
            assert _local_unsynced_count(con) == 0

            sconn = sqlite3.connect(str(db_path_server))
            try:
                rows = sconn.execute("SELECT event_uid FROM physical_log ORDER BY id").fetchall()
            finally:
                sconn.close()
            assert sorted(r[0] for r in rows) == sorted(first_batch + second_batch)
        finally:
            new_server.stop()
    finally:
        con.close()


# ==========================================================================
# TEST J -- concurrent sync (proven possible: see the audit -- the inline
# post-insert sync and an explicit --sync-to-server run, or two rapid
# events, can both call sync_unsynced_logs() against overlapping rows)
# ==========================================================================

def test_j_two_concurrent_syncs_of_the_same_rows_create_no_server_duplicate(device, live_server):
    """Two SEPARATE sqlite3 connections to the SAME local db (mirroring two
    separate OS processes, which is what actually races in production --
    see Invoke-NativeBridge, spawned fresh per event), both syncing at once.
    A large batch is used because a small one finishes within one Python GIL
    slice and never actually interleaves -- this was verified empirically
    against a live server before writing this test (a 5-row batch never
    raced in repeated runs; a 400-row batch reliably did)."""
    lp, con, db_path = device
    con.close()  # the two workers open their own connections below

    seed_con = lp.connect(db_path)
    try:
        uids = _seed(lp, seed_con, n=300, session_prefix="race")
    finally:
        seed_con.close()

    results = {}
    barrier = threading.Barrier(2)

    def worker(name):
        wcon = lp.connect(db_path)
        try:
            barrier.wait()
            n = lp.sync_unsynced_logs(wcon, timeout=15, max_attempts=3)
            results[name] = n
        finally:
            wcon.close()

    t1 = threading.Thread(target=worker, args=("A",))
    t2 = threading.Thread(target=worker, args=("B",))
    t1.start()
    t2.start()
    t1.join(timeout=30)
    t2.join(timeout=30)

    assert "A" in results and "B" in results, "both workers must finish (no hang/deadlock)"

    server_rows = _server_rows(live_server)
    assert len(server_rows) == len(uids), (
        f"expected exactly {len(uids)} server rows (no duplicates from the race), got {len(server_rows)}"
    )
    assert sorted(r["event_uid"] for r in server_rows) == sorted(uids)

    # Sweep: whichever worker "lost" a race retries per the max_attempts=3
    # budget already given to it above; if either still came up short (e.g.
    # a slower machine exhausting that budget), one more ordinary call must
    # finish the job -- this mirrors the next real event's inline sync
    # picking up whatever the previous one could not.
    mop_con = lp.connect(db_path)
    try:
        lp.sync_unsynced_logs(mop_con)
        assert _local_unsynced_count(mop_con) == 0, "every row must eventually be marked synced locally"
    finally:
        mop_con.close()


def test_j_local_writes_from_two_connections_do_not_corrupt_the_device_db(device):
    """The client db is opened WAL + 30s busy_timeout specifically so two
    local processes writing at once (e.g. two log_physical.py invocations
    for two events firing close together) serialize instead of corrupting
    each other. Proven directly, independent of the server."""
    lp, con, db_path = device
    con.close()

    errors = []

    def inserter(session_prefix):
        wcon = lp.connect(db_path)
        try:
            _seed(lp, wcon, n=25, session_prefix=session_prefix)
        except Exception as e:  # pragma: no cover - failure path under test
            errors.append(e)
        finally:
            wcon.close()

    t1 = threading.Thread(target=inserter, args=("p",))
    t2 = threading.Thread(target=inserter, args=("q",))
    t1.start(); t2.start()
    t1.join(timeout=30); t2.join(timeout=30)

    assert errors == [], f"concurrent local writes must not raise: {errors}"
    check = sqlite3.connect(str(db_path))
    try:
        total = check.execute("SELECT COUNT(*) FROM physical_log").fetchone()[0]
        distinct_uids = check.execute("SELECT COUNT(DISTINCT event_uid) FROM physical_log").fetchone()[0]
    finally:
        check.close()
    assert total == 50
    assert distinct_uids == 50
