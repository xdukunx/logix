# Logix UI specification — local workstation console

Final design specification. **Not implemented.** Research and rationale live
in [OFFLINE_CLIENT_VISUAL_DIRECTION.md](OFFLINE_CLIENT_VISUAL_DIRECTION.md);
this document is the decisions.

Every value here is implementable with stdlib `http.server`, one HTML file,
plain CSS and vanilla JS. No framework, no build step, no CDN, no webfont,
no icon package, no chart library, no Electron.

---

## 1. Design philosophy

Logix is a **workstation operations console with a local research
logbook**. It answers, in order:

1. Which workstation is this?
2. Is it in use, and by whom?
3. What are they doing, and under what job?
4. Is the machine healthy?
5. What happened recently, and where is the full history?
6. Is any of this leaving the device?

Three rules govern every decision below.

**Current state outranks history.** The Overview is a console, not an
analytics page. Historical work lives in Logs.

**Every mark has a source.** If a visual device would need data Logix does
not hold, it is replaced by typography and spacing, not filled with a
plausible number. This is why there are no sparklines, no trend arrows, no
period deltas and no gauges-with-targets anywhere in this spec.

**Absence is a designed state.** Unavailable telemetry, an idle
workstation, an empty log and a device that never syncs are all normal, and
each has a deliberate appearance rather than a gap where something failed.

## 2. Theme

**Light is the default. Dark is optional and opt-in.**

A shared lab workstation is used by many people, for short stretches, in a
room lit for working — not by one person at night in a dim office. Under
overhead light a dark console loses contrast and gains reflection, and
light-on-dark text haloes badly for readers with astigmatism, which is a
large fraction of any lab. The editorial references are also the ones whose
*information density at rest* suits a page someone glances at for four
seconds on the way past.

Dark exists because computational labs do run dim at night, and because a
machine console that glares gets closed. It is **not a filter over light**:
surfaces get their own contrast ladder and the accent is re-picked, because
a mid-tone petrol that reads as authoritative on white reads as murky on
near-black.

Implementation: one token block on `:root`, one override block under
`[data-theme="dark"]` plus `@media (prefers-color-scheme: dark)`. Only
colour tokens are redefined — type, spacing, radius and motion are shared,
so dark costs roughly 20 declarations, not a second design system.

## 3. Colour tokens

### Light (default)

| Token | Value | Role |
|---|---|---|
| `--bg` | `#F6F5F2` | page ground, warm off-white |
| `--surface` | `#FFFFFF` | panels, table |
| `--surface-subtle` | `#FBFAF8` | row hover, nested fills |
| `--surface-accent` | `#EEF4F6` | current-usage panel tint |
| `--border` | `#E3E0DA` | hairlines |
| `--border-strong` | `#CFCBC3` | table head rule, focus outline base |
| `--text` | `#14161A` | primary |
| `--text-muted` | `#565C63` | secondary, captions |
| `--text-faint` | `#8A9098` | eyebrows, absent values |
| `--accent` | `#1A5D6E` | see §4 |
| `--accent-hover` | `#144A58` | |
| `--accent-ink` | `#FFFFFF` | text on accent fill |
| `--ok` | `#2E6F4E` | synced, healthy |
| `--warn` | `#8A5A12` | attention, not alarm |
| `--err` | `#A33A2A` | real failure |

### Dark (optional)

| Token | Value |
|---|---|
| `--bg` | `#0F1113` |
| `--surface` | `#16191C` |
| `--surface-subtle` | `#1B1F23` |
| `--surface-accent` | `#12272E` |
| `--border` | `#262B30` |
| `--border-strong` | `#373D44` |
| `--text` | `#E8EAEC` |
| `--text-muted` | `#9AA1A9` |
| `--text-faint` | `#6B727A` |
| `--accent` | `#4FB3C9` |
| `--accent-hover` | `#6BC6D9` |
| `--accent-ink` | `#0F1113` |
| `--ok` | `#5FB98A` |
| `--warn` | `#D4A257` |
| `--err` | `#E0796A` |

## 4. The accent

**`#1A5D6E` — a desaturated petrol blue.**

The provisional `#2F5BEA` is dropped: it is within a few degrees of
Reference 02's accent, and a bright saturated indigo is the single most
common accent in SaaS dashboards, which is the category Logix must not be
mistaken for. Petrol reads as instrumentation rather than product
marketing, it is distinct from every reference in the set (indigo, sage,
orange), and being dark it can carry white text at ~7:1 without a second
tint.

