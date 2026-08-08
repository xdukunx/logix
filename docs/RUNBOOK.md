# Logix Server — Operations Runbook

Day-2 operations for the central server: deploy, back up, restore, rotate keys,
read logs, respond to alerts, and know the capacity limits. Assumes the
Linux + systemd + Caddy deployment from [HOSTING.md](HOSTING.md).

Architecture overview: [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Deploy / update

```bash
cd /opt/logix && git pull
cd frontend && npm ci && npm run build          # rebuild the dashboard
sudo systemctl restart logix-server             # in-memory sessions reset (by design)
```
The server auto-loads `server/.env`. After an env change, restart the service.

## Monitoring & alerting

Two layers — you want both:
1. **Local watchdog** (`ops/watchdog.py`, every 5 min via `logix-watchdog.timer`):
   health check + error-log spike + backup freshness → **Telegram**.
2. **External uptime** (UptimeRobot / healthchecks.io): HTTP check on
   `https://<domain>/api/health` every 1–5 min. This is the only thing that
   catches a fully-down host/network — the local watchdog can't alert if the
   box it runs on is down. Set it up in that service's web UI; no code needed.

Set alert creds in `server/.env`: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.
Test: `python3 ops/watchdog.py --dry-run`.

### Responding to a Telegram alert
| Alert | First checks |
|---|---|
| **Server DOWN** | `systemctl status logix-server`; `journalctl -u logix-server -n 100`; is the host up / disk full (`df -h`)? |
| **Error pile-up** | `tail -100 server/logs/logix.log`; look for the repeated `ERROR`; check DB/disk permissions. |
| **Backup problem** | `systemctl status logix-backup`; `journalctl -u logix-backup -n 50`; disk space in `server/backups`. |

## Logs

- App log: `server/logs/logix.log` (rotating, 5×5 MB). Also in the journal:
  `journalctl -u logix-server -f`.
- Level: set `LOGIX_LOG_LEVEL=DEBUG` in `.env` + restart to increase verbosity.
- Logs describe *what* failed, never row contents — but the journal/host is
  still trusted infrastructure; treat access accordingly.

## Backups & restore

- **Backup** runs daily 02:30 (`logix-backup.timer`) → timestamped snapshot in
  `server/backups/`, integrity-checked, 14-day retention. Run now:
  `python3 ops/backup_db.py`.
- **Off-host copy (do this):** backups on the same disk don't survive a disk
  loss. Add a nightly push, e.g. a cron/timer running
  `rclone copy server/backups remote:logix-backups` or `rsync` to another host.
- **Restore** — use `ops/restore_db.py`, not a bare `cp`. It refuses to write
  over a database the server still has open, keeps the current one aside as
  `central_logix.pre-restore-<stamp>.db`, integrity-checks the *restored* file
  (not just the source), and migrates an older snapshot up to the current
  schema — a backup taken before a column was added restores fine with `cp` and
  then breaks the app at runtime.
  ```bash
  sudo systemctl stop logix-server        # Windows: Stop-ScheduledTask -TaskName "LogixServer"
  python3 ops/restore_db.py --list        # what is available
  python3 ops/restore_db.py --latest      # or --from <path>
  sudo systemctl start logix-server
  ```
  `--dry-run` verifies a snapshot is readable and passes integrity_check
  without touching anything. Practise it before you need it; the round trip is
  covered by `tests/test_ops_backup_restore.py`, but a drill on the real host
  is what proves your backups are where you think they are.

## Personal-data retention

`privacy.retention_days` in `server_config.json` (default 365) bounds how long
a student's nama, NIM, Windows username and free-text keterangan stay attached
to a session. Past the window `ops/retention.py` **redacts those fields in
place** — it does not delete the row, because the session shape (when, which
workstation, which purpose, how long) is what utilisation reporting needs and
none of it identifies anybody.

```bash
python3 ops/retention.py --dry-run     # count what would be redacted
python3 ops/retention.py               # enforce the configured window
```

Set `retention_days` to `0` to disable purging. That is a deliberate choice to
make, not a default to drift into — a university keeping student names forever
because nobody set a number is the situation this exists to prevent.

## Windows hosts

The scheduled jobs above are systemd timers on Linux. On Windows,
`install/setup_server.py --service` registers the same four as Task Scheduler
entries alongside the server task:

| Task | When | What |
| --- | --- | --- |
| `LogixServer` | at startup | the server itself |
| `LogixServer-Backup` | daily 02:30 | database backup, integrity-checked |
| `LogixServer-CleanupReports` | daily 03:00 | prune generated `.xlsx` (PII) |
| `LogixServer-Retention` | daily 03:15 | enforce the retention window |
| `LogixServer-Watchdog` | every 10 min | health / errors / backup freshness |

They use `-StartWhenAvailable`, the equivalent of systemd's `Persistent=true`,
so a host that was switched off overnight catches up instead of silently
skipping a backup. Inspect with
`Get-ScheduledTask -TaskName "LogixServer-*" | Get-ScheduledTaskInfo`.

## Agent versions

Every heartbeat now carries the agent's build, read from the `VERSION` file
shipped beside its scripts, and the Devices tab shows it per workstation. Check
for drift before it becomes a support call:

```bash
sqlite3 server/central_logix.db "SELECT hostname, agent_version, last_seen FROM devices ORDER BY agent_version;"
```

A workstation reporting `NULL` is running a build from before version
reporting, or was updated by hand-copying files without the `VERSION` stamp.
`windows/update_installed_client.ps1` copies the whole set together for exactly
that reason.

## Report cleanup

`logix-cleanup.timer` prunes `server/reports/*.xlsx` (PII) older than 7 days
daily. Reports regenerate on demand, so retention can be short.

## Key & secret rotation

- **Ingest key** (`LOGIX_INGEST_API_KEY`): prefer per-device enrollment keys
  (dashboard → Devices → Enroll device) so you can revoke one device without
  re-keying the fleet. To rotate the shared key: set a new value in `.env`,
  restart, update each device's `config.env`.
- **Admin password**: rotate by setting a new `LOGIX_ADMIN_PASSWORD` in `.env`
  and restarting. Existing admin sessions are in-memory and drop on restart (re-login).
- Never commit `.env`, `*.db`, backups, reports, or logs — all gitignored.

## Capacity & scaling

Measured baseline (ingest hot path, `/api/heartbeat`, dev-class hardware):
**~42 req/s sustained, 0 errors; p95 latency climbs sharply above ~40
concurrent beats** (SQLite serializes writes; each beat also runs an expiry
sweep). Re-measure on your hardware: `python3 ops/loadtest/loadtest.py` (see
[ops/loadtest/](../ops/loadtest/)).

Interpretation: at a 30–60 s heartbeat interval this comfortably serves the
target scale (hundreds of devices — hundreds of devices ÷ 30 s ≈ a few req/s).
If you outgrow it, in priority order — **not** horizontal scaling (in-memory
state makes that a rewrite):
1. Enable **SQLite WAL mode** (`PRAGMA journal_mode=WAL`) — biggest win for
   concurrent read/write; the single cheapest change.
2. Trim per-beat DB work (the expiry sweep needn't run on every heartbeat).
3. Only then consider externalizing state (Redis) for a multi-node setup.

## Disaster recovery (host lost)
1. New host → follow [HOSTING.md](HOSTING.md) (clone, venv, `.env`, service, Caddy).
2. Restore the newest **off-host** DB backup to `server/central_logix.db`.
3. `npm ci && npm run build`; start the service; re-point DNS.
4. Devices reconnect automatically on their next heartbeat.
