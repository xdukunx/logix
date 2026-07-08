#!/usr/bin/env python3
"""Logix ops watchdog -> Telegram alerts.

Runs every few minutes (systemd timer). Three checks:
  1. health  -- GET /api/health returns 200 + {"status":"ok"}
  2. errors  -- new ERROR lines in server/logs/logix.log since the last run
                (an error pile-up), above a threshold
  3. backup  -- the newest DB backup is fresh (< ~26h old)

On a state change it sends a Telegram message (alert on failure, "recovered"
when it clears) -- de-duplicated via a small state file so it doesn't spam
every tick. A local watchdog can't report that the whole host is down, so also
run an EXTERNAL uptime check (UptimeRobot / healthchecks.io) on /api/health --
see docs/RUNBOOK.md.

  python3 ops/watchdog.py            # check + alert
  python3 ops/watchdog.py --dry-run  # print what WOULD be sent, send nothing

Config via env (systemd EnvironmentFile=server/.env, or export):
  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID   (required to actually send)
  LOGIX_HEALTH_URL      (default http://127.0.0.1:8000/api/health)
  LOGIX_LOG_FILE        (default server/logs/logix.log)
  LOGIX_BACKUP_DIR      (default server/backups)
  LOGIX_WATCHDOG_ERROR_THRESHOLD (default 3)
  LOGIX_BACKUP_MAX_AGE_HOURS     (default 26)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

# Alerts contain emoji; make stdout UTF-8 so --dry-run prints on Windows too
# (Linux/systemd journald is already UTF-8).
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = Path(__file__).resolve().parent.parent


def _load_env(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if k and k not in os.environ:
            os.environ[k] = v


_load_env(REPO / "server" / ".env")

HEALTH_URL = os.environ.get("LOGIX_HEALTH_URL", "http://127.0.0.1:8000/api/health")
LOG_FILE = Path(os.environ.get("LOGIX_LOG_FILE", REPO / "server" / "logs" / "logix.log"))
BACKUP_DIR = Path(os.environ.get("LOGIX_BACKUP_DIR", REPO / "server" / "backups"))
STATE_FILE = Path(os.environ.get("LOGIX_WATCHDOG_STATE", REPO / "server" / "logs" / ".watchdog_state.json"))
ERROR_THRESHOLD = int(os.environ.get("LOGIX_WATCHDOG_ERROR_THRESHOLD", "3"))
BACKUP_MAX_AGE_H = float(os.environ.get("LOGIX_BACKUP_MAX_AGE_HOURS", "26"))
BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")


def log(msg: str) -> None:
    print(f"{datetime.now().isoformat(timespec='seconds')} watchdog: {msg}", flush=True)


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state: dict) -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(state))
    except Exception as e:  # noqa: BLE001
        log(f"could not save state: {e}")


def send_telegram(text: str, dry_run: bool) -> None:
    if dry_run:
        log(f"[DRY RUN] would send Telegram:\n{text}")
        return
    if not BOT_TOKEN or not CHAT_ID:
        log("TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set -- cannot send alert")
        return
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": CHAT_ID, "text": text}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=15) as r:
            r.read()
        log("Telegram alert sent")
    except Exception as e:  # noqa: BLE001
        log(f"Telegram send failed: {e}")


def check_health() -> tuple[bool, str]:
    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=10) as r:
            body = json.loads(r.read().decode())
        ok = r.status == 200 and body.get("status") == "ok"
        return ok, ("ok" if ok else f"unexpected response: {r.status} {body}")
    except Exception as e:  # noqa: BLE001
        return False, str(e)


def check_errors(state: dict) -> tuple[int, int]:
    """Count new ' ERROR ' lines since the saved byte offset; return
    (new_error_count, new_offset)."""
    if not LOG_FILE.is_file():
        return 0, 0
    size = LOG_FILE.stat().st_size
    offset = int(state.get("log_offset", 0))
    if offset > size:  # log was rotated/truncated -- start from the top
        offset = 0
    count = 0
    with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
        f.seek(offset)
        for line in f:
            if " ERROR " in line:
                count += 1
        new_offset = f.tell()
    return count, new_offset


def check_backup() -> tuple[bool, str]:
    backups = sorted(BACKUP_DIR.glob("central_logix-*.db"), key=lambda p: p.stat().st_mtime)
    if not backups:
        return False, "no backups found"
    age_h = (time.time() - backups[-1].stat().st_mtime) / 3600
    if age_h > BACKUP_MAX_AGE_H:
        return False, f"newest backup {backups[-1].name} is {age_h:.0f}h old (max {BACKUP_MAX_AGE_H:.0f}h)"
    return True, f"{backups[-1].name} is {age_h:.1f}h old"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Logix ops watchdog -> Telegram.")
    ap.add_argument("--dry-run", action="store_true", help="print alerts instead of sending")
    ns = ap.parse_args(argv)

    state = load_state()
    alerts: list[str] = []
    recoveries: list[str] = []

    # 1. Health
    healthy, hdetail = check_health()
    was_healthy = state.get("health", "up") == "up"
    if not healthy and was_healthy:
        alerts.append(f"Server DOWN — health check failed at {HEALTH_URL}\n{hdetail}")
    elif healthy and not was_healthy:
        recoveries.append("Server RECOVERED — health check OK again")
    state["health"] = "up" if healthy else "down"

    # 2. Error spike
    new_errors, new_offset = check_errors(state)
    state["log_offset"] = new_offset
    if new_errors >= ERROR_THRESHOLD:
        alerts.append(f"Error pile-up — {new_errors} new ERROR lines in logix.log "
                      f"(threshold {ERROR_THRESHOLD})")

    # 3. Backup freshness
    backup_ok, bdetail = check_backup()
    was_backup_ok = state.get("backup", "ok") == "ok"
    if not backup_ok and was_backup_ok:
        alerts.append(f"Backup problem — {bdetail}")
    elif backup_ok and not was_backup_ok:
        recoveries.append(f"Backup OK again — {bdetail}")
    state["backup"] = "ok" if backup_ok else "stale"

    save_state(state)

    for msg in alerts:
        send_telegram(f"🔴 Logix ALERT\n{msg}", ns.dry_run)
    for msg in recoveries:
        send_telegram(f"🟢 Logix\n{msg}", ns.dry_run)

    status = "PROBLEMS" if alerts else "ok"
    log(f"check done: health={state['health']} new_errors={new_errors} backup={state['backup']} -> {status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
