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
hardened: authentication (already exists — Google OAuth + session tokens),
a real permission/role model (not yet — see §4), an audit log (this
milestone — §6), a policy model (this milestone, as data only — §5), and
persisted device identity (this milestone — §5). Only after those are in
place does designing screen/input access become responsible. This
constraint is self-imposed and stated here so it is checkable by anyone
reading this file, not just a private intention.

The full staged milestone list lives in `docs/AUDIT_AND_ROADMAP.md` §7 —
this document does not duplicate it, only points at it, so there is one
source of truth for "what stage are we at."

## 4. Roles and permission model (target state — not yet implemented)

The eventual model has six roles, each with a narrow, named set of
permitted actions:

| Role | Intent |
|---|---|
| Super Admin | Full access across all devices, policies, and audit logs |
| Faculty Admin | Manages devices/policies within their faculty's scope |
| Lab Admin | Manages devices within one or more assigned labs/rooms |
| Instructor | Broadcast/demo and lock/message within an assigned room, during class |
| Viewer | Read-only: device status, session history, audit log |
| Auditor | Read-only, audit log and compliance reporting only, no device state |

**None of this is implemented.** Today there is exactly one tier: any
email in `ADMIN_EMAILS` can perform every admin action, gated only by
`verify_token`. This milestone adds a single inert `role: "admin"` field to
every session (§6) — a no-op today, purely so the real model above can be
introduced later by changing what value gets assigned, not by changing the
shape of every function that currently depends on `verify_token`. Building
the six-role model itself is Milestone 3, deliberately not this one:
there's nothing to differentiate roles by until Control has more than two
commands.

## 5. Device identity and policy profiles

Three axes describe a device in Control:

- **`device_id`** — the durable identity. In this milestone, server-
  generated on first-seen `hostname` (a stopgap — see the limitation note
  below). The real mechanism is invite-code enrollment
  (`/api/enroll`, spec'd in `API_CONTRACT.md`, not yet implemented), which
  will have the agent generate and persist its own local `device.json`
  identity instead of relying on the server to infer one from a hostname.
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

**Known, accepted limitation:** this milestone uses `hostname` as the
`devices` upsert key. A reimaged or renamed device will appear as a new
row rather than updating its old one. This is the exact reason
`AUDIT_AND_ROADMAP.md` §4 specifies `device_id` as the durable identity
long-term — it's accepted here as a documented, temporary simplification,
not a silent gap, and will be resolved when real enrollment
(agent-assigned, agent-persisted `device_id`) lands.

## 6. Audit log as a first-class citizen

Every privileged action Control ever takes against a device produces a
`remote_actions` row before/as it is queued — not bolted on after the
feature works, from the very first two commands. This milestone proves the
principle rather than promising it: `queue_lock_command` and
`queue_broadcast_command` (which predate Control's data model entirely)
were retrofitted with exactly one `log_remote_action(...)` call each,
wrapped so a logging failure can never block the real command from being
queued.

**Explicit limitation, stated plainly so it is never mistaken for more
than it is:** this audit log can currently only prove *"an admin queued
this command,"* not *"the device executed it."* Confirming actual
execution requires the agent to report outcomes back to the server (e.g.
echoing completed command IDs on its next heartbeat) — a natural extension
for Milestone 3, not built here. Anywhere the audit log is surfaced (the
dashboard panel, this document, `SECURITY.md`), a `status: 'queued'` row
must not be read as `status: 'done'`.

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
- Real role-based access control — one inert field, no enforcement
- `/api/enroll` (invite-code device enrollment) — still the locked design
  in `API_CONTRACT.md`, unimplemented
- Any agent-side (PowerShell) changes — this milestone is entirely
  server-side

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