It is deliberately far from `--ok` green, `--warn` amber and `--err` red,
so a selected control can never be misread as a state.

Used **only** for: the current-usage panel edge and tint, the selected
navigation item, focus rings, the primary button, and the segmented-control
selection. Not for headings, not for links inside prose, not for icons, not
for decoration.

## 5. Typography

System stack only. A webfont is a network fetch on a page whose entire
premise is that it works with the network gone.

```
--font: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter,
        system-ui, sans-serif;
--mono: ui-monospace, "Cascadia Mono", "SF Mono", Menlo, Consolas, monospace;
```

| Token | Size / weight | Used for |
|---|---|---|
| `--text-xs` | 11px 600, `.08em`, uppercase | eyebrows, column heads, status |
| `--text-sm` | 12px 400 | captions, secondary metrics |
| `--text-md` | 13px 400 | body, table cells, controls |
| `--text-lg` | 15px 600 | panel titles, person name |
| `--text-xl` | 20px 600 | session purpose |
| `--display` | 26px 640, `-0.02em` | workstation name, telemetry values |
| `--clock` | 34px 600 mono | elapsed time |

**Mono is a role, not a theme.** It applies to elapsed time, timestamps,
byte counts, percentages, NIM and job id — anything that would jitter as it
updates or fail to align in a column. `font-variant-numeric: tabular-nums`
everywhere numerals appear, including in the sans stack.

The elapsed clock is 34px, not 48px. It is operational information read at
a glance, not hero copy; large enough to read across a bench, small enough
that it does not become the page's subject.

## 6. Spacing

A 4px base, seven steps, no values outside it.

```
--space-1:  4px    icon-to-label, dot-to-word
--space-2:  8px    control padding, tight stacks
--space-3: 12px    table cell padding, card inner gaps
--space-4: 16px    panel padding, row rhythm
--space-5: 24px    panel-to-panel
--space-6: 32px    section separation
--space-7: 48px    page top padding, major breaks
```

Applied consistently: page padding `--space-6` horizontal / `--space-7`
top; panel padding `--space-4`; table cells `--space-3` vertical; nav items
`--space-2`; section gaps `--space-5`.

## 7. Borders, surfaces, radius

**Borders over shadows, everywhere.** Exactly one element in the product
casts a shadow: the details side sheet, because it genuinely floats over
the page and needs the separation. Nothing else.

- Border: `1px solid var(--border)`. No 2px borders except the accent edge.
- Radius: `--radius-sm 4px` (controls, chips) · `--radius-md 8px` (panels,
  table) · `--radius-lg 12px` (side sheet only).

When an object gets what:

| Treatment | Applies to |
|---|---|
| No border, no fill | section headings, the recent-logs list, page structure |
| Hairline border on `--surface` | telemetry panel, table, server card |
| `--surface-accent` + 2px accent left edge | the current-usage panel, and nothing else |
| Filled `--accent` | one primary button per page, at most |

Not every group is a card. The recent-logs list is rows on the page ground
with separators — boxing it would make it a peer of the health panel, which
it is not.

## 8. Navigation

**Persistent left sidebar, 208px, text-only labels.**

```
  LOGIX

  Overview
  Logs
  Server
  ────────────
  Settings

  ┌──────────────────┐
  │ LAB-03           │   pinned bottom
  │ GPU-A100 · Local only│
  └──────────────────┘
```

- Selected item: `--surface-accent` fill, `--text` colour, 2px accent left
  edge. No bold-swap (it shifts layout), no pill, no icon.
- Hover: `--surface-subtle`.
- Does not collapse. Four destinations do not need a collapse control, and
  a collapsed rail with text-only labels is unreadable.
- The **workstation** is pinned at the bottom where the references pin the
  user, because here the machine is the persistent identity and the person
  is transient.

## 9. Workstation context

Persistent across every view, in the page header:

```
  YOU ARE USING WORKSTATION            ● Local only
  LAB-03
  GPU-A100
```

- Eyebrow `--text-xs` `--text-faint`; name `--display`; subtitle
  `--text-sm` `--text-muted`.
- The subtitle is the **hostname**, and only when it differs from the
  display name. There is no invented descriptor: `location` and `category`
  exist only server-side and only on a paired device, so on a device-only
  install the line is simply absent — and the block is laid out so its
  absence closes up cleanly rather than leaving a hole.
- Sync status sits at the opposite end of the same baseline, so "which
  machine" and "is anything leaving it" are read together.

## 10. Telemetry

