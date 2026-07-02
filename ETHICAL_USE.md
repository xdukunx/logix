# Ethical use of Logix

Logix is released under the [MIT License](LICENSE). MIT is a permissive
license: it does not, and legally cannot without ceasing to be MIT, restrict
what anyone does with this code. **This document is not a license term, is
not legally enforceable, and does not modify the LICENSE in any way.** It is
a statement of intent from the maintainer, and a request to anyone who
deploys or forks this project.

Read this alongside [docs/PRIVACY.md](docs/PRIVACY.md), which describes what
Logix collects and the privacy-mode controls available to limit it.

## What Logix is for

Logix was built to answer a narrow, legitimate question for a shared lab
workstation: *who used this machine, when, and for how long* — the same
category of record a physical sign-in sheet has kept for decades, just
digitized and harder to lose. It exists so a lab can produce honest usage
reports and manage shared/loaned hardware, with the people being logged
told plainly that logging is happening.

## What Logix is not for

Do not deploy Logix, or a fork of it, to:

- monitor a person without their knowledge that the device is managed and
  logged
- capture data outside its documented scope (see "Design boundaries —
  session/logbook core" in [docs/PRIVACY.md](docs/PRIVACY.md) — no
  keylogging, no browser history, no camera/microphone, no location
  tracking, ever; screen view/remote control are handled separately by
  [Logix Control](docs/LOGIX_CONTROL.md) under its own explicit-action,
  audit-logged, never-silent boundary in the same document — that model
  extends transparent, disclosed device management, it is not a carve-out
  for surveillance); if you add a feature outside either boundary to a
  fork, it is no longer in the spirit of this project
- monitor personal, non-institution-owned devices
- build a profile of a person's behavior beyond simple session
  attendance/duration
- retaliate against, discipline, or single out individuals using data
  collected covertly

## If you deploy Logix

You are the data controller for what it records. At minimum:

1. Tell the people who use the device that it is managed and logged, ideally
   directly on the sign-in popup, before their first session.
2. Choose the least-revealing `privacyMode` that meets your actual need
   (`local_only` by default — see [docs/PRIVACY.md](docs/PRIVACY.md)).
3. Follow your institution's and jurisdiction's data-protection
   requirements — retention limits, access control, deletion on request.
4. Don't repurpose the data for anything beyond usage/attendance reporting
   without telling the people it's about.

## Why this isn't a license restriction

Apache 2.0 and other OSI-approved licenses generally can't carry
use-restriction clauses either — but Logix specifically ships under MIT,
whose standard text cannot be modified while still calling it "MIT." A
legally binding usage restriction would require a source-available license
instead of a true open-source one; that tradeoff was considered and
declined, so that Logix stays fork-friendly and freely reusable. The
consequence is that this document is a social signal, not a legal backstop.
If that gap matters for your deployment, get your own legal advice — this
file is not it.
