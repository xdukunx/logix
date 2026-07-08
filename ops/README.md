# ops/ — production operations for the Logix server

Small, stdlib-only scripts for running the central server in production. All
are safe to run by hand and are scheduled on the server via the systemd units
in [`systemd/`](systemd/). Full runbook: [`docs/RUNBOOK.md`](../docs/RUNBOOK.md).

| Script | What it does | Schedule |
|---|---|---|
| [`backup_db.py`](backup_db.py) | Consistent online snapshot of `central_logix.db` + integrity check + retention | daily 02:30 |
| [`cleanup_reports.py`](cleanup_reports.py) | Prune generated `reports/*.xlsx` (PII) older than N days | daily 03:00 |
| [`watchdog.py`](watchdog.py) | Health check + error-log spike + backup freshness → **Telegram** alert | every 5 min |
| [`loadtest/`](loadtest/) | Capacity test of the `/api/heartbeat` ingest path | on demand |

## Install the scheduled jobs (Linux + systemd)

Adjust the paths / `User=` in the `.service` files to match your deploy
(HOSTING.md uses `/opt/logix` and user `logix`), then:

```bash
sudo cp ops/systemd/logix-*.service ops/systemd/logix-*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now logix-backup.timer logix-cleanup.timer logix-watchdog.timer
systemctl list-timers 'logix-*'          # confirm they're scheduled
```

## Alerts (Telegram)

Set `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` in `server/.env` (create a bot via
@BotFather, get your chat id from @userinfobot). Test without sending:

```bash
python3 ops/watchdog.py --dry-run
```

Because a local watchdog can't report that the whole host is down, **also** add
an external uptime check (UptimeRobot / healthchecks.io) on
`https://<domain>/api/health` — see the RUNBOOK.
