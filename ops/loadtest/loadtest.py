#!/usr/bin/env python3
"""Zero-dependency load test for the Logix ingest hot path (/api/heartbeat).

Heartbeat is the endpoint that scales with device count -- every beat does
SQLite writes (upsert_device, ack apply, expiry sweep), so it's where the
single-process + SQLite ceiling shows up first. This fires concurrent
heartbeats from a pool of synthetic devices and reports throughput + latency
percentiles, to establish a documented capacity baseline (see docs/RUNBOOK.md).

Run it against a THROWAWAY server (LOGIX_DB=/tmp/loadtest.db), never a real DB.

  python3 ops/loadtest/loadtest.py --url http://127.0.0.1:8799 \
      --key loadtest-key --concurrency 50 --duration 20 --devices 200

For the richer Locust UI instead, see locustfile.py in this folder.
"""
from __future__ import annotations

import argparse
import json
import threading
import time
import urllib.request
from statistics import quantiles


def worker(base, key, devices, deadline, lats, errors, idx):
    i = 0
    while time.monotonic() < deadline:
        host = devices[(idx * 7919 + i) % len(devices)]
        body = json.dumps({"hostname": host, "status": "ACTIVE", "username": "load"}).encode()
        req = urllib.request.Request(base + "/api/heartbeat", data=body, method="POST",
                                     headers={"Content-Type": "application/json", "X-API-Key": key})
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                r.read()
                if r.status != 200:
                    errors.append(r.status)
        except Exception:  # noqa: BLE001
            errors.append(-1)
        lats.append((time.perf_counter() - t0) * 1000)
        i += 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8799")
    ap.add_argument("--key", default="loadtest-key")
    ap.add_argument("--concurrency", type=int, default=50)
    ap.add_argument("--duration", type=int, default=20)
    ap.add_argument("--devices", type=int, default=200)
    ns = ap.parse_args()

    devices = [f"LOADTEST-{i:04d}" for i in range(ns.devices)]
    lats: list[float] = []
    errors: list[int] = []
    deadline = time.monotonic() + ns.duration

    print(f"load: {ns.concurrency} workers x {ns.duration}s against {ns.url} "
          f"({ns.devices} synthetic devices)")
    threads = [threading.Thread(target=worker, args=(ns.url, ns.key, devices, deadline, lats, errors, t))
               for t in range(ns.concurrency)]
    start = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - start

    n = len(lats)
    if not n:
        print("no requests completed")
        return 1
    lats.sort()
    p = quantiles(lats, n=100) if n >= 100 else None
    p50 = lats[n // 2]
    p95 = p[94] if p else lats[int(n * 0.95)]
    p99 = p[98] if p else lats[int(n * 0.99)]
    print("\n===== RESULTS =====")
    print(f"requests:   {n}   errors: {len(errors)}")
    print(f"throughput: {n / elapsed:.0f} req/s over {elapsed:.1f}s")
    print(f"latency ms: p50={p50:.1f}  p95={p95:.1f}  p99={p99:.1f}  max={lats[-1]:.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
