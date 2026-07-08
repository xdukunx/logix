# Hosting the Logix central server

The central server ([`server/`](../server/)) is **optional**. The lab agent
works completely standalone — you only need this if you want to see all your
workstations on one dashboard, run remote lock/message/screenshot actions, or
download fleet-wide reports.

It's a small FastAPI app with **no Docker and no external database** — just
Python + SQLite (the DB file is created automatically on first run).

> **Running it in production?** After the setup below, wire up day-2 operations
> — backups, monitoring/alerting, log handling, capacity limits — from the
> **[Operations Runbook](RUNBOOK.md)**. System overview: **[Architecture](ARCHITECTURE.md)**.

---

## 1. One-command setup (recommended)

```bash
git clone https://github.com/xdukunx/logix.git
cd logix
python3 install/setup_server.py --install-deps --service
```

This is interactive: it asks for admin email(s), Google OAuth (optional),
allowed origins; **generates a strong device API key**; writes `server/.env`;
installs dependencies; and (with `--service`, run elevated) registers the
server to start on every boot — systemd on Linux, launchd on macOS, Task
Scheduler on Windows. At the end it prints the exact `LOGIX_SERVER_URL` /
`LOGIX_SERVER_API_KEY` pair to give each device.

Every value can also be passed as a flag (`--admin-emails`, `--ingest-key`,
`--port`, …) for unattended setup — run with `--help` for the list.

### Build the dashboard once

The dashboard is a React app that must be built once (it's served by the
Python server):

```bash
cd frontend
npm install && npm run build     # produces frontend/dist/
```

If the server host has no Node.js, build `frontend/dist/` on another machine
and copy it over. If `dist/` is absent, the server falls back to the legacy
static dashboard automatically.

---

## 2. Quick local trial (evaluation only)

```bash
cd server
pip install -r requirements.txt
cp .env.example .env      # fill in — main.py auto-loads server/.env on start
uvicorn main:app --host 0.0.0.0 --port 8000
```

The defaults are deliberately locked down. Configure these before any
shared/production use:

| Env var | Purpose |
|---|---|
| `LOGIX_DEV_MODE` | `0` (default) = production posture. `1` = local dev only: **unauthenticated mock admin login** + permissive CORS. Never `1` on a reachable server. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | Google OAuth for the dashboard. Required for real auth outside dev mode. |
| `ADMIN_EMAILS` | Comma-separated allowlist of Google accounts allowed to sign in. |
| `LOGIX_INGEST_API_KEY` | Shared secret devices send as `X-API-Key`. Required outside dev mode. Generate with `openssl rand -hex 32`. |
| `LOGIX_ALLOWED_ORIGINS` | Comma-separated dashboard origins for CORS — e.g. `https://logix.example.org`. |

See [SECURITY.md](../SECURITY.md) for the current hardening status.

---

## 3. Running it for real (production)

The server has no built-in TLS and keeps tokens/heartbeats in memory (lost on
restart, by design). It's meant to sit **behind a reverse proxy** on a host you
control, bound to `127.0.0.1` — never exposed directly to the internet.

### Run it as a service, bound to localhost

`setup_server.py --service` does this for you (writes the systemd unit / launchd
plist / scheduled task). If you prefer to do it by hand on Linux:

```ini
# /etc/systemd/system/logix-server.service
[Unit]
Description=Logix central admin server
After=network.target

[Service]
Type=simple
User=logix
WorkingDirectory=/opt/logix/server
EnvironmentFile=/opt/logix/server/.env
ExecStart=/opt/logix/server/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd --system --no-create-home logix
sudo chown -R logix:logix /opt/logix
sudo systemctl enable --now logix-server
```

### Put HTTPS in front

The dashboard sends session tokens and devices send API keys in headers — this
**must be HTTPS** on anything reachable beyond localhost.

**Caddy (simplest — automatic Let's Encrypt):** a ready-to-edit config is in
[`docs/deploy/Caddyfile`](deploy/Caddyfile). Point your domain's DNS at the
host, edit the domain in that file, and `systemctl reload caddy`. Caddy handles
certificate issuance and renewal for you.

**nginx + certbot (if you already run nginx):**

```nginx
server {
    listen 443 ssl;
    server_name logix.example.org;
    ssl_certificate     /etc/letsencrypt/live/logix.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/logix.example.org/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

`certbot --nginx` issues and renews the certificate.

**Either way:** set `LOGIX_ALLOWED_ORIGINS` and `GOOGLE_REDIRECT_URI` to the
same `https://logix.example.org` domain, and register that redirect URI in the
Google Cloud Console. Only port `443` (and `80` for the ACME challenge) should
be open publicly; `8000` stays bound to localhost.

---

## 4. Pointing devices at the server

Give each device's setup window the server URL and the `LOGIX_INGEST_API_KEY`
value, or set them directly in the device's `config.env`:

```bash
LOGIX_SERVER_URL=https://logix.example.org
LOGIX_SERVER_API_KEY=<same value as LOGIX_INGEST_API_KEY>
```

For a real deployment, prefer **per-device enrollment** (each device gets its
own revocable key instead of sharing one): generate an invite code from the
dashboard's **Devices → Enroll device**, and enter it in the device installer.
See [API_CONTRACT.md](../API_CONTRACT.md).

Devices appear on the dashboard, by whatever name was set during install, as
soon as their next heartbeat arrives (every 30s while the monitor runs).

> **A configured server URL alone does not sync session data.** Per
> [PRIVACY.md](PRIVACY.md)'s "default = safest" policy, nothing leaves a device
> unless `LOGIX_PRIVACY_MODE=admin_full_sync` is also set. Preview what would be
> sent: `python logix/log_physical.py --sync-preview`.
