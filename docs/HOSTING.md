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

## 0. Requirements & sizing a VM

| | Needed |
|---|---|
| OS | Linux, macOS, or Windows — CI runs the test suite on Ubuntu and Windows |
| Python | 3.11+ (CI tests 3.11 and 3.12; there's no hard floor lower than that) |
| Node.js | Optional — only used to build the React dashboard at install time. Without it, the server serves the built-in static UI instead, with no loss of function. |
| Dependencies | `fastapi`, `uvicorn`, `openpyxl` — no external database, no Docker |

**Sizing a VM:** the server is one `uvicorn` process talking to a local SQLite
file — no worker pool, no queue, no background jobs beyond the odd export.
Devices are quiet by design: each one only calls in on a heartbeat (5 seconds
by default, `LOGIX_HEARTBEAT_SECONDS`) plus the occasional session sync, and
this project is deliberately scoped to **self-hosted, low hundreds of
devices** per server, not a multi-tenant SaaS load. For that shape:

* **A single lab (up to ~50 workstations):** 1 vCPU, 1 GB RAM, 10 GB disk.
  This is a conservative floor, not a benchmarked ceiling — it hasn't been
  load-tested against real traffic, but the workload (small JSON requests,
  a single-writer SQLite DB) is light enough that headroom is expected.
* **A full building (a few hundred devices):** 2 vCPU, 2 GB RAM, 20 GB disk
  gives comfortable headroom for the same shape of traffic at higher volume.
* **Disk** is mostly the SQLite DB and exported reports, not logs or media —
  10 GB is generous for years of session history at this scale.

If you outgrow "low hundreds of devices," that's a re-architecture (a real
DB server, multiple app workers), not a bigger VM — see
[Architecture](ARCHITECTURE.md).

---

## 1. One-command setup (recommended)

**Fresh Linux/macOS host, one line** — clones the repo, checks/installs
Python + git, builds the dashboard if Node is available, then runs the
installer below:

```bash
curl -fsSL https://raw.githubusercontent.com/xdukunx/logix/main/install/bootstrap-server.sh | bash
```

**Windows**, same idea:

```powershell
irm https://raw.githubusercontent.com/xdukunx/logix/main/install/bootstrap-server.ps1 | iex
```

Like any pipe-to-shell installer, you should read it first —
`curl -fsSL <url> -o bootstrap-server.sh && less bootstrap-server.sh`. It's a
thin wrapper: fetch the code, best-effort install prerequisites, build the
dashboard, then hand off to the same `install/setup_server.py` described
below — nothing it does isn't visible in that one file plus this one.

To pass flags (admin emails, `--service`, a custom install dir, …) instead of
answering prompts:

```bash
# Linux/macOS — bash -s -- forwards args through the pipe
curl -fsSL .../bootstrap-server.sh | bash -s -- --admin-emails you@example.org --service
```
```powershell
# Windows — irm | iex can't take named args; download then run instead
iwr -useb .../bootstrap-server.ps1 -OutFile bootstrap-server.ps1
.\bootstrap-server.ps1 -AdminEmails "you@example.org" -Service
```

Already have the repo cloned, or prefer to see every step yourself? Run the
installer directly — this is exactly what the one-liner above calls after
fetching the code and building the dashboard:

```bash
git clone https://github.com/xdukunx/logix.git
cd logix
cd frontend && npm install && npm run build && cd ..   # optional — builds the React dashboard
python3 install/setup_server.py --install-deps --service
```

Either way it's interactive: it asks for admin email(s), an admin login
password, allowed origins; **generates a strong device API key**; writes
`server/.env`; installs dependencies; and (with `--service`, run elevated)
registers the server to start on every boot — systemd on Linux, launchd on
macOS, Task Scheduler on Windows. At the end it prints the exact
`LOGIX_SERVER_URL` / `LOGIX_SERVER_API_KEY` pair to give each device.

Every value can also be passed as a flag (`--admin-emails`, `--ingest-key`,
`--port`, …) for unattended setup — run `setup_server.py --help` for the list.
If the server host has no Node.js, the dashboard build is skipped and the
server falls back to serving the legacy static UI automatically.

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
| `LOGIX_DEV_MODE` | `0` (default) = production posture. `1` = local dev only: default admin password `admin123` + passwordless `/api/auth/dev-login` + permissive CORS. Never `1` on a reachable server. |
| `LOGIX_ADMIN_PASSWORD` | Admin login password. **Required for real auth** outside dev mode — empty in production rejects every login (no backdoor). Use a strong value. |
| `ADMIN_EMAILS` | Comma-separated allowlist of admin emails allowed to sign in (optionally `email:role`). |
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

**Either way:** set `LOGIX_ALLOWED_ORIGINS` to your `https://logix.example.org`
domain. Only port `443` (and `80` for the ACME challenge) should be open
publicly; `8000` stays bound to localhost.

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
