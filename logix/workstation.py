#!/usr/bin/env python3
"""Current workstation telemetry for the local dashboard.

Three rules shape this module:

1. NEVER fabricate. Every function returns a real reading or None. A missing
   GPU is None, not 0%; an uninstalled psutil is None, not a zeroed card.
   The dashboard renders "Unavailable" for None, which is true, where "0%"
   would be a lie that looks like a working sensor.

2. NOTHING here is required. Logix's core has no dependencies -- that is a
   stated property of the product, not an accident (see
   requirements-sync.txt). psutil is imported optionally and its absence
   degrades three cards, not the client. Storage deliberately uses
   shutil.disk_usage, which is stdlib, so the one metric that matters for
   "can this machine still write my logbook" never depends on anything.

3. NOTHING here is written to SQLite. This is current-state telemetry about
   a machine, not a logbook event about a person. The logbook is the
   durable record; these numbers are true for a second and then are not.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

try:
    import psutil
except Exception:          # ImportError, and anything a broken install raises
    psutil = None

HAVE_PSUTIL = psutil is not None

# psutil.cpu_percent(interval=0) reports load since the PREVIOUS call, and
# the first call in a process has no previous -- it returns exactly 0.0.
# On a dashboard whose stated rule is that it never shows a fake zero, the
# first paint was showing one. Priming here establishes the baseline at
# import, so the first real reading a page asks for is a measurement rather
# than an artefact of process startup.
if HAVE_PSUTIL:
    try:
        psutil.cpu_percent(interval=None)
    except Exception:
        pass

_cpu_last_call = 0.0
_cpu_last_value: dict[str, Any] | None = None
# A short BLOCKING sample, cached. The non-blocking form reports load since
# the previous call, which sounds free and mostly is -- but the window is
# then whatever the gap between callers happened to be, and Windows accounts
# CPU time in ~15.6 ms ticks spread across every logical processor. Measured
# against the running server, that produced occasional exact 0.0 readings on
# a machine sitting at 30-60%, which is the fake zero this module exists to
# prevent, arriving by a different route.
#
# So: sample for 100 ms, which is a window Windows can actually measure, and
# reuse the answer for 2 seconds. The dashboard polls every 2.5 s, so it pays
# 100 ms per poll while someone is looking at the page and nothing at all
# otherwise. No sample is ever taken on the START path.
_CPU_SAMPLE_SECONDS = 0.1
_CPU_CACHE_SECONDS = 2.0

# nvidia-smi is a PROCESS SPAWN, unlike everything else here, so it is not on
# the same refresh path. The dashboard polls CPU/memory in-process every few
# seconds; doing that to the GPU would spawn ~1200 processes an hour, which is
# exactly the kind of thing this project has spent phases removing. Cached,
# with an explicit refresh, and a coarse floor if anyone ever polls it.
_GPU_MIN_INTERVAL = 15.0
_gpu_cache: dict[str, Any] = {"at": 0.0, "value": None}


def cpu(interval: float | None = None) -> dict[str, Any] | None:
    """Current system-wide CPU load, or None if it cannot be read.

    Cached for _CPU_CACHE_SECONDS so that two callers on different timers do
    not each pay for a sample, and so that a burst of requests cannot turn
    into a burst of measurement windows too short to mean anything.
    """
    global _cpu_last_call, _cpu_last_value
    if not HAVE_PSUTIL:
        return None
    if interval is None:
        if _cpu_last_value is not None and (time.monotonic() - _cpu_last_call) < _CPU_CACHE_SECONDS:
            return dict(_cpu_last_value)
        interval = _CPU_SAMPLE_SECONDS
    try:
        # percpu in the SAME sampling window as the aggregate, not a second
        # call: two cpu_percent() calls back to back would give the second one
        # a near-zero window and return a row of zeros. psutil keeps separate
        # internal state for the aggregate and the per-cpu series, so this is
        # one blocking sample that yields both.
        per_core = psutil.cpu_percent(interval=interval, percpu=True)
        _cpu_last_value = {
            # Recomputed from the per-core readings rather than taken from a
            # third call: the aggregate must be consistent with the row of
            # cores drawn beside it, or the number and the blocks disagree on
            # screen for no reason a viewer could work out.
            "percent": round(sum(per_core) / len(per_core), 1) if per_core else 0.0,
            "per_core": [round(v, 1) for v in per_core],
            "cores_logical": psutil.cpu_count(logical=True),
            "cores_physical": psutil.cpu_count(logical=False),
        }
        _cpu_last_call = time.monotonic()
        return dict(_cpu_last_value)
    except Exception:
        return None



def memory() -> dict[str, Any] | None:
    if not HAVE_PSUTIL:
        return None
    try:
        m = psutil.virtual_memory()
        return {"used_bytes": m.total - m.available,
                "total_bytes": m.total,
                "percent": m.percent}
    except Exception:
        return None


def storage(path: Path | str | None = None) -> dict[str, Any] | None:
    """The volume Logix actually writes to, not every drive on the machine.

    Scanning all mounts on each refresh would touch removable and network
    drives, which is slow and occasionally blocking. The question the
    dashboard asks is "can this workstation keep recording", and that is
    answered by one volume.
    """
    if path is None:
        try:
            import paths
            path = paths.data_home()
        except Exception:
            path = Path.home()
    path = Path(path)
    # disk_usage needs a path that EXISTS -- it stats the target, not just
    # the volume. On a fresh install data_home() has never been created (no
    # session has been logged yet), which is the single most important case
    # for this metric to get right, not an edge case to shrug off: "can this
    # workstation still record" answered "Unavailable" on the exact machine
    # that just asked "can I start recording". Free space on a volume does
    # not depend on whether one particular subdirectory under it has been
    # created yet, so walk up to the nearest ancestor that already exists.
    probe = path
    while not probe.exists():
        parent = probe.parent
        if parent == probe:  # hit the filesystem root without finding one
            break
        probe = parent
    try:
        usage = shutil.disk_usage(str(probe))
        return {"free_bytes": usage.free,
                "total_bytes": usage.total,
                "used_bytes": usage.used,
                "percent": round(usage.used / usage.total * 100, 1) if usage.total else None,
                "path": str(path)}
    except Exception:
        return None


def gpu(force: bool = False) -> dict[str, Any] | None:
    """None means "no GPU reading available", which covers no NVIDIA card, no
    driver, and nvidia-smi missing alike. The dashboard says so rather than
    drawing an idle-looking 0%."""
    now = time.monotonic()
    if not force and (now - _gpu_cache["at"]) < _GPU_MIN_INTERVAL:
        return _gpu_cache["value"]

    value = None
    try:
        out = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=name,utilization.gpu,memory.used,memory.total,"
             "temperature.gpu,power.draw,clocks.sm",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=4,
            creationflags=(subprocess.CREATE_NO_WINDOW
                           if sys.platform == "win32" else 0),
        )
        if out.returncode == 0 and out.stdout.strip():
            parts = [p.strip() for p in out.stdout.strip().splitlines()[0].split(",")]
            name, util, used, total = parts[0], parts[1], parts[2], parts[3]
            value = {"name": name,
                     "percent": float(util),
                     "vram_used_bytes": int(float(used) * 1024 * 1024),
                     "vram_total_bytes": int(float(total) * 1024 * 1024)}
            # Temperature, power and clock are queried in the SAME nvidia-smi
            # call rather than a second one -- the process spawn is the whole
            # cost of this function, so extra columns are free while a second
            # invocation would double it.
            #
            # Each is optional and parsed defensively: nvidia-smi answers
            # "[N/A]" for anything the card or driver does not expose (fan
            # speed on this laptop GPU, for instance), and an [N/A] must
            # arrive as an absent key, never as a zero that reads like a cold
            # idle card.
            for key, raw in (("temp_c", parts[4] if len(parts) > 4 else ""),
                             ("power_w", parts[5] if len(parts) > 5 else ""),
                             ("clock_mhz", parts[6] if len(parts) > 6 else "")):
                try:
                    value[key] = float(raw)
                except (TypeError, ValueError):
                    pass
    except Exception:
        value = None

    _gpu_cache["at"] = now
    _gpu_cache["value"] = value
    return value


# Throughput is a RATE, so it only exists between two readings -- there is no
# such thing as an instantaneous byte/s. These hold the previous counter
# snapshot so the next call can difference against it; the first call after
# import therefore has nothing to compare to and reports None rather than a
# fabricated zero.
_io_prev: dict[str, Any] = {"at": 0.0, "disk": None, "net": None}


def io_rates() -> dict[str, Any] | None:
    """Disk and network throughput since the previous call, in bytes/second."""
    global _io_prev
    if not HAVE_PSUTIL:
        return None
    try:
        now = time.monotonic()
        disk = psutil.disk_io_counters()
        net = psutil.net_io_counters()
        prev_at, prev_disk, prev_net = _io_prev["at"], _io_prev["disk"], _io_prev["net"]
        _io_prev = {"at": now, "disk": disk, "net": net}

        elapsed = now - prev_at
        # Under ~0.2s the counters have barely moved and the quotient is
        # mostly rounding noise -- the same short-window problem the CPU
        # sampler has, and the same answer: say nothing rather than something
        # invented.
        if not prev_disk or not prev_net or elapsed < 0.2:
            return None
        return {
            "disk_read_bps": max(0, (disk.read_bytes - prev_disk.read_bytes)) / elapsed,
            "disk_write_bps": max(0, (disk.write_bytes - prev_disk.write_bytes)) / elapsed,
            "net_recv_bps": max(0, (net.bytes_recv - prev_net.bytes_recv)) / elapsed,
            "net_sent_bps": max(0, (net.bytes_sent - prev_net.bytes_sent)) / elapsed,
        }
    except Exception:
        return None


# A short window of real samples, held in memory and never written anywhere.
# This is what lets the dashboard draw a moving line instead of a single
# number -- and every point in it is a measurement this process actually
# took while the page was open, not a synthesised trend. It is deliberately
# NOT persisted: telemetry is not a logbook event, and a history that
# survives a restart would start implying it means something.
_HISTORY_LEN = 60
_history: list[dict[str, Any]] = []


def history() -> list[dict[str, Any]]:
    """The samples taken so far this process, oldest first. Short by design:
    at the dashboard's poll rate this is a couple of minutes, which is the
    span over which "what is this machine doing right now" is still the
    question being asked."""
    return list(_history)


def _record(sample: dict[str, Any]) -> None:
    cpu_v = (sample.get("cpu") or {}).get("percent")
    mem_v = (sample.get("memory") or {}).get("percent")
    gpu_d = sample.get("gpu") or {}
    io = sample.get("io") or {}
    _history.append({
        "t": sample.get("sampled_at"),
        "cpu": cpu_v,
        "memory": mem_v,
        "gpu": gpu_d.get("percent"),
        "gpu_temp_c": gpu_d.get("temp_c"),
        "disk_bps": (io.get("disk_read_bps", 0) + io.get("disk_write_bps", 0)) if io else None,
        "net_bps": (io.get("net_recv_bps", 0) + io.get("net_sent_bps", 0)) if io else None,
    })
    del _history[:-_HISTORY_LEN]


def snapshot(include_gpu: bool = True, force_gpu: bool = False,
             record: bool = True) -> dict[str, Any]:
    """One reading of everything. Keys are always present; a value of None
    is the honest answer for a metric this machine cannot report, and every
    consumer must render it as unavailable rather than as zero."""
    sample = {
        "cpu": cpu(),
        "memory": memory(),
        "storage": storage(),
        "gpu": gpu(force=force_gpu) if include_gpu else None,
        "io": io_rates(),
        "psutil_available": HAVE_PSUTIL,
        "sampled_at": time.time(),
    }
    if record:
        _record(sample)
    return sample


def human_bytes(n: int | float | None) -> str:
    if n is None:
        return "—"
    step = 1024.0
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < step or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= step
    return f"{n:.1f} TB"
