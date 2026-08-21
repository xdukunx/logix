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

**The server (updated after the hardening + deployment passes):**
- `server/main.py`, `server/static/*` are committed, covered by
  `tests/test_server_*.py` in CI, and hardened (§3 findings all fixed).
  Deployment is one command: `install/setup_server.py` writes `.env`
  (generating the ingest key), installs deps, and can register a boot
  service (systemd / launchd / Task Scheduler). The server auto-loads
  `server/.env` at startup. No Docker anywhere, by explicit project
  decision — plain Python + SQLite.

## 2. Public-repo readiness

Already good: thorough `.gitignore` (blocks `*.db`, `*.env`, creds, reports,
logs, pycache); MIT license; no real secrets/PII in tracked source; synthetic
test fixtures; privacy documented in the README.

Added in batch 1: `SECURITY.md`, `docs/PRIVACY.md`, `CONTRIBUTING.md`,
`server/.env.example`, `docs/config.schema.json`, issue templates, gitignore
hardening.

Still open:
- ~~Rebrand remaining hardcoded `MindLab` / `C:\lab` occurrences in the
  Windows scripts~~ **Done.** Runtime state moved from
  `%ProgramData%\MindLabLogbook` to `%ProgramData%\Logix` (one directory,
  alongside `config.env`/`device.json`); the scheduled task is
  `Logix Agent Monitor`, the HKCU Run value `LogixAgentMonitor`, the mutex
  `Global\LogixAgentMonitor`, and the launchd labels `com.logix.*`. Existing
  installs migrate on the first agent start (`Move-LogbookLegacyState`) and the
  pre-rename task/Run value are unregistered by the installer. `MindLab` now
  survives only in `LICENSE` (copyright holder) and this history.
- `server/central_logix.db` exists in working trees that ran the server
  (gitignored, confirmed untracked).

## 3. Security findings — server (verified, by severity)

| # | Sev | Finding | Location |
|---|---|---|---|
| 1 | Critical | ~~Google login mints an admin session with no auth when `GOOGLE_CLIENT_ID` is unset~~ **Resolved:** Google OAuth removed; login is email + password (`ADMIN_EMAILS` + `LOGIX_ADMIN_PASSWORD`), empty password in prod rejects all logins, rate-limited | `main.py` (`password_login`) |
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
- [x] **B. Decide + commit/exclude `server/`; drop working DB** — High / Low / Low. *(done — `server/` has been intentionally committed since the Batch 2 hardening pass; `server/central_logix.db` exists locally from testing but is gitignored and confirmed untracked via `git ls-files`)*
- [x] **C. Server security fixes** — Critical / Med / Med. *(done — all 5 sub-items verified against current code: mock auth gated behind `LOGIX_DEV_MODE` (`server/main.py` ~609), ingest key validated via `secrets.compare_digest` (~563-589), CORS never combines `["*"]` with credentials (~21-41), dashboard escapes agent-supplied fields via `escapeHtml()`, report path resolves correctly; covered by `tests/test_server_security.py`)*
- [x] **D. `event_uid` idempotency + retry/backoff + `--sync-preview`** — High / Med / Low. *(done — `event_uid` on `physical_log` (agent + server, additive migration), `/api/log` dedups by it with fallback to the old tuple match for legacy payloads; `sync_unsynced_logs()` gains `max_attempts` with exponential backoff, scoped to the explicit `--sync-to-server` CLI path only, not the non-blocking inline call; `--sync-preview` mirrors `gsheet_sync.py --dry-run`)*
- [x] **E. Device registry (`devices` table + `/api/enroll` + `device.json`)** — High / Med / Low. *(implemented; see `API_CONTRACT.md`)*
- [x] **F. Privacy-mode enforcement at agent boundary** — High / Med / Low. *(done — `paths.privacy_mode()` defaults to `local_only` per `docs/PRIVACY.md`; `/api/log` sync now gated to `admin_full_sync` only, since that endpoint is inherently full-detail; `redacted_sync`'s real delivery path remains `gsheet_sync.py`'s existing `redact()` gate. Real behavior change for any install with a server URL configured but no `LOGIX_PRIVACY_MODE` set — surfaced via a loud stderr warning, not silent)*
- [x] **G. Dashboard: modularize, add Device Registry / Detail / Sync Health, add loading/empty/error/offline/stale states** — Med / High / Low. *(done — new Devices tab: fleet stat row (total/online/stale/offline/pending), device registry table, and a Device Detail modal with policy, Sync Health counts, and recent-command history with Retry; sidebar connectivity indicator now polls `/api/health` instead of a static dot; shared `renderLoading`/`renderError`/`renderEmpty` helpers in `api.js` give Monitoring/Analytics/Devices one consistent empty/error look; a global offline banner reacts to the browser's online/offline signal)*
- [x] **H. First-run wizard (interactive + `--non-interactive`)** — Med / Med / Low. *(done — `install/install.py` is now interactive (device name, server URL, enrollment code or shared key, privacy mode with the actual `docs/PRIVACY.md` summary shown inline), mirroring `install/setup_sync.py`'s existing `prompt()`/`--non-interactive` pattern; `windows/logbook_setup.ps1` gained the privacy-mode field it was missing)*
- [x] **I. Rebrand hardcoded strings → config schema** — Med / Med / Low. *(done — `docs/config.schema.json` no longer describes speculative unimplemented fields (`product`/`organization`/`device`/`privacyMode`); it now matches `DEFAULT_CONFIG`'s real `devices`/`reports`/`privacy` shape, and `tests/test_config_schema.py` fails the build if they drift apart again)*
- [x] **J. Server deployment packaging (no Docker)** — High / Low / Low. *(done — `install/setup_server.py` (interactive + flags): writes `server/.env` from `.env.example`, generates the ingest key, optional `--install-deps` and `--service` (systemd/launchd/Task Scheduler); `server/main.py` auto-loads `server/.env` (env vars win); covered by `tests/test_setup_server.py`. Verified live end-to-end: 40-check API sweep + a real device (upgrade-in-place, heartbeat, BROADCAST delivered → shown by the timer widget → acked → audit `done`) on 2026-07-03)*

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
| 3 | Command queue hardening + real RBAC + audit log maturity | done — RBAC (6 roles, permissions-only) + command TTL/identity + agent execution acks; DB-wide expiry sweep (`reconcile_expired_actions`) plus a System Alerts feed (`device_stale`/`device_offline`/`action_failed`/`command_expired`) and a manual Retry action for failed/expired LOCK/BROADCAST commands, see `docs/LOGIX_CONTROL.md` §4 and §6 |
| 4 | Message / open website / approved program | not started |
| 5 | Lock screen (branded overlay) | not started |
| 6 | File transfer | not started |
| 7 | Screen thumbnail monitoring | not started |
| 8 | Remote view | not started |
| 9 | Remote control | not started |
| 10 | Broadcast/demo mode | not started |
| 11 | Power actions | not started |
