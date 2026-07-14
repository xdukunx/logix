# Security Policy

Logix processes personal data (names, student/staff IDs, client IPs). We take
security and privacy seriously. This document explains how to report issues and
what security properties Logix does — and does not yet — guarantee.

## Supported components

Logix ships in two parts with **different maturity levels**:

| Component | Location | Status | Network exposure |
|---|---|---|---|
| **Core** (bridge, reporting, SQL helper, GSheet redaction) | `logix/`, `install/`, `windows/` | Stable, tested, CI-covered | Local only (optional outbound GSheet push) |
| **Central server + dashboard** | `server/` | Hardened (audit item C fixed + tested); younger than the core | Listens on HTTP — needs a TLS reverse proxy for non-local use; see below |

The **core is the recommended deployment.** It keeps all data local and has no
inbound network surface.

## Reporting a vulnerability

Please do **not** open a public issue for security problems. Instead:

1. Email the maintainer (see the repository owner's profile) with the subject
   `SECURITY: Logix`, or use GitHub's **private vulnerability reporting**
   (Security tab → *Report a vulnerability*).
2. Include: affected component, version/commit, reproduction steps, and impact.
3. We aim to acknowledge within 5 business days and to agree on a disclosure
   timeline with you. Please allow reasonable time to patch before public
   disclosure.

Do not include real personal data (names, IDs, IPs) in any report or attachment.

## Central server (`server/`) — hardening status

The findings from the original audit (roadmap item C in
`docs/AUDIT_AND_ROADMAP.md`) are **fixed and regression-tested** in
[`tests/test_server_security.py`](tests/test_server_security.py):

- **Auth fallback gated.** Login is email + password: the email must be on the
  `ADMIN_EMAILS` allowlist and the password must match `LOGIX_ADMIN_PASSWORD`
  (constant-time compare). In the default production posture
  (`LOGIX_DEV_MODE=0`), an empty `LOGIX_ADMIN_PASSWORD` refuses every login
  rather than granting a session (no backdoor). Repeated failures from one IP
  are rate-limited. The passwordless `/api/auth/dev-login` shortcut only exists
  behind `LOGIX_DEV_MODE=1`.
- **Ingest authentication.** `/api/log` and `/api/heartbeat` validate
  `X-API-Key` (constant-time compare) outside dev mode; devices get
  individual revocable keys via enrollment, or use the shared
  `LOGIX_INGEST_API_KEY`.
- **CORS.** Outside dev mode, only origins listed in
  `LOGIX_ALLOWED_ORIGINS` are allowed; the wildcard+credentials
  combination is never used.
- **Output escaping.** The dashboard escapes agent-supplied fields before
  rendering.

Caveats that remain true by design — plan your deployment around them:

- **No built-in TLS.** Session tokens and API keys travel in headers; put a
  TLS reverse proxy in front of anything reachable beyond `localhost`
  (walkthrough in the README) and keep uvicorn bound to `127.0.0.1`.
- **In-memory admin sessions.** Login tokens are lost on restart (re-login
  required); deliberate, but it also means a long-lived token survives
  only as long as the process.
- **`LOGIX_DEV_MODE=1` is for a private laptop only.** It re-enables the
  mock login and permissive CORS. Never set it on a reachable server.
- **Limited rate limiting.** Only `/api/enroll` has an abuse guard; on
  public deployments the reverse proxy should provide general rate
  limiting.

## Logix Control's security implications

[Logix Control](docs/LOGIX_CONTROL.md) is a planned subsystem that extends
the server's privileged surface — device control commands today (lock,
broadcast), and eventually screen/input access. **Every caveat above
applies with higher stakes once that capability exists.** For example, the
in-memory/replayable-session-token caveat is currently "an admin session
could be replayed to lock or message a device"; once screen view/remote
control ship, the same underlying weakness becomes "an admin session could
be replayed to view or control a user's screen" — qualitatively worse, and
worth stating as such now rather than leaving it implicit.

**What this milestone (Milestone 2, safe parts) actually adds:** a
persisted `devices` table and an audit log (`remote_actions`) for the two
control commands that already existed (lock, broadcast). It introduces
**no new attack surface** beyond what `/api/control/lock` and
`/api/control/broadcast` already had — no new auth model, no new network
listener, no new command types, no new dependency. The audit log can prove
a command was *queued* by an authenticated admin; it cannot yet prove the
device *executed* it (see [docs/LOGIX_CONTROL.md §6](docs/LOGIX_CONTROL.md#6-audit-log-as-a-first-class-citizen)
for why, and don't read a `queued` status as `done`).

**Commitment for later milestones:** RBAC hardening (Milestone 3) and
screen/remote-control (Milestones 8-9) each require a SECURITY.md revision
*before* they ship, not after — matching this project's existing posture
(the Batch 2 hardening pass fixed the server's known issues before it was
committed into the public repo, not retroactively).

## Secrets and data hygiene

- Never commit `config.env`, `service_account.json`, any `*.db`, generated
  reports, or logs. These are covered by `.gitignore`; verify before pushing.
- The admin password (`LOGIX_ADMIN_PASSWORD`) and API keys must come from
  environment variables / `.env` — never from source or committed config.
- Reports and databases contain PII and must stay on the deploying
  organization's controlled storage.
