# Superseded — v1/v2 design set

**This directory is history. It is not the design source of truth.**

The current one is [`docs/design_handoff_logix_v3/`](../design_handoff_logix_v3/),
whose `README.md` is canonical for tokens and per-screen anatomy, with the
`*.dc.html` prototypes as the pixel reference. See
[`frontend/.claude/CLAUDE.md`](../../frontend/.claude/CLAUDE.md).

Everything here predates the v3 "Clean Calibration" pass, which changed enough
that matching these files would now produce the wrong UI:

- the Astryx design system (`@astryxdesign/core`) these briefs build on was
  removed outright, and must not be reintroduced;
- the Analytics and Layar/Screens routes they specify no longer exist
  (Analytics became Riwayat; screenshot became a per-device action);
- tokens, spacing and the card anatomy were all re-specified in v3.

`LogiX_BUILD_BRIEF.md` in this directory still says the files here are "the
visual source of truth". That was true when it was written and is not true now.

Kept because the reasoning in the PRDs and the copy deck is still worth
reading, and because the v3 set is a revision of this one rather than a
clean-sheet redesign. Nothing here is shipped, imported, or built.
