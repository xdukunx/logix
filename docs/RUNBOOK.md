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
- **Restore drill** (practice it before you need it):
  ```bash
  sudo systemctl stop logix-server
  cp server/backups/central_logix-YYYYMMDD-HHMMSS.db server/central_logix.db
  sqlite3 server/central_logix.db "PRAGMA integrity_check;"   # expect: ok
  sudo systemctl start logix-server
  ```

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
