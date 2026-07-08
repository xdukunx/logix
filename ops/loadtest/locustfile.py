"""Locust load test for Logix (richer UI + distributed option than loadtest.py).

  pip install locust
  LOGIX_INGEST_KEY=loadtest-key locust -f ops/loadtest/locustfile.py \
      --host http://127.0.0.1:8799

Then open http://localhost:8089 and set users/spawn-rate, or run headless:
  ... locust ... --headless -u 50 -r 10 -t 30s

Point --host at a THROWAWAY server (LOGIX_DB=/tmp/loadtest.db), never real data.
"""
import os
import random

from locust import HttpUser, between, task

KEY = os.environ.get("LOGIX_INGEST_KEY", "loadtest-key")


class Device(HttpUser):
    """Simulates a lab device: mostly heartbeats, the real ingest hot path."""
    wait_time = between(1, 3)

    def on_start(self):
        self.hostname = f"LOADTEST-{random.randint(0, 999):04d}"

    @task(10)
    def heartbeat(self):
        self.client.post(
            "/api/heartbeat",
            json={"hostname": self.hostname, "status": "ACTIVE", "username": "load"},
            headers={"X-API-Key": KEY},
            name="/api/heartbeat",
        )

    @task(1)
    def health(self):
        self.client.get("/api/health", name="/api/health")
