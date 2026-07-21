# Logix — Product Requirements Document (PRD)

> **Log · Track · Integrate** — a privacy-first sign-in logbook for shared lab
> computers.

| | |
|---|---|
| **Product** | Logix |
| **Document status** | Living document — reflects the shipped system as of this revision |
| **Owner** | MindLab (lab operations) |
| **Repository** | https://github.com/xdukunx/logix |
| **Primary deployment** | Shared workstations in a university faculty lab (physical + remote/AnyDesk access) |
| **License** | MIT |

---

## 1. Summary

Logix answers one question for a room full of shared computers: **who used
this machine, when, and for what purpose** — without ever spying on *what* they
did on screen. Each lab PC runs a lightweight Windows agent that shows a
sign-in screen at logon/unlock, tracks the session with a small on-screen
timer, and reports session metadata to a central server. Admins see live device
status, session history, and analytics on a web dashboard, and can take a small
set of clearly-disclosed remote actions (lock, message, screenshot, power).

The product's defining constraint is **privacy by construction**: it records
identity and intent (name, ID, access type, purpose, notes, timestamps) and
*nothing about screen contents, keystrokes, files, or applications*. The only
screen capture that exists is admin-triggered and is always announced to the
person at the device.

---

## 2. Problem & motivation

Shared lab machines create an accountability gap:

- **No record.** When anyone can sit down and use a machine, there is no way to
  attribute usage, reconstruct "who was on WS-07 at 3pm", or produce a usage
  report for lab governance.
- **Privacy-invasive alternatives.** Off-the-shelf "monitoring" tools solve
  attribution by recording screens, keystrokes, or activity — unacceptable for
  a lab that must respect the people using it (students, staff, guests).
- **Remote access blind spots.** Labs increasingly allow remote sessions
  (AnyDesk); a logbook that only knows about physical logins misses half the
  picture.

Logix fills the gap with a **consent-first sign-in** (the user actively states
who they are and why) plus **metadata-only** session tracking, and treats
remote (AnyDesk) sessions as first-class.

---

## 3. Goals & non-goals

### 3.1 Goals

1. Attribute every session on a shared machine to a stated identity and purpose.
2. Record **only** who/how/when — never screen content, keystrokes, or activity.
3. Give admins a live, single-pane view of all lab devices and their sessions.
4. Provide a small, **always-disclosed** remote-assist toolkit (lock, message,
   screenshot, power) for lab support.
5. Be deployable on a fresh Windows PC in minutes, and re-pointed/updated
   idempotently.
6. Export session data to spreadsheets/reports for lab governance, with a
   redaction gate for any external sync.
7. Run on plain infrastructure — native services, no Docker required.

### 3.2 Non-goals

- **Not** an employee-surveillance or productivity-tracking tool. No screen
  recording, no keylogging, no idle-shaming, no per-app time tracking.
