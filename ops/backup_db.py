#!/usr/bin/env python3
"""Daily backup of the Logix central database.

The DB (server/central_logix.db) holds ALL of Logix's PII -- names, NIMs, IPs,
session history, the audit log. A disk failure with no backup = total loss.
This takes a consistent ONLINE snapshot (sqlite3 backup API, safe to run while
the server is serving), verifies it, and rotates old copies.

  python3 ops/backup_db.py                 # back up + prune with defaults
  python3 ops/backup_db.py --keep-days 30

Config via env (flags win): LOGIX_DB, LOGIX_BACKUP_DIR, LOGIX_BACKUP_KEEP_DAYS.

Exit code 0 on success, non-zero on failure -- so systemd marks the unit failed
and the ops watchdog can alert. No stdlib-external dependencies.
"""
from __future__ import annotations

import argparse
import os
import sqlite3
import time
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DB = Path(os.environ.get("LOGIX_DB", REPO / "server" / "central_logix.db"))
DEFAULT_BACKUP_DIR = Path(os.environ.get("LOGIX_BACKUP_DIR", REPO / "server" / "backups"))
DEFAULT_KEEP_DAYS = int(os.environ.get("LOGIX_BACKUP_KEEP_DAYS", "14"))
PREFIX = "central_logix-"


def log(msg: str) -> None:
    print(f"{datetime.now().isoformat(timespec='seconds')} backup: {msg}", flush=True)


def online_backup(src: Path, dest: Path) -> None:
    """Consistent snapshot via SQLite's backup API -- copies a transactionally
    consistent image even while the server is writing, unlike a file copy."""
    src_conn = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    try:
        dest_conn = sqlite3.connect(dest)
        try:
            src_conn.backup(dest_conn)
        finally:
            dest_conn.close()
    finally:
        src_conn.close()


def integrity_ok(db: Path) -> bool:
    conn = sqlite3.connect(db)
    try:
        row = conn.execute("PRAGMA integrity_check").fetchone()
        return bool(row) and row[0] == "ok"
    finally:
        conn.close()


def prune(backup_dir: Path, keep_days: int) -> int:
    cutoff = time.time() - keep_days * 86400
    removed = 0
    for f in backup_dir.glob(f"{PREFIX}*.db"):
        if f.stat().st_mtime < cutoff:
            f.unlink()
            removed += 1
    return removed


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Back up the Logix central DB.")
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    ap.add_argument("--backup-dir", type=Path, default=DEFAULT_BACKUP_DIR)
    ap.add_argument("--keep-days", type=int, default=DEFAULT_KEEP_DAYS)
    ns = ap.parse_args(argv)

    if not ns.db.is_file():
        log(f"ERROR: database not found at {ns.db}")
        return 2
    ns.backup_dir.mkdir(parents=True, exist_ok=True)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = ns.backup_dir / f"{PREFIX}{stamp}.db"
    try:
        online_backup(ns.db, dest)
    except Exception as e:  # noqa: BLE001
        log(f"ERROR: backup failed: {e}")
        return 1

    if not integrity_ok(dest):
        log(f"ERROR: integrity_check FAILED on {dest.name}; deleting corrupt backup")
        dest.unlink(missing_ok=True)
        return 1

    size_mb = dest.stat().st_size / 1_048_576
    removed = prune(ns.backup_dir, ns.keep_days)
    kept = len(list(ns.backup_dir.glob(f"{PREFIX}*.db")))
    log(f"OK {dest.name} ({size_mb:.2f} MB), integrity ok; pruned {removed}, kept {kept} "
        f"(retention {ns.keep_days}d)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
