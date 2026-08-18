"""Workstation telemetry (Phase B).

The property under test is mostly a negative one: this module must never
invent a reading. A machine with no GPU, or an install with no psutil, has
to produce None -- which the dashboard renders as "Unavailable" -- because
a fabricated 0% looks exactly like a working sensor reporting an idle
device, and there is no way for anyone looking at the screen to tell.

Measured on the development workstation, and the reason GPU is not on the
same refresh path as everything else:

    cpu()       101 ms     a deliberate 100 ms sample, then cached 2 s
    memory()      0.06 ms
    storage()     0.06 ms
    gpu(force)   92.91 ms   <- a process spawn
    gpu(cached)   0.00 ms

CPU is sampled rather than read non-blockingly because the non-blocking
form measures whatever gap happened to elapse between callers, and Windows
accounts CPU time in ~15.6 ms ticks across every logical processor. Against
the running server that produced occasional exact 0.0 readings on a machine
sitting at 30-60% -- the fake zero this module exists to prevent, arriving
by a different route.
"""
from __future__ import annotations

import subprocess
import sys

import pytest

sys.path.insert(0, "logix") if "logix" not in sys.path else None
import workstation as w


# ---- shape --------------------------------------------------------------

def test_snapshot_always_has_every_key():
    """Consumers branch on None, not on a missing key -- a KeyError in a
    telemetry card must not be able to take out the dashboard."""
    s = w.snapshot(include_gpu=False)
    for key in ("cpu", "memory", "storage", "gpu", "psutil_available", "sampled_at"):
        assert key in s


def test_storage_needs_no_optional_dependency(monkeypatch):
    """shutil.disk_usage is stdlib. The one metric that answers "can this
    machine still record my logbook" must not depend on anything."""
    monkeypatch.setattr(w, "HAVE_PSUTIL", False)
    monkeypatch.setattr(w, "psutil", None)
    s = w.storage()
    assert s is not None
    assert s["total_bytes"] > 0


# ---- absence is reported, never faked -----------------------------------

def test_no_psutil_yields_none_not_zero(monkeypatch):
    monkeypatch.setattr(w, "HAVE_PSUTIL", False)
    monkeypatch.setattr(w, "psutil", None)
    assert w.cpu() is None
    assert w.memory() is None


def test_no_gpu_yields_none_not_zero(monkeypatch):
    """The distinction that matters: an absent GPU and an idle GPU must not
    render identically."""
    def boom(*a, **k):
        raise FileNotFoundError("nvidia-smi not on PATH")
    monkeypatch.setattr(subprocess, "run", boom)
    w._gpu_cache["at"] = 0.0
    assert w.gpu(force=True) is None


def test_gpu_nonzero_exit_is_not_a_reading(monkeypatch):
    class R:
        returncode = 9
        stdout = ""
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: R())
    w._gpu_cache["at"] = 0.0
    assert w.gpu(force=True) is None


def test_garbled_gpu_output_does_not_raise(monkeypatch):
    class R:
        returncode = 0
        stdout = "this is not, csv, at all\n"
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: R())
    w._gpu_cache["at"] = 0.0
    assert w.gpu(force=True) is None


def test_telemetry_failure_never_propagates(monkeypatch):
    """A snapshot is taken while rendering a page. It may return nothing
    useful; it may not throw."""
    monkeypatch.setattr(w, "HAVE_PSUTIL", True)
    # Clear the reading cache first, otherwise this exercises the cache
    # rather than the failure path it is named for.
    monkeypatch.setattr(w, "_cpu_last_value", None)

    class Exploding:
        def __getattr__(self, _):
            raise RuntimeError("driver went away")
    monkeypatch.setattr(w, "psutil", Exploding())
    s = w.snapshot(include_gpu=False)
    assert s["cpu"] is None and s["memory"] is None


# ---- the GPU is cached because it costs 100x everything else ------------

def test_gpu_is_not_respawned_on_every_call(monkeypatch):
    calls = {"n": 0}

    class R:
        returncode = 0
        stdout = "NVIDIA Test,47,8192,24576\n"

    def counted(*a, **k):
        calls["n"] += 1
        return R()

    monkeypatch.setattr(subprocess, "run", counted)
    w._gpu_cache["at"] = 0.0

    first = w.gpu(force=True)
    for _ in range(20):
        w.gpu()

    assert calls["n"] == 1, "20 dashboard refreshes must not spawn 20 processes"
    assert first["percent"] == 47.0
    assert first["vram_total_bytes"] == 24576 * 1024 * 1024


def test_gpu_refresh_can_be_forced(monkeypatch):
    """An explicit refresh button has to actually re-read, cache or not."""
    calls = {"n": 0}

    class R:
        returncode = 0
        stdout = "NVIDIA Test,10,1024,24576\n"

    def counted(*a, **k):
        calls["n"] += 1
        return R()

    monkeypatch.setattr(subprocess, "run", counted)
    w._gpu_cache["at"] = 0.0
    w.gpu(force=True)
    w.gpu(force=True)
    assert calls["n"] == 2


# ---- formatting ---------------------------------------------------------

def test_human_bytes_renders_absence_as_an_em_dash():
    assert w.human_bytes(None) == "—"
    assert w.human_bytes(1024 ** 3).endswith("GB")
