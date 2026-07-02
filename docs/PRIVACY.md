# Privacy in Logix

Logix is a **device- and session-management** tool, not a surveillance tool.
This document states what data it collects, the privacy controls available, and
the responsibilities of anyone who deploys it.

## Design boundaries (what Logix will not do)

Logix does **not** and will not implement:

- keylogging or keystroke capture
- screenshots or screen recording
- browser history or URL capture
- microphone/camera access
- GPS or physical-location tracking
- stealth/hidden monitoring of any kind

Tracking is limited to transparent device-, session-, and asset-management
facts. If a proposed feature falls outside that scope, it does not belong here.

## What Logix collects

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
