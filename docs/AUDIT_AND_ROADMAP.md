# Logix — audit & evolution roadmap

Evidence-based review of the repository as inspected, plus the staged plan to
evolve it into a public-ready, multi-device management tool. Line references
point at the commit reviewed; treat them as approximate if the code has moved.

## 1. Current state (what is true today)

**Mature and recommended — the core:**
- `logix/log_physical.py` — idempotent SQLite bridge; three capture paths merge
  here; supports `--sync-to-server` and a `synced` flag. 23 tests pass.
- `logix/paths.py` — single source of config resolution (env → `config.env` →
  OS default). Already exposes `server_url()` / `server_api_key()`.
- `logix/gsheet_sync.py` — privacy-first redaction gate (whitelist: date /
  member-token / session_type / hours), tested across `initials|hash|code`.
- `install/` — stdlib-only, idempotent, cross-OS installer. Installs the core
  only (not the server).
- `windows/` — WPF sign-in popup with a cascading JSON rebrand config.

**Preview / not production-ready — the server:**
- `server/main.py`, `server/static/*` are **untracked in git**, absent from CI,
  untested, and not installed by the installer. They hold the project's only
  serious security issues (§3).

## 2. Public-repo readiness

Already good: thorough `.gitignore` (blocks `*.db`, `*.env`, creds, reports,
logs, pycache); MIT license; no real secrets/PII in tracked source; synthetic
test fixtures; privacy documented in the README.

Added in batch 1: `SECURITY.md`, `docs/PRIVACY.md`, `CONTRIBUTING.md`,
`server/.env.example`, `docs/config.schema.json`, issue templates, gitignore
hardening.

Still open:
- Decide whether to commit `server/` (after hardening) or exclude it.
- Remove the working-tree `server/central_logix.db` (ignored, but present).
- Rebrand ~75 hardcoded `FTMM` / `MindLab` / `C:\lab` / brand-hex /
  `admin@logix.com` / `admin123` occurrences across 17 files into config.
- Add CI coverage for the server module if it is kept.

## 3. Security findings — server (verified, by severity)

| # | Sev | Finding | Location |
|---|---|---|---|
| 1 | Critical | Google login mints an admin session with no auth when `GOOGLE_CLIENT_ID` is unset (the default) | `main.py` ~192–202 |
| 2 | High | `/api/log` and `/api/heartbeat` accept `X-API-Key` but never validate it — unauthenticated PII ingest / heartbeat spoofing | `main.py` 331–346, 395–442 |
| 3 | High | Stored XSS: unauthenticated ingest rendered into dashboard via `innerHTML` without escaping | `main.py` (2) + `static/app.js` 163, 388 |
| 4 | High | `CORSMiddleware(allow_origins=["*"], allow_credentials=True)` — invalid/unsafe combination | `main.py` 21–27 |
| 5 | Med | Weak hardcoded defaults `admin123` / `admin@logix.com`; also dead code (no route uses `LoginRequest`/`get_admin_password`) | `main.py` 90–96, 150–155 |
| 6 | Med | Session token passed in URL query string on redirect (history/referrer/log leak) | `main.py` 202, 262 |
| 7 | Low | `/api/reports` shells out to a non-existent path (`BASE_DIR.parent/"logbook_report.py"`; script is in `logix/`) — endpoint 500s | `main.py` 556–557 |
| 8 | Low | Tokens/heartbeats/commands in memory (lost on restart); no rate limiting | `main.py` 36–44 |

## 4. Target architecture

Local agent (source of truth) → authenticated HTTPS sync → central server
(read/aggregate mirror) → hardened dashboard. One config schema shared by
agent, popup, dashboard, and server. Device identity is a first-class object
stored locally first, enrolled to the server when reachable.

### Device model (new `devices` table + local `device.json`)

```
device_id (uuid, stable PK), hostname, display_name,
category (lab_workstation|office_workstation|loaned_laptop|mobile_device|server|custom),
owner, location, tags (json), status (enrolled|active|stale|retired),
enrolled_at, last_seen (persisted), privacy_mode, sync_enabled
```

Category drives defaults via a config table (not code): lab → popup required;
loaned laptop → headless auto-sync; server → SSH/system only.