**One health panel, not four cards.** References 01 and 05 arrived at this
independently. Four bordered boxes imply four unrelated subjects; these are
four readings of one machine, and grouping them says so.

```
  WORKSTATION HEALTH                              refreshed 2s ago

  CPU              MEMORY            GPU              STORAGE
  34%              21.4 GB           47%              312 GB free
  10 cores         of 64 GB          8.2 / 24 GB      of 1.8 TB
  ▂▂▂▂▂▂▂░░░       ▂▂▂▂░░░░░░        ▂▂▂▂▂░░░░░       ▂▂▂▂▂▂▂▂░░
```

One panel, four columns divided by hairlines. Per metric: label
(`--text-xs`) → value (`--display`) → secondary (`--text-sm`
`--text-muted`) → a **3px horizontal bar**.

**Horizontal bars, not arcs or rings** (§11). A bar is the least decorative
form that still shows proportion, costs two divs and no SVG, and stays
legible at 3px. Arcs and rings both need geometry to say the same thing.

Unavailable renders as `Unavailable` in `--text-sm` `--text-faint` — a
*smaller, quieter* treatment than a real value, with **no bar at all**, so
an absent GPU can never be mistaken for an idle one.

No trends. No arrows. No targets. No history. The "refreshed Ns ago" line
is the only temporal claim the panel makes, and it is true.

## 11. Proportion rule

**Allowed**, because these are real fractions of a known whole: CPU
utilization, memory used of total, storage used of total, GPU utilization,
VRAM used of total.

**Forbidden**: any dial implying a target, goal, score, grade, efficiency,
ratio-of-success, or progress. Logix has no targets, so a gauge would
invent one by implication.

The shape may be borrowed from the references; the meaning may not.

## 12. Current usage — the primary object

The one accented element on the page.

```
  ┃ CURRENT USAGE                              ● ACTIVE
  ┃
  ┃ DFTB Parameterization                      02:34:17
  ┃ Dhana · 000000000
  ┃ Simulation · Job 258026 · Langsung
  ┃
  ┃ started 08:41                              [ Details ]
```

`--surface-accent` fill, 2px `--accent` left edge, `--radius-md`. **Not**
an inverted accent card — Reference 03 inverts a whole card, which at this
size becomes a coloured slab and shouts. Important, not loud.

**Reading order, deliberate:**

1. **State** — `● ACTIVE`, top right, `--text-xs` uppercase.
2. **Purpose** (`tujuan`) — `--text-xl`, the headline. What is happening
   matters before who is doing it.
3. **Elapsed** — `--clock`, mono, right-aligned, sharing the baseline with
   the purpose.
4. **Person** — `--text-lg`, with NIM in `--text-muted` at the same size.
   Subordinate to the purpose but plainly visible.
5. **Job metaline** — `--text-sm --text-muted`, em dash when absent.
6. **Start time**, then **Details**.

`keterangan` is **not** on this panel. It is prose of arbitrary length and
belongs in Details.

Idle state replaces the whole panel and loses the accent (§14) — an idle
workstation is not the primary object of anything.

## 13. Status language

Always **indicator + literal words**. Colour is never the only carrier.

| State | Mark | Words | Colour |
|---|---|---|---|
| Active session | `●` | `ACTIVE` | `--accent` |
| Idle | `○` | `IDLE` | `--text-faint` |
| Local only | `●` | `Local only` | `--ok` |
| Sync blocked | `●` | `Synchronization disabled` | `--text-muted` |
| Sync pending | `●` | `N waiting to synchronize` | `--warn` |
| Syncing | `◐` | `Synchronizing…` | `--accent` |
| Synced | `●` | `All changes synchronized` | `--ok` |
| Server unavailable | `○` | `Server unavailable` | `--warn` |
| Sync error | `▲` | `Synchronization failed` | `--err` |

The dot is a 7px CSS circle, `--space-1` from its label, vertically
centred. `Local only` is `--ok`, never amber: on a device with no server
nothing is waiting, and the most common configuration in the field must
look like success because it is.

## 14. Empty states

Centred in the container they replace, `--surface`, 1px **dashed**
`--border`, `--radius-md`, `--space-7` padding. Title `--text-lg`, body
`--text-sm --text-muted`. No emoji, no illustration, no call to action
unless there is a real action.

