# Handoff: LogiX v3 — "Clean Calibration" Admin Dashboard + Client Widget

## Overview
LogiX is a lab-access logbook system for a university computing lab (FTMM). It has two surfaces:
1. **Admin web dashboard** — monitor stations, review session/audit history, manage devices and policy (Indonesian-first UI).
2. **Windows client widget (WPF)** — a dark, always-on-top timer that runs on each lab workstation, tracking session time and letting admins message/lock/end sessions remotely.

This handoff covers the **v3 "Clean Calibration"** pass: a full visual reset away from an earlier "AI-generated-looking" direction (parchment backgrounds, serif italics, tinted badges, KPI-chart clutter) toward a restrained "quiet instrument" language — flat cards, dot/edge-only status color, mono tabular numerals for data, pill-shaped controls, and zero decorative chrome.

## About the Design Files
The files in this bundle are **design references built in HTML** — static/interactive prototypes showing intended look, structure, and behavior. They are NOT production code to lift as-is. The task is to **recreate these designs in the target codebase's real environment**:
- The **admin dashboard** should be rebuilt in whatever web stack the team already uses (React/Vue/etc. — ask if none exists yet; a React + Tailwind or CSS-modules stack is a reasonable default given the flat, inline-style-driven visual system shown here).
- The **client widget** (Sign-in Popup, Timer Pill & Strip) is a **WPF (.NET) desktop app** — every prototype explicitly notes "WPF: Border, Path, StackPanel, TextBlock." Recreate these as real WPF `UserControl`s using `Border` + `Path` (for the pill/strip's rounded/notched geometry), not as an embedded web view.

## Fidelity
**High-fidelity.** Exact hex colors, spacing, type scale, and copy (Indonesian) are final and should be reproduced pixel-for-pixel. Where a prototype shows only one language/data example, treat the *pattern* (column layout, field order, character limits implied by the layout) as the spec, and confirm real copy/data with the product owner.

## Files in this bundle

### Current — v3 Clean Calibration (build from these)
| File | Covers |
|---|---|
| `LogiX Style Tile v2.dc.html` | Design tokens: color ramps (light/dark), status colors, type scale, component kit (cards, buttons, chips, menus, toasts, modals), before/after comparison |
| `LogiX Monitoring v2.dc.html` | Admin: station grid (the dashboard's home/hero screen), light + dark, ⋯ menu, Cuplikan (screenshot) privacy modal, Emergency Broadcast modal |
| `LogiX Riwayat.dc.html` | Admin: History tab (merged Session Log + Audit Log, replaces the old "Analytics" page), inline summary stats, period/export presets |
| `LogiX Devices & Settings v2.dc.html` | Admin: Devices table + detail drawer + invite-code flow; Settings page incl. new "Idle auto-end" policy section |
| `LogiX Responsive.dc.html` | Admin: same screens adapted to TV wall-display, tablet, and phone breakpoints |
| `LogiX Timer Pill & Strip.dc.html` | Client: the always-on-top timer widget — all 8 core states + 3 admin-message reply states |
| `LogiX Sign-in Popup.dc.html` | Client: the session sign-in dialog — 4 states (default, destination dropdown, validation error, success handoff to the timer pill) |

### `legacy_reference/` — earlier iteration, NOT yet migrated to v3 tokens
These client-side screens were designed in an earlier pass (warm "editorial shell" — parchment background, serif headings) and have **not** been recalibrated to the v3 rules (flat #EDEFF2 canvas, sans-only, no warm tones). Treat them as behavior/content reference only; restyle to match the v3 token set in this bundle before building.
- `LogiX Notifications.dc.html` — client toast/notification patterns
- `LogiX Lock & Setup.dc.html` — client lock-screen + first-run setup
- `LogiX Client Foundation.dc.html` — original client design-system reference (superseded by Style Tile v2 for tokens)
- `LogiX Copy Deck.dc.html` — all Indonesian UI copy strings, text-only
- `LogiX Action Modals.dc.html` — admin confirmation modal patterns (superseded in part by modals in Monitoring v2)
- `LogiX App Shell & Login.dc.html` — admin login + shell/nav reference

---

## Design Tokens (v3 — canonical, see Style Tile v2 for visual swatches)

### Canvas rules (non-negotiable)
- Document/page canvas: flat `#EDEFF2`. No parchment/beige/cream/terracotta anywhere.
- No serif or italic type anywhere. `system-ui, "Segoe UI", sans-serif` only.
- No paper/card-shadow "editorial" framing on the canvas itself.

### Dashboard (light default, dark first-class)
```
bg                #F4F5F7  (dark: #0B0F16)
card              #FFFFFF  (dark: #111722)
border            1px #E6E9EF  (dark: #1E2836)
text              #14181F  (dark: #EDF1F7)
muted             #6A7382  (dark: #8A94A6)
accent            #2563EB — used ONLY for links, focus rings, and primary buttons
nav active state  dark pill: background #14181F, white text, radius 10 (NOT a border-left accent)
radius            card 16 · control 10 · button/chip/pagination 999 (full pill)
shadow (card)     0 1px 2px rgba(16,24,40,.04), 0 4px 16px rgba(16,24,40,.04) — very subtle, cards only
shadow (modal)    0 16px 48px rgba(16,24,40,.14) — modals are the one "elevated" surface
status color      dot 8px or edge/ring 3px ONLY — never a filled/tinted background:
                    aktif/active   #16A34A (dark #22C55E)
                    locked         #D97706 (dark #F59E0B)
                    idle           #64748B (dark #94A3B8)
                    offline        #9CA3AF (dark #6B7280) — card also gets dashed border, no actions
                    alert/critical #DC2626 (dark #EF4444)
type              system-ui · Display 28/650 · H2 20/600 · Body 14.5/1.6 · Caption 12
                  mono tabular (ui-monospace/Consolas) for ALL time/ID/duration values
spacing           8px grid · card padding 20–24px · prefer whitespace over dividing lines
```

### Client widget (WPF, always dark)
```
surface   #0B1017
elevated  #0E1626 (pill/strip/expand-card background)
hairline  #223451
text      #EEF3FB
muted     #93A1B8
font      Segoe UI (UI text) + Consolas (mono: clock, IDs) — no web fonts
radius    fully rounded / pill (999, or half-height) — mood ref: iOS Live Activity / Dynamic Island
```

### Guard rails (apply everywhere)
No: decorative gradients · glow/pulse on static elements · tinted/filled status badges · trend arrows (▲/▼ %) · nested "card in a card" · emoji · more than 2 font weights per card. Hierarchy comes from size + spacing, not chrome. One hero element per surface (e.g., the station grid IS the Monitoring page — no KPI cards or occupancy chart above it).

---

## Screens

### 1. Monitoring (`LogiX Monitoring v2.dc.html`) — admin home
**Purpose:** at-a-glance view of all lab stations; primary daily-use screen for admins.
**Layout:** persistent left sidebar (216px, nav pills, active = dark pill) + main content area. Main: header row (title + inline summary sentence "6 dari 12 stasiun dipakai · diperbarui 8 dtk lalu" + right-aligned Emergency Broadcast pill button) then a 4-column card grid (`grid-template-columns: repeat(4, 1fr)`, 14px gap).
**Station card anatomy (fixed, reused everywhere):**
- 8px status dot, top-left, inline with title
- Title line: `WS-{id} · {spec}` in mono, 13.5px/600, `white-space: nowrap`
- `⋯` menu trigger, right-aligned same row
- Second line (13px, muted, 18px left-indent to align under title text not the dot): `{user} · {access type} · {mono duration}` — or for locked: `Dikunci admin · {mono time}` — or for offline: `Offline sejak {mono timestamp}` with no menu, dashed border, all-muted color, no interactive affordance.
**⋯ menu:** 168px popover, white, radius 12, items: Pesan (Message) / Kunci (Lock) / Cuplikan layar (Screenshot) / divider / Daya (Power, red text).
**Modals:** 
- Cuplikan confirm — must include a visible (not hidden-behind-a-link) privacy notice: "pengguna selalu diberi tahu" (user is always notified), left border accent #2563EB.
- Emergency Broadcast — top border accent #DC2626, textarea-style message preview box, required checkbox acknowledgement before the red "Kirim broadcast" button.

### 2. Riwayat / History (`LogiX Riwayat.dc.html`) — replaces "Analytics"
**Purpose:** session + audit history, exports. Explicitly has **zero charts** — this was a deliberate pruning decision from the previous Analytics page.
**Layout:** header shows 3 summary numbers **inline in a sentence**, not as KPI cards: "148 j total · 96 sesi · 31 pengguna" (numbers in mono, labels muted). Right side: period preset pill dropdown (Hari ini / 7 hari / Bulan ini / Semester ini / Custom) and Unduh (Export) pill dropdown (Excel / CSV / rekap per-pengguna).
**Sub-tabs:** Log Sesi (Session Log) and Log Audit (Audit Log), rendered as pill toggle (active = dark pill, matches nav pattern).
- Log Sesi table columns: Waktu, Perangkat, Pengguna, Tipe akses, Tujuan, Durasi (mono, right-aligned).
- Log Audit table columns: Waktu, Aktor, Target, Aksi, Status (dot + label), Alasan.
Both: light hairline row dividers (no zebra striping), pagination as pill number buttons, filter chips (search + 2 dropdowns) above the table.

### 3. Devices & Settings (`LogiX Devices & Settings v2.dc.html`)
**Devices:** flat table (ID, Spesifikasi, Kategori, Sinkronisasi, Versi client) + right-side detail drawer (330px) on row select. **No sparkline** (explicitly removed — a 7-day sync sparkline column existed in an earlier iteration and was cut; sync status is now just a dot + "X ago" timestamp). Drawer includes the one-time, 15-minute-expiry invite-code flow: monospace code in a dashed box, countdown timer text, "Buat kode baru" / "Hapus" pill actions.
**Settings:** left nav (5 sections: Branding, Tipe Akses & Tujuan, Perangkat, Laporan, Privasi) + content pane. The **Perangkat** section is the one with new content: **Idle auto-end** policy — per-category (GPU/CPU/Umum) toggle + threshold (mono, e.g. "2 jam") + fixed copy "notifikasi 5 menit sebelum sesi ditutup otomatis." Toggle switches are pill-shaped, accent-blue when on. Umum (general) category has the toggle off by default, with muted "nonaktif" copy. Includes a callout box clarifying idle is measured from input **and** compute load, not input alone (so long-running jobs like DFT/training don't get killed).

### 4. Responsive (`LogiX Responsive.dc.html`)
Documents 4 breakpoints for the admin dashboard using the same Monitoring card anatomy at every size:
- **≥1280px (desktop):** left sidebar nav, 4-col grid — this is the default shown in Monitoring v2.
- **768–1279px (tablet):** sidebar collapses into a top bar with nav rendered as inline pills + an icon-only Emergency button; grid drops to 2 columns.
- **≤767px (phone):** cards become single-column list rows (identity shortened to just the station ID); bottom tab bar, 4 items, ≥44px touch targets; the ⋯ menu becomes a bottom sheet (same 4 actions).
- **TV / wall display (`/wall` route):** dark, read-only, no nav/menus at all — just lab name, live counter, clock, and a dense station grid with larger type (21px mono IDs) meant to be read from ~4 meters away. User names can be hidden via Settings › Privasi for this mode.

### 5. Timer Pill & Strip (`LogiX Timer Pill & Strip.dc.html`) — client widget, WPF
Two postures of one widget, always-on-top, draggable, snapped to the top edge of the screen.
**Pill (default):** 150×32px capsule, `opacity: .70` at rest, dot (8px) + elapsed time (Consolas 13, tabular). Drag anywhere along the top edge.
- Hover → expands to a 240px rounded card (radius 22): name, tujuan (purpose), perangkat (device+access type), admin message if present, and a "SELESAI" (Done) pill button. Auto-collapses 5s after cursor leaves.
- SELESAI is a **two-step / armed** control: first click arms it (button turns red, "Tekan lagi untuk selesai" / press again to finish), auto-disarms after 3s if not confirmed.
- Incoming message: dot turns blue + numeric badge. **Does not auto-expand** — user must hover to read.
- Message reply flow (hover while a message is pending): quick-reply pills ("OK", "Butuh 10 mnt") plus a "Balas…" free-text field, Enter to send; confirmation state shows a checkmark + "Terkirim ke admin," then auto-collapses. The reply appears back on the admin's Monitoring station card.
**Strip (focus mode):** double-click the pill to switch — remembered per session. Renders as a 3px full-width line along the top edge, colored by status. Optional config: auto-switch to strip when the OS reports a fullscreen app.
- **Sliver peek:** dwelling the cursor at the top edge for 300ms drops a small 24px pill-shaped sliver showing elapsed time + station ID; click it to expand the full card. (Fitts's-law rationale: screen edge = infinite-width target.)
- Incoming message in strip mode: strip turns blue and the sliver auto-peeks for 4s then retracts — the **only** motion permitted on a background event.
**Countdown/emergency overlay:** escapes BOTH postures into a centered, dimmed-backdrop overlay (radius 22, 360px wide) — used for idle auto-end warnings and admin emergency broadcasts. Buttons must not wrap ("Perpanjang sesi" / "Selesai sekarang", `white-space: nowrap`).
**Global rules:** `reduce_motion` OS setting disables all animation (states snap instead of transitioning). Status colors: green=active, blue=notice, amber=warning, red=critical.

### 6. Sign-in Popup (`LogiX Sign-in Popup.dc.html`) — client widget, WPF
Appears when a user sits down at a station for **physical access only** — SSH/AnyDesk sessions are logged automatically from remote-login credentials with no popup.
**Layout:** 320px dark dialog (radius 22), centered. Fields: NIM/Username (mono input), Tujuan (Destination — dropdown sourced from Settings › Tipe Akses & Tujuan, includes a free-text "Lainnya" escape hatch), access type shown read-only (auto-detected, not user-chosen) with a dot indicator. Primary "Mulai sesi" (Start session) pill button, full-width. A fixed two-line privacy disclosure is always visible (not hidden behind a link): "Sesi mencatat waktu, durasi & tujuan. Tanpa perekaman layar." (Session logs time, duration & purpose. No screen recording.)
**Validation:** unrecognized NIM shows an inline red dot + one-sentence fix instruction under the field; submit button disables (does not shake/error-dialog).
**Success:** popup closes, desktop appears, the Pill widget starts at `00:00`, and a one-time toast points at the pill's location for 4s then disappears.

---

## Interactions & Behavior summary
- All hover/expand/collapse timings are specified per-component above (5s pill auto-collapse, 3s SELESAI disarm, 300ms sliver dwell, 4s message auto-peek/toast).
- `reduce_motion`: disable every transition/animation client-wide; states snap.
- Two-step destructive-ish confirm pattern (SELESAI) should be implemented as a real timeout-based state machine (armed → confirm-or-timeout), not a CSS-only trick.
- Emergency Broadcast and idle-auto-end countdown share the same overlay component (see Timer state 8).

## State Management (client widget)
Minimum states needed: `idle/active/locked/offline/alert` (status), `collapsed/hovered/armed` (pill), `pill/strip` (posture, persisted across sessions), `sliver-hidden/sliver-peeking` (strip), `message: none/unread/replying/sent`, `overlay: none/countdown/broadcast`. Posture preference and reduce-motion should read from OS/user settings at launch.

## Screenshots
Full-page screenshots of each current v3 file are in `screenshots/` (same filenames, one per design file above) for quick visual reference alongside the HTML.

## Assets
No external images or icon sets — all icons are hand-drawn inline SVG (line-style, stroke-based, no filled icon fonts, no emoji). No fonts to license: system-ui/Segoe UI + Consolas are OS-provided.

## Open items / things to confirm with the product owner
1. `legacy_reference/` client screens (Notifications, Lock & Setup) still use the old warm/serif visual language — need a v3 restyle pass before building.
2. Exact wording for all Riwayat/Devices/Settings copy should be cross-checked against `LogiX Copy Deck.dc.html` (text-only source of truth for Indonesian strings).
3. Web framework for the admin dashboard was not specified in this project — confirm with the engineering team before scaffolding.
