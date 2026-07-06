# CLAUDE.md

This project's working rules live in [AGENTS.md](AGENTS.md) — they apply to
any model, Claude included. Read that file first; this file only adds
Claude Code-specific notes and defers to AGENTS.md for everything else.

If [GEMINI.md](GEMINI.md) is also present, it documents Antigravity-specific
behavior only and does not apply to Claude Code sessions.

## Project-specific must-reads

- [docs/CLAUDE_CODE_HANDOFF.md](docs/CLAUDE_CODE_HANDOFF.md) — privacy/security
  rules for this repo. Logix processes student names, NIMs, and client IPs.
  None of that data may ever be committed. Check `.gitignore` and diff for
  secrets/PII before any commit, per that doc.
- [docs/GSHEET_SYNC_DESIGN.md](docs/GSHEET_SYNC_DESIGN.md) — required design
  for the Google Sheets sync feature (redaction gate is non-negotiable).

## Stack

- Backend: Python (`server/`, `logix/`) — FastAPI app in `server/main.py`.
- Frontend: React 19 + TypeScript + Vite in `frontend/`, built on the Astryx
  design system (`@astryxdesign/core`). Conventions for UI work live in
  [frontend/.claude/CLAUDE.md](frontend/.claude/CLAUDE.md) — read it before
  touching UI code (discover components via `npx astryx build/component`,
  no raw `<div>` layout, tokens only).
  - Dev: `npm run dev` in `frontend/` (proxies `/api` to `localhost:8791`).
  - Prod: `npm run build`; `server/main.py` serves `frontend/dist/` when it
    exists, else falls back to the legacy vanilla-JS UI in `server/static/`.
- The legacy dashboard (`server/static/`) is kept as the no-Node fallback;
  fix bugs in the React app, not there.
- Windows-specific capture scripts live in `windows/` (PowerShell) — treat as
  environment-specific, document rather than rewrite, per AGENTS.md.