| Where | Title | Body |
|---|---|---|
| No active session | `No active usage` | `This workstation is currently idle.` |
| No logs at all | `No sessions recorded` | `No sessions have been recorded on this workstation yet.` |
| No logs in range | `No sessions in this period` | `Try a wider date range.` |
| No search results | `No matching sessions` | `No session matches this filter.` |
| No GPU | `Unavailable` | `No supported GPU was detected.` (inline, in the panel) |
| No server | `Not connected` | `This workstation is not paired with a central server.` |

## 15. Error states

An error is scoped to the thing that failed. **The dashboard never turns
red**, because local logging continuing normally is the more important
fact.

```
  ● Server unavailable
    3 changes stored safely on this workstation.     [ Retry ]
```

- Telemetry failure: that metric alone reads `Unavailable`. The panel and
  page are unaffected.
- Server unavailable / sync error: one line on the Server page and one word
  in the header status. Never a modal, never a banner, never a toast.
- Export failure: an inline note under the Export button, with the reason.
- Malformed local status: the affected panel shows its empty state; the
  rest of the page renders.

Every failure message states what still works. No message ever implies
local data is at risk, because it never is.

## 16. Motion

```
--duration-fast:   120ms   hover, focus, button press
--duration-normal: 180ms   panel appearance, view switch
--ease: cubic-bezier(.2, .6, .2, 1)
```

Motion is used for: view transitions, the side sheet sliding in, selection
changes, hover and focus. Nothing else.

Explicitly not animated: telemetry bars (they would appear to be tracking
something), the clock, panels on data refresh, and anything on a timer.
Telemetry updates in place with no transition and no layout shift — the
clock and all numerals are tabular precisely so a changing digit moves
nothing.

```css
@media (prefers-reduced-motion: reduce) {
  * { animation: none !important; transition: none !important; }
}
```

## 17. Icons

**Text-only labels; three geometric primitives; one inline SVG.**

The smallest practical approach, and the only one that adds no dependency.

- Navigation, buttons and controls are **text**. With four destinations an
  icon adds weight and no clarity.
- Three CSS shapes: the status dot (7px circle, `border-radius:50%`), the
  disclosure caret (rotated 45° border box), the segmented-control divider.
- One inline SVG: the side-sheet close control, 16px, 1.5px stroke,
  `currentColor`, round caps.

No icon font, no sprite sheet, no package. If a future need appears, inline
SVG at 16px / 1.5px stroke is the house style.

## 18. Logs

An operational data surface, not a card wall.

- Table on `--surface`, hairline border, `--radius-md`.
- **Row separators only** — no column rules, no zebra.
- Row height 36px, cell padding `--space-3`, text `--text-md`. Compact: a
  full lab day should fit without scrolling.
- Column heads `--text-xs` uppercase `--text-faint`, one `--border-strong`
  rule beneath.
- Time, duration, NIM and job id are mono and tabular; times and durations
  right-aligned, text left.
- Whole row clickable, hover `--surface-subtle`, focusable with a visible
  ring, Enter opens Details.
- No pagination. The local database is one workstation's history; the
  ranges (§19) bound it, and All-time on a real device is hundreds of rows,
  not millions. If that assumption ever breaks, add a count-capped fetch
  before adding pager chrome.

Columns: `Start · End · Name · NIM · Purpose · Job · Duration · State`.

## 19. Time range control

**Segmented control**, not a dropdown.

```
  [ Today ][ 7 days ][ 30 days ][ All ]
```

Four options, high frequency of use, and the current value is readable
without opening anything — a dropdown hides three quarters of that. Height
28px, `--text-sm`, `--radius-sm`, 1px border; the selected segment takes
`--accent` fill and `--accent-ink` text.

It sits inline with search and export in the Logs toolbar and is used
nowhere else, so it never becomes page furniture.

## 20. Search

```
  ┌────────────────────────────────────┐
  │ Search sessions              Ctrl+K│
  └────────────────────────────────────┘
```

- Width 260px fixed; grows to fill on narrow layouts.
- Placeholder: `Search sessions` — not "Search for anything…".
- Shortcut hint: `Ctrl+K` on Windows, `⌘K` on macOS, chosen from
  `navigator.platform`. Rendered `--text-xs --text-faint` in a chip inside
  the field's right edge. **The shortcut is displayed but not bound** in
  this phase; the hint ships only when the binding does.
- Focus: 2px `--accent` outline, offset 2px. No glow.
- Filters live rows client-side across name, NIM, purpose, job type and job
  id. No spinner: it is an array filter on data already in the page.

## 21. Details

**Side sheet.** Right-anchored, 420px, full height, `--surface`,
`--radius-lg` on the left corners, the one shadow in the product, scrim
`rgba(20,22,26,.28)`.

