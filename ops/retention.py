#!/usr/bin/env python3
"""Enforce the personal-data retention window on the session log.

Logix records a student's nama and NIM against every session. That is
necessary while a session is recent -- it is how an admin answers "who was on
WS-04 last Tuesday" -- and unnecessary a year later, when all anyone needs
from that row is that WS-04 was busy for two hours doing DFT.

So this REDACTS rather than deletes: nama, NIM, the Windows username and the
free-text keterangan are overwritten in place, and the session shape (when,
which workstation, which purpose, how long) is left intact. Deleting the rows
would throw away the utilisation history along with the personal data, which
is the opposite of the trade a lab wants.

  python3 ops/retention.py --dry-run     # count what would be redacted
  python3 ops/retention.py               # redact, using the configured window
  python3 ops/retention.py --days 180    # override the window

The window comes from server_config.json's privacy.retention_days (default
365). Setting it to 0 disables purging -- a deliberate choice a deployment has
to make, not something that happens by forgetting to configure it.

Idempotent: rows already redacted are skipped, so running this on a timer
costs nothing and re-running after a restore is safe.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DB = REPO / "server" / "central_logix.db"
SERVER_CONFIG = REPO / "server" / "server_config.json"
DEFAULT_RETENTION_DAYS = 365

# Must match server/main.py's REDACTED_MARKER, which is what makes the "skip
# rows already done" check work in both places.
REDACTED_MARKER = "[redacted]"


def configured_days(config_path: Path = SERVER_CONFIG) -> int:
    try:
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
        return int(cfg.get("privacy", {}).get("retention_days", DEFAULT_RETENTION_DAYS))
    except (OSError, ValueError, TypeError):
        return DEFAULT_RETENTION_DAYS


def purge(db_path: Path, days: int, dry_run: bool = False,
          now: datetime | None = None) -> int:
    if days <= 0:
        print(f"retention_days={days}: purging disabled, nothing to do.")
        return 0
    if not db_path.exists():
        print(f"database not found: {db_path}", file=sys.stderr)
        return -1

    cutoff = ((now or datetime.now()) - timedelta(days=days)).isoformat()
    conn = sqlite3.connect(str(db_path))
    try:
        where = ("WHERE timestamp < ? AND (nama IS NOT NULL AND nama != '' AND nama != ?)")
        args = (cutoff, REDACTED_MARKER)
        (count,) = conn.execute(f"SELECT COUNT(*) FROM physical_log {where}", args).fetchone()
        if dry_run:
            print(f"[dry-run] would redact {count} row(s) older than {cutoff}")
            return count
        if count:
            conn.execute(
                "UPDATE physical_log SET nama = ?, nim = ?, username = ?, windows_user = ?, "
                f"keterangan = ?, raw_json = NULL {where}",
                (REDACTED_MARKER, REDACTED_MARKER, REDACTED_MARKER, REDACTED_MARKER,
                 REDACTED_MARKER, *args),
            )
            conn.commit()
        print(f"redacted {count} row(s) older than {cutoff} ({days}-day window)")
        return count
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    ap.add_argument("--days", type=int, default=None,
                    help="override privacy.retention_days from server_config.json")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would be redacted and change nothing")
    args = ap.parse_args(argv)

    days = args.days if args.days is not None else configured_days()
    result = purge(args.db, days, dry_run=args.dry_run)
    return 1 if result < 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