- **Not** a device-management/MDM suite (no software deployment, patching, or
  policy push beyond the agent's own settings).
- **Not** a public multi-tenant SaaS — it targets a single lab/organization
  running its own server on a trusted network.
- **Not** an authentication/identity provider — sign-in states intent; it is
  not a security gate for the OS session itself.

---

## 4. Users & personas

| Persona | Needs | How Logix serves them |
|---|---|---|
| **Lab user** (student/staff/guest at a machine) | Fast, non-intrusive sign-in; confidence they're not being spied on | One-tap returning-user resume; a clear, short form; a visible timer; explicit notices for any screenshot |
| **Lab admin / operator** | Know who's on which machine now; session history; take support actions; produce reports | Live device grid, session history, remote lock/message/screenshot/power, analytics, xlsx export |
| **Lab governance / faculty** | Accountability records, usage reports, assurance that privacy is respected | Reports, the published privacy model, audit log of admin actions |
| **Deployer / IT** | Install the agent on many PCs; stand up the server; keep it updated | One-liner + wizard installers, idempotent re-runs, native-service deployment |

---

## 5. Privacy & ethics model (non-negotiable)

This section is a **requirement**, not a description — every feature must
comply.

### 5.1 What Logix records

- Stated identity: **name**, **NIM/ID**.
- **Access type**: Physical or AnyDesk (auto-detected, user-confirmable).
- **Purpose** (tujuan) and free-text **notes** (keterangan).
- Session **start/end timestamps** and derived duration.
- **Device name**, Windows username, hostname, and (if present) **AnyDesk ID**.

### 5.2 What Logix must NEVER record

- Keystrokes, clipboard, typed content.
- Screen contents, window titles, browsing history, file names, or
  per-application usage — **except** an explicit, admin-triggered screenshot.

### 5.3 Screenshot rule

The only screen capture is the admin-triggered `SCREENSHOT` control action, and
it is **never silent**: the device shows the person an on-screen notice that a
capture was taken, every time. A capture with no notice is a defect.

### 5.4 Data-handling requirements

- **local_only by default.** Runtime PII stays on the device / the lab's own
  server.
- **No PII in version control.** Databases, reports, session state, logs, and
  config with keys are git-ignored; every commit is checked for leaks.
- **Redaction gate for external sync.** The optional Google Sheets sync must
  pass a redaction gate before any row leaves the server (see
  `docs/GSHEET_SYNC_DESIGN.md`). This gate is non-negotiable.
- **Transparency of intent.** The sign-in copy tells the user exactly what is
  recorded and that their on-screen activity is not.

See `docs/PRIVACY.md` and `ETHICAL_USE.md` for the full policy.

---

## 6. System architecture

Five cooperating parts:

```
  Lab PC (Windows)                         Central server (any OS)
  ┌───────────────────────────┐           ┌──────────────────────────┐
  │ Windows Agent (windows/)  │  HTTPS     │ FastAPI app (server/)    │
  │  - sign-in popup          │ ─────────► │  - enroll / heartbeat    │
  │  - session timer widget   │  heartbeat │  - sessions / logging    │
  │  - resident monitor       │  + logs    │  - control commands      │
  │  - kiosk lockdown         │ ◄───────── │  - alerts / replies      │
  │  - remote-control agent   │  commands  │  - analytics / reports   │
  │  - AnyDesk (remote assist)│           │  - auth (email+password) │
  │  - native Python core ────┼──┐        └───────────┬──────────────┘
  │    (logix/ log_physical)  │  │ SQLite              │ serves
  └───────────────────────────┘  │ session db          ▼
                                  ▼            ┌──────────────────────┐
                            local logix.db     │ Dashboard (frontend/)│
                                               │ React 19 + Astryx    │
                                               └──────────────────────┘
```

1. **Windows agent** (`windows/*.ps1`) — the on-device experience and the
   remote-control responder. PowerShell + WPF UI. Runs as the plain interactive
   user (non-elevated) via a self-healing scheduled task.
2. **Native Python core** (`logix/`) — cross-platform logging bridge
   (`log_physical.py`), SQL helper (`logbook_sql.py`), report generator
   (`logbook_report.py`), Google Sheets sync (`gsheet_sync.py`), SSH-login
   bridge (`logbook_ssh_login.py`), path resolution (`paths.py`).
3. **Central server** (`server/main.py`) — FastAPI app; SQLite storage; REST
   API for the agent and the dashboard.
4. **Dashboard** (`frontend/`) — React 19 + TypeScript + Vite on the Astryx
   design system; the admin single-pane UI. A legacy vanilla-JS UI
   (`server/static/`) is the no-Node fallback.
5. **Installers & tooling** — Inno Setup wizard (`installer/`), one-liner
   bootstraps (`install/`, `windows/bootstrap-client.ps1`), CI that builds and
   releases the installer.

Full detail: `docs/ARCHITECTURE.md`.

---

## 7. Functional requirements

### 7.1 Windows agent — sign-in

- **FR-A1** At logon and at unlock (and on resume from sleep), present a
  fullscreen, top-most sign-in prompt on a blurred snapshot of the desktop.
- **FR-A2** Collect: name, NIM/ID (numeric-only), access type
  (Physical/AnyDesk, auto-selected from detection), purpose (configurable
  list), and notes. Required fields are configurable.
- **FR-A3** **Returning-user fast path**: if a saved profile exists, offer a
  one-tap "continue as <name>" resume, with "Bukan saya / ganti data" to fall
  through to the full form. The switch must be instant (no re-capture lag).
- **FR-A4** **Kiosk lockdown while the form is up**: swallow window-management
  chords (Alt+Tab, Win+Tab / any Win chord, Ctrl+Esc, Alt+Esc, Alt+F4, Escape)
  and gate Task Manager, so the prompt can't be bypassed before a session
  starts. Both mitigations must **always** be released when the form closes
  (a crash must never leave the machine locked down). Ctrl+Alt+Del is
  OS-enforced and out of scope.
- **FR-A5** On submit, write the session record, log a START event, and hand
  off to the timer widget with a smooth, continuous transition (form collapses
  toward screen center as the timer grows in at that same point, then the timer
  glides to its dock).

### 7.2 Windows agent — session timer widget

- **FR-A6** A small always-on-top widget shows elapsed session time and (for
  the first 10s / on hover) the session's identity/purpose/device.
- **FR-A7** The widget enters center-screen, then glides to a top-left dock; the
  **SELESAI (end session)** control appears only after it has docked.
- **FR-A8** SELESAI is a deliberate two-step control (arm, then confirm within
  ~3s) that ends the session and locks the workstation.
- **FR-A9** The widget renders inline admin messages (toast-style) and escalates
  emergencies to a centered countdown overlay.

### 7.3 Windows agent — resident monitor & lifecycle

- **FR-A10** A resident monitor process handles session lifecycle:
  lock/unlock/logoff, sleep/resume, and shutdown, per the product rule that
  **lock/sleep is a pause, not a departure** (the session survives across any
  lock/sleep duration and resumes on unlock).
- **FR-A11** **Self-healing**: the monitor is registered as a logon scheduled
  task with a 30-minute re-fire so a dead monitor recovers within ≤30 min, plus
  an HKCU Run fallback. A single-instance mutex prevents duplicates.
- **FR-A12** Idle auto-close: an unlocked-but-idle session past a configurable
  timeout is auto-closed; a max-session-age cap closes multi-day sessions.
- **FR-A13** Heartbeats at a configurable interval report device + session
  status and carry the poll for remote commands.
- **FR-A14** The monitor and everything it spawns run **non-elevated** so all
  session-state files stay user-owned and therefore deletable (ending a session
  must never silently fail).

### 7.4 Windows agent — remote control responder

- **FR-A15** Execute admin commands delivered via heartbeat and acknowledge
  each outcome: `LOCK`, `BROADCAST` (message), `SCREENSHOT` (with mandatory
  on-screen notice), `SHUTDOWN`, `RESTART`, `LOGOFF`. Unknown commands fail
  explicitly.
- **FR-A16** Users can reply to a broadcast from the widget; replies flow back
  to the admin.
- **FR-A17** AnyDesk is auto-deployed (optional) and its ID auto-reported so the
  dashboard's "Remote" action works without manual setup.

### 7.5 Central server — device fleet

- **FR-S1** **Enrollment**: issue single-use invite tokens; a device enrolls to
  receive a per-device API key. Devices can be **revoked** and **renamed**.
- **FR-S2** **Heartbeat ingestion**: accept device status, active-session
  metadata, and AnyDesk ID; drive live status.
- **FR-S3** **Live views**: list devices with current status; list active
  sessions; per-device detail with session/action history.

### 7.6 Central server — logging & records

- **FR-S4** Ingest session events (`/api/log`) with **deduplication** so
  retries don't double-count.
- **FR-S5** Serve **session history** and an **audit log** of admin actions.
- **FR-S6** Serve **analytics** aggregates and export **xlsx reports**.

### 7.7 Central server — control & messaging

- **FR-S7** Dispatch control commands (`lock`, `broadcast`, `power`,
  `screenshot`) to devices with a full **ack lifecycle**; pending commands are
  **rehydrated on server restart** so nothing is lost.
- **FR-S8** Store admin-triggered **screenshots** (uploaded by the agent) and
  serve them in the device detail view.
- **FR-S9** Two-way **replies**: collect user replies and mark them read.
- **FR-S10** **Alerts**: raise, acknowledge, and resolve operational alerts.

### 7.8 Central server — auth & access control

- **FR-S11** Admin auth is **email + password**: sign-in requires an address on
  the `ADMIN_EMAILS` allowlist **and** the shared `LOGIX_ADMIN_PASSWORD`
  (never hardcoded, never in the DB). Session is a signed cookie.
- **FR-S12** **Brute-force guard**: lock a client IP after N failed attempts
  within a window.
- **FR-S13** **RBAC**: role-gated access to admin endpoints.
- **FR-S14** A dev-mode default password and a passwordless `dev-login` exist
  **only** under `LOGIX_DEV_MODE` (for tests / trusted LAN) and must never be
  used on a shared server.

### 7.9 Dashboard

- **FR-D1** Device grid with live status; session history; per-device detail.
- **FR-D2** Remote-control UI (lock / message / screenshot / power) with clear
  affordances and command feedback.
- **FR-D3** Alerts, replies, analytics, and report download.
- **FR-D4** Built on the Astryx design system (tokens/components, no raw layout
  primitives); served by the FastAPI app in production, with a legacy no-Node
  fallback.

### 7.10 Reporting & integration

- **FR-R1** Generate session reports (xlsx) for governance.
- **FR-R2** Optional **Google Sheets sync** with a **mandatory redaction gate**
  and a dry-run mode that leaks no PII.

### 7.11 Installation & deployment

- **FR-I1** **Wizard installer** (`LogixAgentSetup.exe`, Inno Setup): EN/ID,
  collects server URL/API key/device name, registers the non-elevated monitor
  task, installs the native core, and starts the agent — unattended after a
  couple of fields. Built and attached to GitHub Releases by CI on `v*` tags.
- **FR-I2** **One-liner agent install** (`irm … | iex` → `bootstrap-client.ps1`)
  for a single machine, and a flagged form for scripted mass deployment.
- **FR-I3** **Server bootstrap** (`install/bootstrap-server.*`) and a
  cross-platform core installer (`install/install.py`).
- **FR-I4** Re-runs are **idempotent** (update in place / re-point to a new
  server); a clean uninstaller fully removes the agent and re-enables Task
  Manager.

---

## 8. Non-functional requirements

- **NFR-1 Privacy-first** — §5 is binding on every feature.
- **NFR-2 Security** — per-device API keys; admin allowlist + password;
  brute-force lockout; RBAC; no secrets in source or DB; security-hardening
  smoke tests in CI.
- **NFR-3 Reliability** — self-healing monitor; command rehydration on restart;
  session-zombie prevention (user-owned state, max-age cap); structured server
  logging (no silent `except: pass`).
- **NFR-4 Transparency** — no silent screen capture; sign-in copy states what
  is and isn't recorded.
- **NFR-5 Compatibility** — agent targets Windows 10 1809+ (build 17763) and
  Windows 11; the Python core and server run on Linux, macOS, and Windows (CI
  matrix: py 3.11/3.12 × three OSes).
- **NFR-6 Deployability** — plain-Python + native services (systemd / launchd /
  Task Scheduler); **no Docker requirement**.
- **NFR-7 Windows launch hygiene** — background PowerShell launches route
  through `conhost.exe --headless` (no stray terminal tabs on Win11) and quote
  spaced paths (PS 5.1 `Start-Process` does not); the sign-in flow must never
  leave a stuck window or a trapped keyboard.
- **NFR-8 Encoding** — `windows/*.ps1` and `install/*.py` are ASCII-only.
- **NFR-9 Maintainability** — Windows capture scripts are treated as
  environment-specific (document rather than gratuitously rewrite); UI work uses
  the design system's tokens/components.

---

## 9. Data model (high level)

- **Device** — id, name, enrollment/API-key state, last-seen, AnyDesk ID,
  status.
- **Session** — session_id, device, identity (name, NIM), access type, purpose,
  notes, start/end, duration, source (physical/AnyDesk).
- **Event / log** — START / END / AUTO_CLOSE / AUTO_FINISH with dedup.
- **Command** — id, device, type (LOCK/BROADCAST/SCREENSHOT/SHUTDOWN/RESTART/
  LOGOFF), param, status (pending/done/failed), acks.
- **Reply** — user reply to a broadcast, read state.
- **Alert** — operational alert, acknowledged/resolved state.
- **Audit entry** — admin action, actor, timestamp.
- **Screenshot** — admin-triggered capture, disclosed on device, stored server-side.

Runtime PII lives in the local device DB and the lab's own server DB; neither is
ever committed.

---

## 10. Success metrics

- **Attribution coverage** — % of sessions on managed machines that carry a
  stated identity + purpose (target: ~all interactive sessions).
- **Sign-in friction** — time to complete sign-in (returning users: one tap;
  new users: a short form).
- **Fleet visibility** — device last-seen freshness (heartbeat within interval)
  and % of fleet reporting.
- **Reliability** — monitor uptime / self-heal recovery within ≤30 min; zero
  "zombie" sessions (timers running with no live session).
- **Privacy assurance** — zero silent captures; zero PII in version control;
  redaction gate passing on every external sync.
- **Operational** — command ack success rate; alert time-to-acknowledge.

---

## 11. Release & deployment model

- **Source of truth**: the GitHub repo; CI (`.github/workflows/`) runs the
  cross-platform core round-trip, server security tests, the full pytest suite,
  the dashboard typecheck+build, and the Windows popup-config validation.
- **Installer delivery**: `build-installer.yml` compiles `LogixAgentSetup.exe`
  on every `main` push (artifact) and attaches it to a **GitHub Release** on
  `v*` tags.
- **Agent updates**: re-run the wizard or the one-liner; idempotent.
- **Server hosting**: native service on the lab's own host/network
  (`docs/HOSTING.md`, `docs/GOING_LIVE.md`, `docs/RUNBOOK.md`).

---

## 12. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Agent monitor dies → no sign-in/timer | 30-min self-heal task + Run fallback + mutex |
| Elevated run makes state files undeletable → zombie sessions | Non-elevated monitor (RunLevel Limited); state-dir ACL grant; repair script |
| Windows 11 terminal tabs / stuck sign-in window | `conhost --headless` launch contract; guaranteed window close independent of animation |
| Server restart loses in-flight commands | Command rehydration on startup |
| PII leakage | git-ignore + pre-commit checks; redaction gate on external sync; local_only default |
| Screen-capture misuse | Screenshots always disclosed on device; documented ethical-use policy |
| Kiosk lockdown traps the keyboard | Hook + Task Manager gate always released in `finally`; skipped in test mode |
| Dev shortcuts on a real server | Dev password / dev-login gated behind `LOGIX_DEV_MODE`; documented "must be 0 in production" |

---

## 13. Roadmap (forward-looking)

Tracked in `docs/ROADMAP.md` and `docs/AUDIT_AND_ROADMAP.md`. Themes: richer
analytics, deeper reporting/integration, and continued hardening of the
agent/monitor lifecycle. The privacy model is fixed and not subject to roadmap
trade-offs.

---

## 14. Appendix

### 14.1 Server API surface (current)

Auth: `POST /api/auth/login`, `POST /api/auth/dev-login` (dev only),
`GET /api/auth/verify`, `POST /api/auth/logout` ·
Config: `GET/PUT /api/config` ·
Fleet: `POST /api/heartbeat`, `GET /api/active`, `GET /api/devices`,
`GET /api/devices/{id}`, `POST /api/devices/{id}/revoke`,
`PUT /api/devices/rename`, `POST /api/devices/{id}/actions/{aid}/retry` ·
Enrollment: `POST /api/enroll/invite`, `POST /api/enroll` ·
Control: `POST /api/control/{lock,broadcast,power,screenshot}`,
`POST /api/control/screenshot/upload`, `GET /api/devices/{id}/screenshot` ·
Messaging: `POST /api/replies`, `GET /api/replies`,
`POST /api/replies/{id}/read` ·
Alerts: `GET /api/alerts`, `POST /api/alerts/{id}/acknowledge`,
`POST /api/alerts/{id}/resolve` ·
Records: `POST /api/log`, `GET /api/sessions`, `GET /api/audit-log`,
`GET /api/analytics`, `GET /api/reports` ·
Ops: `GET /api/health` · UI: `GET /`, static assets.

Canonical contract: `API_CONTRACT.md`.

### 14.2 Glossary

- **NIM** — student/staff identification number.
- **Tujuan / Keterangan** — purpose / notes fields on the sign-in form.
- **SELESAI** — the "end session" control on the timer widget.
- **Logix Control** — the remote-assist command surface (lock/message/
  screenshot/power).
- **Monitor** — the resident agent process that owns session lifecycle.
- **Physical vs AnyDesk** — in-person vs remote-desktop session type.

### 14.3 Related documents

`README.md` · `docs/ARCHITECTURE.md` · `docs/PRIVACY.md` · `ETHICAL_USE.md` ·
`docs/LOGIX_CONTROL.md` · `docs/GSHEET_SYNC_DESIGN.md` · `docs/GETTING_STARTED.md` ·
`docs/HOSTING.md` · `docs/GOING_LIVE.md` · `docs/RUNBOOK.md` ·
`docs/ROADMAP.md` · `SECURITY.md` · `API_CONTRACT.md` · `installer/README.md`.