A modal would centre and block; a dedicated page would lose the reader's
place in a long table. A sheet keeps the row visible behind it and closes
back to exactly where they were.

Content is a two-column definition list (`112px` labels, `--text-sm`),
grouped with `--space-5` between groups and no rules:

```
  Session                    ×

  IDENTITY
  Name          Dhana
  NIM           000000000

  WORKSTATION
  Station       LAB-03

  SESSION
  Purpose       DFTB Parameterization
  Job type      Simulation
  Job ID        258026
  Access        Langsung
  Start         18 Aug 2026, 08:41
  End           —
  Duration      02:34:17

  DESCRIPTION
  Development and validation of Slater-Koster
  parameters for Ag-organic systems.

  STATE
  Local         Stored on this workstation
  Sync          Local only
```

Description is full-width prose below its group label, not squeezed into
the value column. Absent values are `—` in `--text-faint`. Escape closes;
focus returns to the row that opened it.

## 22. Server page

Deliberately quieter than Overview. Configuration and state, no telemetry,
no accent panel.

```
  CENTRAL SERVER

  ┌──────────────────────────────────────────────────┐
  │ ● Local only                                     │
  │   Stored on this workstation. Nothing needs to   │
  │   be uploaded.                                   │
  │                                                  │
  │   Server          not configured                 │
  │   Privacy mode    local_only                     │
  │   Pending         —                              │
  │   Last success    —                              │
  │   Last error      —                              │
  └──────────────────────────────────────────────────┘
```

- One card, hairline border, no accent fill.
- The state line and its sentence come first; the key/value block is
  secondary.
- **`Pending` renders `—`, never `0`, when the state is Local only or
  Synchronization disabled.** A zero implies a queue exists and happens to
  be empty; an em dash says the question does not apply. This is the single
  most important rule on the page.
- Actions appear **only when they can do something**: `Sync now` only when
  sync is permitted and rows are pending; `Retry` only after a failure;
  `Test connection` only when a server is configured. Local only shows no
  buttons, because there is nothing for the user to fix.

## 23. Overview composition

### Desktop (≥1100px)

```
┌────────────┬──────────────────────────────────────────────────────────┐
│ LOGIX      │  YOU ARE USING WORKSTATION            ● Local only       │
│            │  LAB-03                                                  │
│ Overview   │  GPU-A100                                                    │
│ Logs       │ ─────────────────────────────────────────────────────────│
│ Server     │                                                          │
│ ───────    │  WORKSTATION HEALTH                    refreshed 2s ago  │
│ Settings   │  ┌────────────┬────────────┬────────────┬─────────────┐  │
│            │  │ CPU        │ MEMORY     │ GPU        │ STORAGE     │  │
│            │  │ 34%        │ 21.4 GB    │ 47%        │ 312 GB free │  │
│            │  │ 10 cores   │ of 64 GB   │ 8.2/24 GB  │ of 1.8 TB   │  │
│            │  │ ▂▂▂▂▂░░░░  │ ▂▂▂░░░░░░  │ ▂▂▂▂░░░░░  │ ▂▂▂▂▂▂▂░░░  │  │
│            │  └────────────┴────────────┴────────────┴─────────────┘  │
│            │                                                          │
│            │  ┃ CURRENT USAGE                          ● ACTIVE       │
│            │  ┃                                                       │
│            │  ┃ DFTB Parameterization              02:34:17           │
│            │  ┃ Dhana · 000000000                                     │
│            │  ┃ Simulation · Job 258026 · Langsung                    │
│            │  ┃                                                       │
│            │  ┃ started 08:41                        [ Details ]      │
│            │                                                          │
│            │  RECENT                                                  │
│            │  08:41   Dhana    DFTB Parameterization        2j 34m    │
│            │  05:12   Alya     Molecular Dynamics           1j 48m    │
│ ┌────────┐ │  ─────────────────────────────────────────────────────   │
│ │ LAB-03 │ │                                    [ View all logs ]     │
│ │ GPU-A100 │ │                                                          │
│ └────────┘ │                                                          │
└────────────┴──────────────────────────────────────────────────────────┘
```

**A note on order.** The health band sits above current usage, matching the
requested composition, but current usage is the only accented object on the
page — so the eye lands there first regardless of DOM order, matching the
product hierarchy where "is it in use / who / what / job" precede machine
health. Order and emphasis are set independently, on purpose.

### Narrow (<900px)

