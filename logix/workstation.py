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

# nvidia-smi is a PROCESS SPAWN, unlike everything else here, so it is not on
# the same refresh path. The dashboard polls CPU/memory in-process every few
# seconds; doing that to the GPU would spawn ~1200 processes an hour, which is
# exactly the kind of thing this project has spent phases removing. Cached,
# with an explicit refresh, and a coarse floor if anyone ever polls it.
_GPU_MIN_INTERVAL = 15.0
_gpu_cache: dict[str, Any] = {"at": 0.0, "value": None}


def cpu(interval: float = 0.0) -> dict[str, Any] | None:
    """interval=0 returns the load since the previous call rather than
    blocking. The dashboard calls this on a timer, so consecutive calls give
    a real figure without any sample ever holding up a response."""
    if not HAVE_PSUTIL:
        return None
    try:
        return {
            "percent": psutil.cpu_percent(interval=interval),
            "cores_logical": psutil.cpu_count(logical=True),
            "cores_physical": psutil.cpu_count(logical=False),
        }
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
    try:
        usage = shutil.disk_usage(str(path))
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
             "--query-gpu=name,utilization.gpu,memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=4,
            creationflags=(subprocess.CREATE_NO_WINDOW
                           if sys.platform == "win32" else 0),
        )
        if out.returncode == 0 and out.stdout.strip():
            name, util, used, total = [
                p.strip() for p in out.stdout.strip().splitlines()[0].split(",")]
            value = {"name": name,
                     "percent": float(util),
                     "vram_used_bytes": int(float(used) * 1024 * 1024),
                     "vram_total_bytes": int(float(total) * 1024 * 1024)}
    except Exception:
        value = None

    _gpu_cache["at"] = now
    _gpu_cache["value"] = value
    return value


def snapshot(include_gpu: bool = True, force_gpu: bool = False) -> dict[str, Any]:
    """One reading of everything. Keys are always present; a value of None
    is the honest answer for a metric this machine cannot report, and every
    consumer must render it as unavailable rather than as zero."""
    return {
        "cpu": cpu(),
        "memory": memory(),
        "storage": storage(),
        "gpu": gpu(force=force_gpu) if include_gpu else None,
        "psutil_available": HAVE_PSUTIL,
        "sampled_at": time.time(),
    }


def human_bytes(n: int | float | None) -> str:
    if n is None:
        return "—"
    step = 1024.0
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < step or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= step
    return f"{n:.1f} TB"
