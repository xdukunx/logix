# Visual direction — local workstation console

Written against the working dashboard at `b539885`, after the first two
visual references. **Nothing here is implemented.** More references are
coming, so this records the direction and, just as deliberately, what is
being left undecided.

The functional architecture, data sources, API and tests stay exactly as
they are. This is about presentation only.

---

## 0. The constraint that outranks the references

Logix is a **local, offline dashboard client**: stdlib `http.server`, no
framework, no build step, no CDN, no Electron. The page is served from the
device to the browser that is already installed on it.

That is not a compromise to design around — it is the reason the product
can be lightweight at all. Both references are heavyweight web apps and
will suggest components that cost a bundler, an icon set, and a chart
library. Every borrowed idea has to survive being written as plain CSS and
a few hundred lines of vanilla JS, or it does not get borrowed.

Practical consequences: no icon font or SVG sprite sheet unless the icons
are inlined and few; no charting library; no webfont download (system font
stack only); no runtime dependency added to make the page look better.

## 1. What each reference is actually for

**Reference 01 — light, editorial.** Take the *air*: generous whitespace,
a real type scale, hairline borders instead of boxes, and the idea of a
**tinted band** grouping the current-state row so it reads as one object
rather than four floating cards. Its compact left nav with grouped sections
is close to what Logix needs.

**Reference 02 — dark, technical.** Take the *posture*: operational
density, compact metric cards, one restrained accent doing all the colour
work, a persistent nav, and status expressed as small dots rather than
badges. This is what a machine console should feel like at 2am.

**Neither gets copied.** Reference 01 is a CRM and Reference 02 is a team
analytics product; their semantics are not ours.

## 2. What must NOT be taken, and why it matters

This is the most important section, because both references are full of
affordances Logix has no data for.

| In the references | Why Logix cannot have it |
|---|---|
| Sparkline under every metric card | Telemetry is **instantaneous**. Nothing is persisted (by design — telemetry is not a logbook event). A trend line would be drawn from data that does not exist. |
| Trend arrows, `+8.6%`, `-2.42%` | Requires a previous period. There is none. |
| Donut with a headline percentage | No meaningful part-to-whole here. A ring showing "26%" of nothing is decoration. |
| Promo card ("Bonus earned", "Learn More") | Marketing surface. Logix has nothing to sell its own user. |
| Kanban columns | Sessions are not a pipeline. |
| Avatars, follower counts, member lists | Logix knows one person at a time: whoever is signed in to this machine. |
| Credit cards, balances, currency | Not this product. |

The rule from the brief holds without exception: **every displayed number
must have a real source.** Where a reference makes a card look good by
adding a chart, Logix has to make it look good with type and spacing
instead.

## 3. Typography

Type does the work, because it is the only free material we have.

- **System stack only.** No webfont — it would be a network fetch on a
  local-first page. `-apple-system / Segoe UI / Inter / system-ui`.
- **One monospace role, not a theme.** Tabular figures for durations,
  clocks, byte counts, NIMs and job ids — anything that should not jitter
  as it updates or shift as it aligns in a column. Prose stays sans.
- **A short scale**: eyebrow (11px, uppercase, tracked) · body (13–14px) ·
  card metric (24–26px) · session clock (30px+) · station name (27px+).
  Reference 01 earns its calm by having few sizes used consistently, not by
  having many.
- Weight carries hierarchy before size does; colour carries it last.

## 4. Colour philosophy

- **Near-monochrome plus exactly one accent.** Both references are
  disciplined here and Logix should be stricter, because a workstation
  console is read for state, not browsed.
- **Colour is reserved for state**, never for decoration. Green = fine or
  synced. Amber = attention, not alarm. Red = an actual failure. Anything
  merely informational stays neutral.
- **`local_only` is neutral, never coloured as a warning.** This is a
  product rule from the UX contract with a visual consequence: the most
  common configuration in the field must look like success, because it is.
- No gradients, no glass, no glow. Reference 02 uses a glow card and Logix
  will not.
- The current accent (`#2F5BEA`) is close to Reference 02's blue. Whether
  Logix keeps a blue at all is **open** (§12).

## 5. Layout philosophy

Overview answers one question — *what is happening on this workstation
right now* — so the page is ordered by that, not by what dashboards
usually contain:

```
  workstation identity        who am I looking at
  ────────────────────────
  current health              is the machine OK
  ────────────────────────
  CURRENT USAGE               who is here, what are they doing   <- dominant
  ────────────────────────
  recent usage                what happened just before
```

Historical analysis is a different page and stays there. Reference 01
groups its current-state metrics into a single tinted band; that idea suits
the health row well and is the strongest borrowable composition in either
image.

## 6. Navigation

Persistent, compact, quiet — as in both references. Four destinations at
most (Overview / Logs / Server, plus Settings when it exists). No badges,
no counters, no nested trees. Reference 01 pins a user chip at the bottom
of the nav; Logix should pin the **workstation** there instead, because the
machine is the persistent identity here and the person is transient.