Sidebar becomes a horizontal strip of text links across the top; the
pinned workstation chip merges into the header block. Health drops to two
columns, then one below 560px. Current usage keeps its accent edge and
stacks the clock beneath the purpose. Recent keeps start / name / duration
and drops purpose below 560px. Nothing disappears entirely.

## 24. Logs composition

```
  LOGS

  ┌──────────────────────────┐  [Today][7 days][30 days][All]   [ Export ]
  │ Search sessions   Ctrl+K │  [ All states ▾ ]
  └──────────────────────────┘

  START   END     NAME    NIM        PURPOSE            JOB          DURATION  STATE
  ──────────────────────────────────────────────────────────────────────────────────
  08:41   —       Dhana   000000000  DFTB Parameter…    Simulation·  02:34:17  Active
                                                        258026
  05:12   07:00   Alya    000000001  Molecular Dyn…     —            1j 48m    Finished
  ──────────────────────────────────────────────────────────────────────────────────

  2 sessions · 4j 22m
```

Toolbar wraps to two rows below 900px (search full width, then controls).
Below 700px the table drops NIM and Job into Details only, keeping start,
name, purpose, duration and state.

## 25. Server composition

See §22. One card, one state sentence, one key/value block, conditional
actions. No second column, no telemetry, no chart.

## 26. Responsive behaviour

| Width | Behaviour |
|---|---|
| ≥1400px | Content max-width 1180px, centred. Layout does not keep growing. |
| 1100–1400 | Full layout as specified. |
| 900–1100 | Health to 2×2. Current usage stacks clock under purpose. |
| 560–900 | Sidebar → top strip. Table drops NIM and Job. Toolbar wraps. |
| <560px | Health single column. Recent shows start / name / duration. |

Never: a horizontally scrolling page. Wide content scrolls inside its own
container.

## 27. Accessibility

- Contrast: body text ≥ 7:1, secondary ≥ 4.5:1, non-text marks ≥ 3:1. Both
  themes.
- **State is never colour alone** — every indicator has words beside it
  (§13). This is a hard rule, not a preference.
- Focus: 2px `--accent` outline, 2px offset, visible on every interactive
  element including table rows. Never removed.
- Tab order follows visual order. The side sheet traps focus while open and
  restores it to the originating row on close.
- Table uses real `<table>` semantics with `<th scope="col">`; the health
  panel is a `<dl>`; nav is `<nav>` with `aria-current="page"`.
- Live-updating values (clock, telemetry) are **not** in an aria-live
  region — announcing a clock every second is hostile. Status changes are.
- Disabled controls: `--text-faint`, `cursor:default`, `aria-disabled`.
  Actions that cannot apply are hidden rather than disabled (§22).
- Reduced motion honoured (§16).

## 28. Component inventory

Deliberately small. Each earns its place by repeating or by clarifying
structure — the page is one HTML file and over-componentising it would just
be ceremony.

| Component | Repeats | Notes |
|---|---|---|
| `AppShell` | — | sidebar + main, the only grid |
| `NavList` | — | four items, selection state |
| `WorkstationContext` | 2 | header block and pinned chip |
| `StatusIndicator` | many | dot + words, one per state |
| `HealthPanel` | — | container |
| `HealthMetric` | 4 | label / value / secondary / bar |
| `CurrentUsagePanel` | — | the accented object |
| `SessionRow` | many | recent list and log table share a shape |
| `LogTable` | — | + `LogToolbar` (search, range, filters, export) |
| `SegmentedControl` | 1 | range only |
| `DetailsSheet` | — | + `DetailGroup` |
| `ServerCard` | — | |
| `EmptyState` | 6 | title + body |
| `Button` | many | default / primary / quiet |

## 29. Explicit anti-patterns

Not to be added, at any point, for any reason:

- Fake historical telemetry, sparklines, trend arrows, period deltas
- Gauges implying a target, score, grade or efficiency
- Productivity metrics, rankings, streaks, gamification
- AI panels, generated summaries, "insights", recommendations
- Marketing copy, hero sections, promotional cards, CTAs to nothing
- Charts with no real data behind them
- Avatars, follower counts, member lists, kanban boards
- Glassmorphism, gradients, glows, heavy shadows, 3D renders
- Every group boxed as a rounded floating card
- Icons without semantic purpose; an icon package of any kind
- Colour as the sole carrier of meaning
- A pending count on a device that does not sync
- React, Vue, Tailwind, Bootstrap, any framework
- A build step, a CDN, a runtime webfont, a chart library, Electron