### Sync (build on the existing `synced` flag)

- Add client-generated `event_uid` (uuid per row) as the idempotency key;
  server uses `INSERT ... ON CONFLICT DO NOTHING`. Additive migration in the
  existing `migrate()`.
- Wrap `sync_unsynced_logs()` in exponential backoff + jitter + max attempts;
  keep the 3s inline attempt; add a scheduled catch-up (reuse `setup_sync.py`'s
  systemd/launchd/Task-Scheduler machinery).
- Add `--sync-preview` (mirrors `gsheet_sync.py --dry-run`) honoring
  `privacy_mode`.

### Privacy enforcement at the agent boundary

`local_only` (default) never calls `/api/log`; `redacted_sync` runs rows through
the existing redaction before push; `admin_full_sync` requires explicit opt-in +
user notice. See `docs/PRIVACY.md`.

## 5. Staged roadmap (impact / effort / risk)

- [x] **A. Public-repo docs & schema** — High / Low / None. *(batch 1, done)*
- [ ] **B. Decide + commit/exclude `server/`; drop working DB** — High / Low / Low.
- [x] **C. Server security fixes** — Critical / Med / Med. *(done — all 5 sub-items verified against current code: mock auth gated behind `LOGIX_DEV_MODE` (`server/main.py` ~609), ingest key validated via `secrets.compare_digest` (~563-589), CORS never combines `["*"]` with credentials (~21-41), dashboard escapes agent-supplied fields via `escapeHtml()`, report path resolves correctly; covered by `tests/test_server_security.py`)*
- [ ] **D. `event_uid` idempotency + retry/backoff + `--sync-preview`** — High / Med / Low (additive migration).
- [x] **E. Device registry (`devices` table + `/api/enroll` + `device.json`)** — High / Med / Low. *(implemented; see `API_CONTRACT.md`)*
- [ ] **F. Privacy-mode enforcement at agent boundary** — High / Med / Low.
- [ ] **G. Dashboard: modularize, add Device Registry / Detail / Sync Health, add loading/empty/error/offline/stale states** — Med / High / Low.
- [ ] **H. First-run wizard (interactive + `--non-interactive`)** — Med / Med / Low.
- [ ] **I. Rebrand hardcoded strings → config schema** — Med / Med / Low. *(partial: default values rebranded FTMM/MindLab→Logix; full config-schema abstraction not done)*

## 6. Migration & compatibility

- All schema changes are **additive** (new columns/tables) via the idempotent
  `migrate()`; existing local databases keep working with no manual step.
- Item C changes server runtime behavior; it will be gated by `LOGIX_DEV_MODE`
  so existing local dev workflows are preserved when the flag is set.
- No change to the capture front-ends' on-disk formats is planned.

## 7. Logix Control subsystem roadmap

A separate, larger initiative layered on top of items A-I above: Veyon-like
remote lab-device management (screen view, remote control, lock, broadcast,
file transfer, power actions, RBAC, audit log), custom-built for
institution-managed devices. Full architecture and current status in
[docs/LOGIX_CONTROL.md](LOGIX_CONTROL.md) — this table is the roadmap of
record; that document explains the *why* and links back here for the *what
stage*.

**Non-negotiable ordering constraint:** screen streaming and remote control
are not designed in code-level detail, let alone built, until
authentication, a real permission model, an audit log, a policy model, and
persisted device identity all exist and are hardened. Milestones 1-2 build
exactly those foundations and nothing else.

| # | Milestone | Status |
|---|---|---|
| 1 | Public repo/docs/architecture cleanup | in progress |
| 2 | Device registry + heartbeat persistence | done — safe parts only; streaming/control explicitly deferred |
| 3 | Command queue hardening + real RBAC + audit log maturity | done — RBAC (6 roles, permissions-only) + command TTL/identity + agent execution acks, see `docs/LOGIX_CONTROL.md` §4 and §6 |
| 4 | Message / open website / approved program | not started |
| 5 | Lock screen (branded overlay) | not started |
| 6 | File transfer | not started |
| 7 | Screen thumbnail monitoring | not started |
| 8 | Remote view | not started |
| 9 | Remote control | not started |
| 10 | Broadcast/demo mode | not started |
| 11 | Power actions | not started |
