# Contributing to Logix

Thanks for your interest. Logix is a privacy-conscious device/session logbook;
contributions are welcome as long as they respect its scope and privacy stance.

## Ground rules

- **Privacy first.** Never add keylogging, screenshots, browser/URL capture,
  location tracking, or any hidden monitoring. See `docs/PRIVACY.md`. PRs that
  cross these boundaries will be declined regardless of quality.
- **No PII in the repo, ever.** No real names, IDs, IPs, databases, reports, or
  logs — not in code, tests, fixtures, screenshots, or commit history. Use
  synthetic data (see `tests/` for examples).
- **No secrets.** API keys, OAuth secrets, service-account files, and passwords
  come from environment variables. `.gitignore` already blocks the usual
  offenders; verify before pushing.

## Branches

`main` is the only long-lived branch, and it is always releasable: CI is green
on every commit and the tip is what a one-liner installer clones. Everything
else is short-lived.

- **Name a branch for its change, prefixed by kind:** `fix/`, `feat/`,
  `docs/`, `chore/`, `ci/` — e.g. `fix/device-duplicate-on-enrol`. The prefix
  is the same vocabulary as the commit subject, so a branch and its commits
  read as one thing.
- **One branch, one change.** A branch that accumulates three unrelated
  features is a branch nobody can review or revert cleanly.
- **Delete it the moment it merges.** Four branches were once left behind this
  way; three had already been fully merged and the fourth had been superseded
  months earlier, so the only thing they still communicated was uncertainty
  about whether they contained something.
- **Rebase on `main` rather than merging `main` into your branch**, so history
  stays linear and a revert is one commit.

Nothing has to be preserved just because it was pushed once. A branch whose
commits are ancestors of `main` (`git branch -r --merged origin/main`) can be
deleted with no loss at all. A branch with unique commits that are *superseded*
gets a tag before deletion, so the commit stays reachable without a dead branch
implying live work:

```bash
git tag -a archive/<branch> <sha> -m "why this was superseded"
git push origin archive/<branch>
git push origin --delete <branch>
```

`archive/*` tags are history, not releases; release tags are `v*`.

## Development setup

```bash
# Core is stdlib-only (Python 3.11+). Tests need pytest.
python -m pip install pytest
python -m pytest tests/ -q

# What CI runs (parse + import + synthetic round-trip + redaction dry-run):
python -m py_compile logix/*.py
```

The optional GSheet sync needs `pip install -r requirements-sync.txt`. The
central server needs `pip install -r server/requirements.txt`.

## Making changes

- **Minimal, focused changes.** Change only what the issue/PR is about. Note
  unrelated problems as separate issues rather than fixing them inline.
- **Keep the core stdlib-only.** Isolate new third-party dependencies to the
  optional modules (sync, server), and document them.
- **Configuration, not hardcoding.** New labels, colors, org names, paths, or
  field lists belong in the config schema (`docs/config.schema.json`), not in
  source. Validate config changes against that schema.
- **Migrations, not ad-hoc schema edits.** Extend the idempotent `migrate()`
  path in `logix/log_physical.py`; additive columns only, so existing local
  databases keep working.
- Explain **what** changed and **why** in the PR description, and show how you
  verified it (tests, or a reproducible manual check).

## Commit / PR checklist

- [ ] No PII or secrets added (code, tests, screenshots, history).
- [ ] `python -m pytest tests/ -q` passes.
- [ ] `python -m py_compile logix/*.py` passes.
- [ ] New config keys validate against `docs/config.schema.json`.
- [ ] Docs updated if behavior or setup changed.
- [ ] Change stays within Logix's privacy scope.

## Reporting security issues

Do **not** open a public issue. Follow `SECURITY.md`.
