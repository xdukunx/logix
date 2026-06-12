# Handoff: Logix

You're working in the `logix` repo on Mindlab-01. This repo holds the lab
access logbook: SSH/AnyDesk/physical session capture, a SQLite bridge, and
Excel reporting. It is being published to GitHub.

## CRITICAL — privacy and security (read before anything else)

Logix processes student names, NIM (student IDs), and client IP addresses.
NONE of that data may ever be committed to git.

Before any commit, verify:
1. `.gitignore` is in place and blocks *.db, session.json, *.xlsx, *.log,
   config.env, and *service-account*.json. Do not weaken these patterns.
2. `git status` shows NO database, no .xlsx report, no .json session file,
   no .log, no credentials. If any appear, STOP and fix .gitignore first.
3. Grep the diff for secrets before pushing:
   `git diff --cached | grep -niE '([0-9]{1,3}\.){3}[0-9]{1,3}|token|secret|password|[0-9]{8,}:[A-Za-z0-9_-]{30,}'`
   Any hit -> stop and investigate.
4. Never commit the actual notify.db or any copy of it, even "for testing."
   Use a synthetic fixture DB created in-test if you need test data.

If you are ever unsure whether something contains PII, do NOT commit it.
Ask first.

## Phase 1 — publish current state (do this first)

The current code is already here. Your job for phase 1 is hygiene, not
features:
- Confirm the repo contains code only (no data). Run the checks above.
- Add a LICENSE (MIT) if missing.
- Make sure README.md's privacy section is intact and accurate.
- Light CI: a workflow that imports the Python modules and runs any tests,
  on a throwaway in-memory/synthetic DB only.
- Tag an initial release (e.g. v0.1.0) — this is a reference publication,
  not a polished product, so semver starting at 0.x is honest.
- Do NOT refactor the capture logic in phase 1. Publish what works.

## Phase 2 — GSheet sync (only after phase 1 is published)

Implement `docs/GSHEET_SYNC_DESIGN.md` EXACTLY. The redaction gate is the
core requirement, not an add-on:
- Build `logix/gsheet_sync.py` with a pure `redact(row) -> dict` function
  FIRST, and unit-test it before writing any Google API code. The test must
  assert that no client IP and no raw NIM can appear in the output.
- One-way upsert only. Service-account auth. Creds path from config.env,
  never hardcoded, never committed.
- Isolate the Google dependency to this one module so the rest of Logix stays
  dependency-light.
- Follow the design's test plan. Do not ship sync until redact() tests pass.

Do not start phase 2 until phase 1 is on GitHub and the privacy checks pass.

## Constraints

- Don't change the existing DB schema or the capture scripts' behavior in
  phase 1.
- Keep the Windows PowerShell scripts as-is (they're environment-specific;
  document, don't rewrite).
- All new config via config.env (gitignored), never inline constants.
