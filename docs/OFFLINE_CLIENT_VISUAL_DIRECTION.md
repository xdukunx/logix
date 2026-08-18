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

---

# Reference intake

One section per reference. Principles, not components.

## Reference 01 — light editorial CRM

**Source:** light dashboard, cream banded header, kanban board below.

**Transferable principles**
- A **tinted band** can group the current-state row so it reads as one
  object instead of four floating cards.
- Generous whitespace and a short type scale carry hierarchy without boxes.
- Hairline borders; surfaces separated by lightness, not shadow.
- Compact left nav with grouped sections and quiet selection treatment.
- A dense header strip can hold several unrelated readings if the type is
  disciplined.

**Not transferable**
- Kanban columns — sessions are not a pipeline.
- Bar chart of "new customers per weekday" — Logix has no comparable series
  on the Overview.
- Radial "68% successful deals" — no success/failure ratio exists.
- Member list with avatars and roles — Logix knows one person at a time.
- "Add customer" as the primary action — the dashboard is read-only; the
  primary action lives in the WPF client.

**Potential Logix application**
- Health band grouping CPU / memory / GPU / storage.
- Nav shape and selection treatment.
- Header strip carrying workstation identity plus sync state.

## Reference 02 — dark technical console

**Source:** dark dashboard, restrained blue accent, metric cards with
sparklines, activity list.

**Transferable principles**
- One accent doing all the colour work against a near-monochrome surface.
- Compact metric cards on a strict grid; label above, value dominant.
- An **activity list with right-aligned timestamps** is the correct shape
  for recent sessions.
- Status as a small dot beside a word.
- Persistent nav with a pinned identity chip at the bottom.
- Dark surfaces with their own contrast logic — proof that dark is a real
  design, not a filter over light.

**Not transferable**
- Sparkline under every metric — telemetry is instantaneous and nothing is
  persisted.
- `+8.6%` / `-2.42%` deltas — no previous period exists.
- Segmented donut at "26%" — no part-to-whole for that number.
- "Bonus earned" promo card with a CTA and a glowing 3D card render.
- Glow, gradient and star-field decoration.

**Potential Logix application**
- Dark theme structure and accent discipline.
- Recent-logs list composition.
- Pinned identity chip — but pinning the **workstation**, not the person.

## Reference 03 — sage property dashboard

**Source:** light neutral page, white cards, icon-rail nav, muted green
accent.

**Transferable principles**
- **Icon rail navigation**: very narrow, leaves the width to content. A
  credible option for a product with three or four destinations.
- **One card inverted to the accent** to mark the primary object on the
  page — the single strongest idea in this reference for Logix, because
  Logix has exactly one genuinely primary object: the active session.
- Neutral page background with white cards; elevation by lightness rather
  than shadow.
- Uniform card geometry and gutters across a mixed grid.

**Not transferable**
- Radial gauge at "80%" framed as a goal — Logix has no targets.
- Sparkline inside every stat card — no history.
- 3D credit-card render, avatar, follower/following counts.
- "Keep you safe!" security-promo card with a CTA.
- A coloured circular icon badge per card — icon soup by another name.

**Potential Logix application**
- Inverted accent surface for the **current usage** card, so the answer to
  the page's question is unmistakable at a glance.
- Light-theme structure: neutral page, white cards.
- Icon rail as a candidate nav shape (still open).

## Reference 04 — warm CRM dashboard

**Source:** orange gradient page, pill filters, very large numerals,
gauge, dot-density series.

**Transferable principles**
- **Segmented control for time range** (Today / Yesterday / Weekly /
  Monthly) is more legible and more direct than a dropdown, and it is
  purely structural — it implies no data.
- **Numeral-first metric composition**: very large figure, small labelled
  caption beneath.
- A search field with a visible **keyboard hint** is a cheap, honest
  affordance.

**Not transferable**
- Warm gradient page background — conflicts directly with a restrained
  technical console.
- "Goals: $7580 out of 7000" gauge — no goal concept in Logix.
- Dot-density series per lead source — no historical telemetry.
- A distinct coloured icon per metric card.
- "See All" rendered as decorative accent text.

**Potential Logix application**
- Replace the Logs range `<select>` with a segmented control.
- Numeral-first treatment for the four telemetry readings.
- Keyboard hint on the Logs search field.

