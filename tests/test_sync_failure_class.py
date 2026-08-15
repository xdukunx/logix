"""Sync failure classification (Phase 2A).

Why this file exists: a UI cannot tell "the server is unreachable" from "the
server refused us" by reading last_error, because that field is English prose
written for a human debugging a problem. Rendering a status line off a
substring match would be guesswork dressed as a state machine.

So sync_unsynced_logs now classifies at the point it catches the exception,
where the distinction is still available, and records last_error_class beside
the untouched free-form text. These tests pin the classes to the real failure
modes that produce them -- a refused socket, a live server answering 401, a
live server answering 5xx -- not to mocked exceptions, because what is being
proven is that urllib's actual behaviour lands in the branch we think it does.

See docs/OFFLINE_CLIENT_UX_CONTRACT.md 2b for how a UI consumes this.
"""
from __future__ import annotations

import http.server
import importlib
import json
import socket
import sys
import threading

import pytest


def _lp():
    if "log_physical" in sys.modules:
        return importlib.reload(sys.modules["log_physical"])
    return importlib.import_module("log_physical")


def _seed(lp, con, n=1):
    for i in range(n):
        ns = lp.parse_args(["--event", "START", "--hostname", "PC-1",
                            "--session-id", f"cls{i}"])
        lp.insert_event(con, lp.payload_from_args(ns))


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _FixedStatusServer:
    """The smallest real HTTP server that can answer with a chosen status.

    A live FastAPI app would also work, but it brings auth, routing and
    startup cost to prove one thing: that urllib raises HTTPError with a
    given code and that the classifier maps it. This answers in microseconds
    and cannot drift from the product's own auth rules, which are not what
    is under test here.
    """

    def __init__(self, status: int):
        self.status = status
        self.port = _free_port()
        status_code = status

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                self.rfile.read(length)
                self.send_response(status_code)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"detail":"nope"}')

            def log_message(self, *a):
                pass

        self.httpd = http.server.HTTPServer(("127.0.0.1", self.port), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}"


def _device(monkeypatch, tmp_path, server_url):
    monkeypatch.setenv("LOGIX_SERVER_URL", server_url)
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")
    monkeypatch.setenv("LOGIX_SERVER_API_KEY", "any-key")
    db_path = tmp_path / "device.db"
    monkeypatch.setenv("LOGIX_DB", str(db_path))
    lp = _lp()
    con = lp.connect(db_path)
    lp.migrate(con)
    return lp, con


# ---- the three the contract requires be distinguishable ------------------

def test_unreachable_server_classifies_as_network(monkeypatch, tmp_path):
    """Port 1 never listens, so this is a real refused connection -- the
    laptop-left-the-lab case, and the only one that should ever make a UI
    say 'server unavailable'."""
    lp, con = _device(monkeypatch, tmp_path, "http://127.0.0.1:1")
    try:
        _seed(lp, con)
        assert lp.sync_unsynced_logs(con, timeout=2) == 0

        st = lp.sync_status(con)
        assert st["last_error_class"] == "network"
        assert st["connection_state"] == "offline"
        assert st["pending_count"] == 1, "the row is still there and still eligible"
    finally:
        con.close()


def test_server_error_classifies_as_server(monkeypatch, tmp_path):
    """It answered. Whatever is wrong is on its side and plausibly
    transient, which is why this is the branch that retries."""
    with _FixedStatusServer(503) as srv:
        lp, con = _device(monkeypatch, tmp_path, srv.url)
        try:
            _seed(lp, con)
            assert lp.sync_unsynced_logs(con, timeout=5) == 0
            assert lp.sync_status(con)["last_error_class"] == "server"
        finally:
            con.close()


