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
import time

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


# ---- per-core: one reading per real CPU, never a synthesised row --------

def test_cpu_reports_one_reading_per_logical_cpu():
    """The dashboard draws one block PER CORE, so the row is only honest if
    the count comes from the machine rather than from a number chosen to
    look tidy."""
    c = w.cpu()
    if c is None:
        pytest.skip("psutil not installed")
    assert len(c["per_core"]) == c["cores_logical"]


def test_aggregate_is_the_mean_of_the_cores_it_is_drawn_beside():
    """Taken from a third cpu_percent() call the aggregate would drift from
    the per-core row on screen, and a viewer would have no way to work out
    which one to believe."""
    c = w.cpu()
    if c is None:
        pytest.skip("psutil not installed")
    expected = round(sum(c["per_core"]) / len(c["per_core"]), 1)
    assert abs(c["percent"] - expected) < 0.15


def test_per_core_readings_are_independent(monkeypatch):
    """Guards against the aggregate being splayed across N identical
    entries, which would look like a per-core readout while carrying no
    per-core information at all."""
    monkeypatch.setattr(w, "_cpu_last_value", None)

    class FakePsutil:
        @staticmethod
        def cpu_percent(interval=None, percpu=False):
            return [10.0, 90.0, 0.0, 45.5] if percpu else 36.375
        @staticmethod
        def cpu_count(logical=True):
            return 4 if logical else 2

    monkeypatch.setattr(w, "psutil", FakePsutil)
    monkeypatch.setattr(w, "HAVE_PSUTIL", True)
    c = w.cpu(interval=0)
    assert c["per_core"] == [10.0, 90.0, 0.0, 45.5]
    assert c["percent"] == 36.4


# ---- rates and history: real samples only, never a fabricated zero ------

def test_first_io_reading_is_none_because_a_rate_needs_two_points(monkeypatch):
    """Throughput only exists between two counter readings. The first call
    after import has nothing to difference against, and must say so rather
    than report 0 B/s -- which would read as a genuinely idle disk."""
    monkeypatch.setattr(w, "_io_prev", {"at": 0.0, "disk": None, "net": None})
    assert w.io_rates() is None


def test_io_rates_are_non_negative(monkeypatch):
    """Counters can reset (a driver reload, a counter wrap). A negative rate
    would render as a nonsense reading, so the difference is floored."""
    if not w.HAVE_PSUTIL:
        pytest.skip("psutil not installed")
    w.io_rates()
    time.sleep(0.3)
    r = w.io_rates()
    if r is None:
        pytest.skip("window too short on this machine")
    assert all(v >= 0 for v in r.values())


def test_history_records_real_samples_and_is_bounded():
    before = len(w.history())
    w.snapshot(include_gpu=False)
    w.snapshot(include_gpu=False)
    after = w.history()
    assert len(after) >= before
    assert len(after) <= w._HISTORY_LEN, "the buffer is capped, not unbounded"
    assert "t" in after[-1] and "cpu" in after[-1]


def test_history_does_not_survive_a_restart():
    """Telemetry is not a logbook event, and a history that outlived the
    process would start implying it means something. Asserted by actually
    reloading the module rather than by reading its source: what matters is
    that nothing reconstitutes the buffer, not that a particular call is
    absent from the file."""
    import importlib
    w.snapshot(include_gpu=False)
    assert len(w.history()) > 0
    fresh = importlib.reload(w)
    assert fresh.history() == [], "a reloaded module must start with no samples"


def test_gpu_absent_sensor_is_omitted_not_zeroed(monkeypatch):
    """nvidia-smi answers [N/A] for anything the card does not expose (fan
    speed on a laptop GPU). An [N/A] must arrive as a missing key, never as
    a 0 that reads like a cold idle card."""
    class R:
        returncode = 0
        stdout = "NVIDIA Test,10,1024,24576,[N/A],[N/A],[N/A]\n"
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: R())
    w._gpu_cache["at"] = 0.0
    g = w.gpu(force=True)
    assert g["percent"] == 10.0
    assert "temp_c" not in g and "power_w" not in g and "clock_mhz" not in g