## Reference 05 — vitals monitor

**Source:** health dashboard with live readings, waveform traces, 3D organ
renders, glass surfaces.

This is the closest **conceptual** analogue in the whole set. It answers
the same shape of question Logix asks: *what is this system doing right
now?* Its composition is therefore worth more than its styling.

**Transferable principles**
- The **vitals row**: label, current value, and a trace — several related
  readings grouped in one panel rather than scattered as separate cards.
  This is Reference 01's band idea arriving from a different direction, and
  the agreement between them is a signal.
- **Current value held in a chip at the end of the trace**, separating "the
  reading now" from "the reading over time".
- Status as **word plus dot** ("Heart · Normal") — never colour alone,
  which is exactly the accessibility rule this project already committed to.
- Readings that are simply unavailable are omitted, not zeroed.

**Not transferable**
- 3D anatomical renders — decorative and heavy.
- Glassmorphism throughout — explicitly excluded.
- "7,425 of 10,000 steps" gauge — a target, which Logix does not have.
- The waveform traces themselves, **unless** the in-memory ring buffer
  (§11) is approved. Without it they would be invented data.

**Potential Logix application**
- Group the four telemetry readings into one health panel.
- Word-plus-dot status treatment throughout.
- If the ring buffer is approved, the value-chip-plus-trace composition is
  the right shape for it — and would be honest, because the trace would be
  real samples taken while the page was open.

## Cross-cutting observation

Four of the five references center a **gauge or donut**, and none of them
transfer — every one encodes a goal, a target, or a success ratio, and
Logix has none of those.

But the distinction needs to be precise, because it decides real UI:

- **Legitimate part-to-whole**: CPU load, memory used of total, storage
  used of total. These are genuinely fractions of a known whole, so a bar
  or an arc is truthful.
- **Not legitimate**: any dial implying a target, a score, or progress
  toward a goal. Logix has no goals, and a gauge invents one by implication.

So the shape may be borrowed; the meaning may not.

---

## 14. Resolved

All references are in. Every question this document held open is now
decided, and the decisions live in
[OFFLINE_CLIENT_UI_SPEC.md](OFFLINE_CLIENT_UI_SPEC.md). Recorded here so
the reasoning stays with the research that produced it.

| Was open | Decided | Why |
|---|---|---|
| Default theme | **Light**, dark opt-in | A shared lab machine is used briefly, by many people, in a lit room. Dark loses contrast under overhead light and haloes for astigmatic readers. Dark still ships because compute labs run dim at night. |
| Accent | **`#1A5D6E`** petrol | `#2F5BEA` sat within a few degrees of Reference 02 and reads as generic SaaS indigo. Petrol reads as instrumentation, is distinct from all five references, and carries white text at ~7:1. |
| Nav shape | **Sidebar, 208px, text-only** | Four destinations. An icon rail needs icons to be legible; icons need a package or hand-drawn SVG, and neither buys clarity here. |
| Icons | **Text + 3 CSS shapes + 1 inline SVG** | Smallest thing that works and adds no dependency. |
| Telemetry shape | **One grouped panel** | References 01 and 05 reached this independently from opposite directions. Four boxes imply four subjects; this is one machine. |
| Bars vs arcs vs rings | **3px horizontal bars** | Least decorative form that still shows proportion. Two divs, no SVG, legible at 3px. |
| Current usage treatment | **Tint + 2px accent left edge** | Reference 03 inverts a whole card; at this size that becomes a coloured slab. Important, not loud. |
| Range control | **Segmented** | Four options, used constantly, current value readable without opening anything. |
| Table density | **Compact, 36px rows** | A full lab day should fit without scrolling. |
| Details | **Side sheet** | Keeps the row visible behind it and returns the reader to their place. |
| Page order | Health above usage, **usage accented** | Order follows the requested composition; emphasis follows the product hierarchy. Set independently, on purpose. |
| Sparklines from a ring buffer | **No** | Reference 05 makes the strongest case for it, but it is a functional change to satisfy a visual want. Revisit only if someone asks to watch a load over time. |
| Workstation subtitle | **Hostname, or nothing** | `location` and `category` are server-side only. The block closes up cleanly when absent rather than inviting invented text. |
