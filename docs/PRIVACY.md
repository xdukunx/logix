# Privacy in Logix

Logix is a **device- and session-management** tool, not a surveillance tool.
This document states what data it collects, the privacy controls available, and
the responsibilities of anyone who deploys it.

## Design boundaries — session/logbook core (unconditional)

This section covers the logbook core (`logix/`, the sign-in popup, SSH/
AnyDesk capture, reporting). It is absolute and does not change regardless
of what other subsystems Logix grows. The logbook core does **not** and
will not implement:

- keylogging or keystroke capture
- screenshots or screen recording
- browser history or URL capture
- microphone/camera access
- GPS or physical-location tracking
- stealth/hidden monitoring of any kind

Tracking is limited to transparent device-, session-, and asset-management
facts. If a proposed feature falls outside that scope, it does not belong
in the logbook core.

## Design boundaries — Logix Control (conditional, explicit-action only)

**Logix Control** ([docs/LOGIX_CONTROL.md](LOGIX_CONTROL.md)) is a separate,
larger-permission subsystem for institution-managed device control
(screen view, remote control, lock, file transfer, power actions). Its own
spec includes capabilities — screen view, remote control — that would
contradict the unconditional list above if left unqualified. This section
exists so that contradiction is resolved explicitly, in public, before any
of that capability is built, rather than discovered later.

**Current state.** Logix Control now ships an *on-demand screen view*
(single screenshot per explicit admin action) and *power actions*
(shutdown/restart/logoff), in addition to the earlier lock/broadcast
commands and the persisted device registry + audit log — see
[docs/LOGIX_CONTROL.md §7](LOGIX_CONTROL.md#7-what-is-explicitly-not-built-yet)
for exactly what is and is not built. Continuous/streaming screen view and
mouse-keyboard remote control are still **not** built. The screen-view
capability that does exist was implemented to honor every commitment below,
which were written *ahead* of it specifically so they would be reviewable
before they mattered.

Screen view and power actions, as built (and remote control, if it is ever
added), will, without exception:

- **Never run without an explicit, individually-authorized admin action**
  that produces an audit-logged `remote_actions` row before or as the
  action starts — no scheduled, background, or automatic screen access.
- **Never persist screen content beyond the latest capture.** The screen
  view stores only the single most recent screenshot per device
  (`device_screenshots`, one row per device, replaced on every capture) —
  no accumulating history, no per-capture archive.
- **Never run silently or hidden from the local user.** A visible
  indicator that screen view/remote control is active is required
  whenever it runs; this is a design requirement, not a UI nicety.
- **Still exclude keylogging, camera/microphone access, GPS, and browser
  history absolutely** — the conditional model above does not create a
  carve-out for any of these. They remain in the unconditional list, full
  stop, regardless of what Logix Control eventually adds.
- **Never record remote-control input as key logs.** Mouse/keyboard input
  transmitted during an authorized remote-control session is relayed for
  that session only and is not stored as a keystroke record.

## What Logix collects

This table covers the logbook core. Logix Control's device-registry fields
(`device_id`, `category`, `location`, `policy_profile`, etc.) are
asset-management metadata about the machine, not personal data about the
person using it — see [docs/LOGIX_CONTROL.md §5](LOGIX_CONTROL.md#5-device-identity-and-policy-profiles).

| Field | Purpose | Sensitivity |
|---|---|---|
| Name (`nama`) | Attribute a session to a person | PII |
| Student/staff ID (`nim`) | Disambiguate people | PII |
| Session type / purpose | Usage reporting | Low |
| Hostname / device ID | Which machine was used | Low–moderate |
| Client IP (SSH/AnyDesk) | Distinguish remote vs local access | PII (network) |
| Timestamps, start/end events | Compute usage hours | Low |

By default **all of this stays in the local SQLite database on the device.**

## Privacy / sync modes

The intended model (default = safest):

| Mode | What leaves the device | Use case |
|---|---|---|
| `local_only` **(default)** | Nothing. No network sync at all. | Single shared machine; strictest privacy. |
| `redacted_sync` | Aggregated, redacted view only — hours per member-token per session-type per day. **No IPs, no raw IDs, no names.** | Central reporting without exposing PII. |
| `admin_full_sync` | Full session rows to a central server you control. | Fleet management where the org is the data controller and users are informed. |

The GSheet exporter (`logix/gsheet_sync.py`) already implements the
`redacted_sync` guarantee behind a whitelist gate, verified by tests: only
`date`, `member-token`, `session_type`, and `hours` can ever be emitted.

> Note: `admin_full_sync` transmits PII. It must be an explicit, documented
> choice, and local users must be told the device is managed and what is sent.

## Inspect before you sync

Preview exactly what would leave the box, with no credentials and no network:

```bash
python <install-dir>/gsheet_sync.py --dry-run
```

## Responsibilities of the deploying organization

If you deploy Logix, **you are the data controller** for everything it records:

- Inform users that the device is managed and that sessions are logged, and
  what data is collected — ideally on the sign-in popup itself.
- Follow your institution's and jurisdiction's data-protection rules
  (retention, access, deletion, minors' data where applicable).
- Restrict access to the database, reports, and any central server to
  authorized administrators.
- Prefer the least-revealing mode that meets your need. Default to `local_only`
  or `redacted_sync` unless full sync is genuinely required and justified.

Logix gives you the controls; it cannot make these decisions for you.

## Ethical use

Logix is MIT-licensed, so nothing here is legally enforceable — but see
[../ETHICAL_USE.md](../ETHICAL_USE.md) for the intended scope of this tool
and what deploying it responsibly looks like.