def test_policy_block_records_no_attempt_at_all(monkeypatch, tmp_path):
    """Policy is not a failure. sync_unsynced_logs returns before it opens a
    socket, so nothing may be written to the sidecar -- a last_error here
    would make a correctly-configured private device look broken."""
    lp, con = _device(monkeypatch, tmp_path, "http://127.0.0.1:1")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "local_only")
    try:
        _seed(lp, con)
        assert lp.sync_unsynced_logs(con, timeout=2) == 0

        st = lp.sync_status(con)
        assert st["connection_state"] == "blocked", "derived live from privacy_mode"
        assert st["last_error"] is None
        assert st["last_error_class"] is None
        assert st["last_attempt"] is None, "no socket was opened, so no attempt happened"
    finally:
        con.close()


# ---- the rest of the taxonomy --------------------------------------------

@pytest.mark.parametrize("code,expected", [
    (401, "auth"),
    (403, "auth"),
    (400, "rejected"),
    (422, "rejected"),
    (500, "server"),
    (502, "server"),
])
def test_http_status_maps_to_class(code, expected):
    assert _lp()._classify_http_error(code) == expected


def test_auth_failure_against_a_real_socket(monkeypatch, tmp_path):
    """Not just the pure function: prove urllib actually raises HTTPError for
    a 401 so the classifier is reached at all."""
    with _FixedStatusServer(401) as srv:
        lp, con = _device(monkeypatch, tmp_path, srv.url)
        try:
            _seed(lp, con)
            assert lp.sync_unsynced_logs(con, timeout=5) == 0
            assert lp.sync_status(con)["last_error_class"] == "auth"
        finally:
            con.close()


# ---- the class is additive: nothing existing may change ------------------

def test_free_form_error_text_is_retained(monkeypatch, tmp_path):
    """The class is for rendering; the text is for whoever has to debug it.
    Adding one must not cost the other."""
    with _FixedStatusServer(503) as srv:
        lp, con = _device(monkeypatch, tmp_path, srv.url)
        try:
            _seed(lp, con)
            lp.sync_unsynced_logs(con, timeout=5)

            st = lp.sync_status(con)
            assert st["last_error"], "the human-readable detail is still recorded"
            assert "503" in st["last_error"]
        finally:
            con.close()


def test_success_clears_both_error_and_class(monkeypatch, tmp_path):
    """A stale class outliving the failure would strand the UI in an error
    state after everything recovered."""
    lp, con = _device(monkeypatch, tmp_path, "http://127.0.0.1:1")
    try:
        _seed(lp, con)
        lp.sync_unsynced_logs(con, timeout=2)
        assert lp.sync_status(con)["last_error_class"] == "network"

        lp._record_sync_attempt(con, ok=True)

        st = lp.sync_status(con)
        assert st["last_error"] is None
        assert st["last_error_class"] is None
    finally:
        con.close()


def test_state_file_from_an_older_build_reads_back_as_unknown(monkeypatch, tmp_path):
    """A device that fails, then updates, has a sidecar with last_error and
    no last_error_class. That must not surface as a missing field the UI has
    to special-case -- it degrades to 'unknown', which renders as a generic
    sync error rather than claiming to know the cause."""
    lp, con = _device(monkeypatch, tmp_path, "http://127.0.0.1:1")
    try:
        path = lp._sync_state_path(con)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "last_attempt": "2026-08-01T10:00:00+07:00",
            "last_error": "written by a build that had no classes",
        }), encoding="utf-8")

        assert lp.sync_status(con)["last_error_class"] == "unknown"
    finally:
        con.close()


def test_every_class_is_in_the_declared_taxonomy(monkeypatch, tmp_path):
    """An unrecognised class must be coerced, not stored -- otherwise a typo
    at one call site becomes an unhandled branch in every consumer."""
    lp, con = _device(monkeypatch, tmp_path, "http://127.0.0.1:1")
    try:
        lp._record_sync_attempt(con, ok=False, detail="x", error_class="nonsense")
        assert lp.sync_status(con)["last_error_class"] == "unknown"
        assert set(lp.SYNC_ERROR_CLASSES) == {
            "network", "auth", "rejected", "server", "unknown"}
    finally:
        con.close()
