# Logix — Architecture

How the pieces fit together in a production (central-server) deployment.
Operations for each piece: [RUNBOOK.md](RUNBOOK.md). Hosting: [HOSTING.md](HOSTING.md).

```mermaid
flowchart TB
    subgraph Lab["Lab devices"]
        A1["Agent (Windows popup / SSH hook)<br/>heartbeat + logs, X-API-Key"]
    end

    subgraph Admin["Admins"]
        B1["Browser<br/>dashboard (Google OAuth)"]
    end

    subgraph Host["Server host (single node)"]
        C["Caddy<br/>TLS · :443 · auto Let's Encrypt"]
        D["uvicorn + FastAPI<br/>main.py · 127.0.0.1:8000"]
        subgraph Mem["in-memory (reset on restart, by design)"]
            E1["HEARTBEATS · PENDING_COMMANDS · ACTIVE_TOKENS"]
        end
        F[("central_logix.db<br/>SQLite · ALL PII")]
        G["reports/*.xlsx<br/>(generated, PII)"]
        H["logs/logix.log<br/>(rotating)"]

        subgraph Ops["ops/ — systemd timers"]
            O1["backup_db.py<br/>daily 02:30"]
            O2["cleanup_reports.py<br/>daily 03:00"]
            O3["watchdog.py<br/>every 5 min"]
        end
        I[("backups/*.db")]
    end

    T["Telegram<br/>(admin phone)"]
    U["External uptime<br/>(UptimeRobot / healthchecks.io)"]
    R["Off-host backup<br/>(rclone / rsync)"]

    A1 -- "HTTPS heartbeat/log" --> C
    B1 -- "HTTPS dashboard/API" --> C
    C -- "reverse proxy" --> D
    D --- E1
    D -- "read/write" --> F
    D -- "writes" --> G
    D -- "writes" --> H

    O1 -- "snapshot + verify" --> F
    O1 --> I
    O2 -- "prune old" --> G
    O3 -- "GET /api/health" --> D
    O3 -- "scan ERROR spikes" --> H
    O3 -- "check freshness" --> I
    O3 -- "alert" --> T
    U -- "GET /api/health" --> C
    U -- "alert" --> T
    I -. "nightly copy" .-> R
```

## Key properties
- **Single node.** In-memory session/heartbeat/command state is a deliberate
  choice for this scale; it means a restart drops active sessions (re-login)
  but keeps all persistent data in SQLite. Horizontal scaling is out of scope
  (see RUNBOOK "Capacity & scaling").
- **The server never faces the internet directly.** uvicorn binds to
  `127.0.0.1`; only Caddy (TLS) is public. All PII lives in one SQLite file on
  the host.
- **Two monitoring layers.** The local watchdog catches app/DB/backup problems;
  an external uptime check catches full-host outages the local one can't report.
- **Privacy boundary.** Everything in the dashed "PII" stores (`central_logix.db`,
  `reports/`, `backups/`) stays on the operator's controlled host — see
  [PRIVACY.md](PRIVACY.md).
