# Logix — development roadmap

Living plan for what's built and what's next. Privacy rules in
[`GSHEET_SYNC_DESIGN.md`](GSHEET_SYNC_DESIGN.md) and the handoff in
[`CLAUDE_CODE_HANDOFF.md`](CLAUDE_CODE_HANDOFF.md) take precedence over this file.

## Done

- **Phase 1 — publication.** Privacy hygiene, MIT license, CI, `v0.1.0` tagged
  and pushed.
- **Cross-platform core + installer.** Logging bridge, report generator, and
  SQL helper run natively on Linux/macOS/Windows; one installer (`install/`)
  sets up a system-wide deploy. Path/config resolution centralized in
  `logix/paths.py`.
- **GSheet sync core (Phase 2a).** `logix/gsheet_sync.py`: redaction gate
  (whitelist → date/member/session_type/hours), stable one-way member tokens
  (initials | hash | code), hourly aggregation, idempotent upsert keyed by
  `date|member|session_type`, read-only DB access. Unit-tested in `tests/` —
  the "no IP, no raw NIM ever leaves the box" guarantee is enforced by tests
  across all three redaction modes.

- **Go-live tooling (Phase 2b).** `install/setup_sync.py`: writes sync config
  into config.env, installs the optional Google libs (`requirements-sync.txt`),
  validates the service-account key, verifies sheet access, and registers an
  hourly schedule (systemd timer / launchd daemon / Task Scheduler). New
  `gsheet_sync.py --dry-run` (preview, no creds) and `--check` (verify access).
  Operator runbook: [`GOING_LIVE.md`](GOING_LIVE.md).

## Next

1. **Live Google push validation.** *Blocked on real credentials only.* The
   tooling is ready; an operator runs `setup_sync.py` with a real service
   account + shared Sheet, then confirms two runs produce no duplicate rows
   against the live sheet (the idempotency is unit-tested; this is the
   end-to-end confirmation).
2. **Per-user popup customization.** Extend the Windows WPF popup
   (`windows/logbook_popup.ps1`) so fields/branding can vary per system/user
   without touching the capture core. Windows-side only.

## Won't do (by decision)

- A macOS/Linux GUI popup for physical "at-keyboard" capture. That's a separate
  native-UI project; physical capture stays Windows-only and SSH covers the
  POSIX side. (See the platform-support matrix in the README.)
