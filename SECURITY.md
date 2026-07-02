# Security Policy

Logix processes personal data (names, student/staff IDs, client IPs). We take
security and privacy seriously. This document explains how to report issues and
what security properties Logix does — and does not yet — guarantee.

## Supported components

Logix ships in two parts with **different maturity levels**:

| Component | Location | Status | Network exposure |
|---|---|---|---|
| **Core** (bridge, reporting, SQL helper, GSheet redaction) | `logix/`, `install/`, `windows/` | Stable, tested, CI-covered | Local only (optional outbound GSheet push) |
| **Central server + dashboard** | `server/` | **Preview / not production-ready** | Listens on HTTP; see caveats below |

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

## Known security caveats — central server (`server/`)

The `server/` module is a **preview** and is **not hardened for untrusted
networks**. Before exposing it beyond `localhost` on a trusted admin machine,
be aware of the following (tracked in `docs/AUDIT_AND_ROADMAP.md`):

- **Development auth fallback.** If `GOOGLE_CLIENT_ID` is unset, the Google
  login route grants an admin session without real authentication. This is a
  developer convenience and **must not run in production.** Configure real
  OAuth, and run the server only behind a `LOGIX_DEV_MODE=0` gate once the
  hardening patch (roadmap item C) lands.
- **Ingest authentication.** The `/api/log` and `/api/heartbeat` endpoints do
  not yet enforce the `X-API-Key` header. Do not expose these to untrusted
  clients until API-key validation is enabled.
- **CORS.** The server currently allows all origins with credentials — intended
  for local development only.
- **Output escaping.** The dashboard renders some client-supplied fields into
  HTML; treat all ingested data as untrusted until the escaping fix lands.

Until these are resolved, run the server **only** on a trusted host bound to
`127.0.0.1` (or behind a reverse proxy that enforces authentication), and never
on a public interface.

## Secrets and data hygiene

- Never commit `config.env`, `service_account.json`, any `*.db`, generated
  reports, or logs. These are covered by `.gitignore`; verify before pushing.
- OAuth client secrets, admin passwords, and API keys must come from
  environment variables — never from source or committed config.
- Reports and databases contain PII and must stay on the deploying
  organization's controlled storage.