## 7. Cards

A card is a container for one operational fact, not a visual style.

- Hairline border, flat surface, modest radius. No shadow.
- Label (eyebrow) → value → context line, in that order, every time.
- Absent data renders as **"Unavailable"** or an em dash in muted type, at
  a smaller size than a real value — so an absent GPU can never be mistaken
  for an idle one at a glance.
- The **current-usage card is deliberately not a peer** of the others. It
  is the answer to the page's question and should be larger, quieter inside,
  and unmistakably primary.

## 8. Tables

The Logs page is a table and should look like one, not like a stack of
cards (Reference 01 makes this mistake for its records; its *header* area
is what to learn from).

- Row separators only; no column rules, no zebra striping.
- Numeric and time columns tabular and right-aligned; text columns left.
- Quiet hover, whole row clickable, details in a side sheet so the reader
  never loses their place.
- Density tuned for a lab: comfortable enough to scan, tight enough that a
  day of sessions fits without scrolling.

## 9. Workstation identity

The workstation is a **first-class object**, present on every view — not a
banner on one.

```
  You are using workstation
  LAB-03
  Computational Research Node
```

Understated: small eyebrow, large name, quiet subtitle. The name should be
the largest text on the page after the active session clock.

Honest constraint: the subtitle line ("Computational Research Node") has
**no local source today**. Device `display_name`, `location` and `category`
exist server-side and arrive only on a paired device via the cached config.
On a device-only install there is nothing but the hostname. So the subtitle
must degrade to nothing rather than to invented text — and whether it is
worth surfacing at all is **open**.

## 10. Active session emphasis

The single most important region. It carries person, purpose, job, elapsed
time and state, and it should read in one glance from across a lab bench.

- The clock is the visual anchor: large, monospaced, tabular.
- `tujuan` is the headline, not the person — the person is the byline.
- Job metadata sits as a quiet metaline and renders an em dash when absent,
  which today is always (the sign-in popup does not collect it yet).
- Idle is a designed state, not an empty one: *"No active usage — this
  workstation is currently idle."* It should look intentional.

## 11. Telemetry presentation

Four readings, equal weight, no hierarchy between them — CPU, memory, GPU,
storage.

Current implementation draws a thin utilization bar under each. That is
honest for an instantaneous reading. The open question is whether to keep a
**short in-memory ring buffer** (say 60 samples, never written to disk) so
a real sparkline could be drawn from real data. That would satisfy the
reference's shape without inventing anything — but it is a functional
change, so it waits (§12).

GPU is never polled on the page timer; it is cached and refreshed
explicitly. Whatever the visual treatment, it must not imply a live feed.

## 12. Dark and light

Both are wanted, for a real reason rather than taste: a lab workstation is
often used in a dim room, and a console that glares is a console that gets
closed.

Direction: **build the palette as tokens now, ship light first, add dark
when the token set is proven.** Dark is not a filter over light — Reference
02 shows a dark surface with its own contrast logic, and the accent has to
be re-picked for it, not reused.

Which is the *default* is **open**.

## 13. Interaction philosophy

- Feedback is immediate and small: hover, focus ring, pressed state. No
  page-level spinners for a local query that takes milliseconds.
- Focus must be visible and keyboard order sensible; the side sheet closes
  on Escape.
- State is never carried by colour alone — a dot always sits beside a word.
- Nothing animates that is not communicating a change.
- Refresh is quiet: telemetry updates in place with no flash, no skeleton,
  no layout shift.

## 14. Deliberately NOT decided yet

Waiting on the further references:

1. **Default theme** — light or dark.
2. **The accent** — whether Logix keeps a blue, and which one. Current
   `#2F5BEA` is provisional and sits close to Reference 02.
3. **Exact palette and surface levels** for both themes.
4. **Density scale** — comfortable versus compact, and whether it is a
   user setting.
5. **Icons at all** — currently none. Both references use them in nav;
   Logix may not need any, and every one added is inlined weight.
6. **Sparklines from an in-memory buffer** (§11) — real data, but a
   functional change.
7. **Whether the workstation subtitle is surfaced** given it has no local
   source (§9).
8. **Nav shape** — full sidebar versus the icon rail of the third style of
   reference layout.
9. **Whether Overview and Logs share one shell** or Logs gets its own
   header treatment.

## 15. What changes in the current implementation

Recorded for when work resumes — not to be acted on yet:

| Now | Direction |
|---|---|
| Station name is a plain heading | First-class identity, present on every view, pinned in nav |
| Current usage is a peer card | Visually dominant, distinct from the metric row |
| Health row is four loose cards | One grouped band, per Reference 01 |
| Light only, colours hard-coded | Tokenised palette, dark theme possible |
| Utilization bars | Open: bars, or true sparklines from an in-memory buffer |
| Table is serviceable | Density, tabular figures and alignment tuned |
| No empty-state design beyond text | Idle and no-data states designed as states |

Nothing in this table justifies touching the API, the data model, the
server, YASB, or the tests.
