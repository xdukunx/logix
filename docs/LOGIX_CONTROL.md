# Logix Control — architecture and vision

Status: **Milestone 1-2 (safe parts) only.** This document describes a
subsystem that is mostly *not yet built*. Read [§7](#7-what-is-explicitly-not-built-yet)
before assuming any capability described here is active.

## 1. What Logix Control is

Logix Control is a Veyon-like remote lab-device management layer for Logix:
device monitoring, screen view, remote control, lock screen, broadcast
messaging, file transfer, and power actions, administered from the Logix
central dashboard. It is a custom-built system — not an integration with
Veyon or any third-party remote-control product — designed specifically for
institution-managed faculty/lab/office devices.

Logix Control is a **distinct, larger-permission subsystem layered on top
of** the existing access-logbook tool, not an extension of its scope:

- The **logbook** (`logix/`, `windows/logbook_*.ps1`, `server/main.py`'s
  session/reporting endpoints) answers one question: *who used this
  machine, when, and for how long.* It stays exactly that scope.
- **Control** answers a different question: *what can an authorized admin
  additionally, transparently, and auditably do to a device the
  institution owns and manages.* It is opt-in per device/category, never
  silent, and every privileged action is audit-logged as a first-class
  design principle — not a feature added after the fact.

A device can run the logbook popup with zero Control capability enabled.
Conversely, a device existing in Control's registry does not by itself
grant any remote-control capability over it — capability is gated by the
device's assigned policy profile (§5), and as of this milestone, no policy
profile permits anything beyond the two commands (lock, broadcast) that
already existed before Control's data model was added.

## 2. Relationship to the existing logbook tool

Logix Control shares infrastructure with the logbook — the same central
server process, the same SQLite database (`central_logix.db`), the same
admin authentication (`verify_token`), and the same device concept
(`hostname`/`device_name` reported via heartbeat) — but is versioned and
reasoned about separately. `docs/AUDIT_AND_ROADMAP.md` §5 (items A-I) is
the logbook/server hardening roadmap; §7 of that same document is the
Control subsystem roadmap. They are tracked independently because they
have different risk profiles: hardening an existing, scoped feature is
lower-risk than adding new remote-access capability to managed devices.

## 3. Why this is staged, and why non-negotiably so

Screen streaming and remote control are not being designed in code-level
detail, let alone built, until all of the following exist and are
hardened: authentication (already exists — email + password + session tokens),
a real permission/role model (not yet — see §4), an audit log (this
milestone — §6), a policy model (this milestone, as data only — §5), and
persisted device identity (this milestone — §5). Only after those are in
place does designing screen/input access become responsible. This
constraint is self-imposed and stated here so it is checkable by anyone
reading this file, not just a private intention.

The full staged milestone list lives in `docs/AUDIT_AND_ROADMAP.md` §7 —
this document does not duplicate it, only points at it, so there is one
source of truth for "what stage are we at."

## 4. Roles and permission model (Milestone 3 — implemented)

Six roles, each with a narrow, named set of permitted actions:

| Role | Intent |
|---|---|
| Super Admin | Full access across all devices, policies, and audit logs |
| Faculty Admin | Manages devices/policies within their faculty's scope |
| Lab Admin | Manages devices within one or more assigned labs/rooms |
| Instructor | Broadcast/demo and lock/message within an assigned room, during class |
| Viewer | Read-only: device status, session history, audit log |
| Auditor | Read-only, audit log and compliance reporting only, no device state |

`server/main.py`'s `ROLE_PERMISSIONS` maps each role to a set of
permission strings, and `require_permission(action)` gates every endpoint
that has a real permission boundary. `ADMIN_EMAILS` accepts `email:role`
pairs (`admin@x.org:lab_admin`); a bare email with no `:role` suffix
defaults to `super_admin`, so existing deployments keep working unchanged.

**Explicit, deliberate limitation:** this is permissions-only. There is no
faculty/lab/room *scope* restriction — a `faculty_admin` and a
`super_admin` differ in which actions they can take, not in which devices
they can take them on, because no backing entity for "their faculty" or
"assigned labs" exists yet. See `tests/test_server_rbac.py` for the
permission matrix this implements.

## 5. Device identity and policy profiles

Three axes describe a device in Control:

- **`device_id`** — the durable identity. Invite-code enrollment
  (`POST /api/enroll/invite` + `POST /api/enroll`, spec'd in
  `API_CONTRACT.md`) is now implemented: the server generates `device_id`
  and a per-device API key on redemption, and the agent persists both
  locally in `device.json` (`logix/paths.py`) rather than the server
  inferring identity from `hostname`. A device that hasn't enrolled yet
  still upserts by `hostname` on heartbeat as a fallback (see the
  limitation note below) — enrollment is optional, not required, for a
  device to appear on the dashboard.
- **`category`** — `lab_workstation | office_workstation | loaned_laptop |
  mobile_device | server | custom` (locked in `docs/AUDIT_AND_ROADMAP.md`
  §4, unchanged here — never call this `device_profile`).
- **`policy_profile`** — one of seven named profiles (`strict_privacy`,
  `lab_standard`, `exam_mode`, `instructor_demo`, `office_device`,
  `loaned_laptop`, `server_monitoring`). This milestone seeds all seven
  with identical, minimal `allowed_capabilities` (`["lock","broadcast"]`)
  — the two commands that exist — because there is nothing yet to
  meaningfully differentiate them by. No code path enforces this data
  against anything; it exists so later milestones edit existing rows
  instead of designing the table from scratch.

**Known, accepted limitation:** an *unenrolled* device still upserts by
`hostname` (the pre-enrollment fallback path). A reimaged or renamed
unenrolled device will appear as a new row rather than updating its old
one. Enrolling a device (redeeming an invite code) resolves this for that
device, since its `device_id` then persists in `device.json` independent
of hostname. Unenrolled operation remains supported for backward
compatibility and low-friction first-run use.

## 6. Audit log as a first-class citizen

Every privileged action Control ever takes against a device produces a
`remote_actions` row before/as it is queued — not bolted on after the
feature works, from the very first two commands. This milestone proves the
principle rather than promising it: `queue_lock_command` and
`queue_broadcast_command` (which predate Control's data model entirely)
were retrofitted with exactly one `log_remote_action(...)` call each,
wrapped so a logging failure can never block the real command from being
queued.

**Execution confirmation (Milestone 3 — implemented).** A `status`
column value now means something specific:

| Status | Meaning |
|---|---|
| `queued` | An admin queued it. Nothing more is known yet. |
| `done` / `failed` | The agent reported the outcome on a *later* heartbeat via `HeartbeatPayload.acks`, matched back to this row by `command_id`. `executed_at` is set. |
| `expired` | It sat in the queue past `COMMAND_TTL_MINUTES` (5) without the device checking in, and was withheld — never delivered. A device offline for hours no longer fires a stale LOCK/BROADCAST the instant it reconnects. |

Acks ride the *next* heartbeat, not the one that delivered the command:
the agent executes LOCK/BROADCAST synchronously, after it has already
consumed the HTTP response that delivered them, so there's no request left
to attach the outcome to. `apply_command_acks()` applies each ack with an
`AND status = 'queued'` guard, making it idempotent against a resent ack
(the agent's own delivery is at-least-once, via
`windows/logbook_common.ps1`'s `pending_acks.json`) and a silent no-op for
an unknown or already-terminal `command_id` — an ack is a best-effort
report, not something the caller depends on succeeding.

**Still true:** a `status: 'queued'` row must not be read as
`status: 'done'` — it just means "queued" now covers a narrower, more
honest window than before.

## 7. What is explicitly NOT built yet

To prevent a reader from inferring capability from the presence of schema
or documentation, stated as a literal list. None of the following exist in
the codebase as of this milestone:

- Screen capture, screen thumbnails, or any form of screen view
- Remote control / mouse-keyboard input injection
- File transfer (send or collect)
- Broadcast/demo screen sharing (text broadcast already existed before
  Control; screen broadcast does not)
- WebSocket or any realtime/duplex channel
- Power actions (Wake-on-LAN, reboot, shutdown, logout)
- Run-approved-program / open-approved-website execution
- Any enforcement of `device_policies` or `command_allowlist` — both exist
  as seeded data only
- Faculty/lab/room *scope* restriction within RBAC (§4) — roles gate
  which actions, not which devices; no backing entity for "their faculty"
  exists yet

## 8. Relationship to PRIVACY.md and ETHICAL_USE.md

`docs/PRIVACY.md` states two separate boundary sets: an unconditional one
for the logbook/session core (unchanged, absolute — no keylogging, no
camera/mic, no GPS, no browser history, ever), and a conditional one
specifically for Logix Control, committed to now, ahead of any Control
capability existing: when screen view or remote control are eventually
built, they will never run without an explicit, audit-logged admin action;
will never persist screen content by default; and will never run silently
or hidden from the local user. Read `docs/PRIVACY.md`'s "Design boundaries
— Logix Control" section for the full statement — this document does not
duplicate it, only commits to keeping this section and that one
consistent as Control evolves.

`ETHICAL_USE.md` frames Logix as transparent, disclosed institutional asset
management, not covert surveillance. Logix Control does not change that
framing — an explicit-action, audit-logged remote-control feature is an
extension of transparent device management, not a carve-out for it.
