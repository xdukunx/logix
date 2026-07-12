# LogiX — Claude Code Build Brief (from final designs)

**Purpose.** The 16 `.dc.html` design canvases are now the **visual source of truth**. This brief locks the design tokens, maps each design file to the repo files that must implement it, and sets the rules + sequence. Hand this file to Claude Code together with the design files.

**Setup before starting (do once):**
1. Copy all `*.dc.html` + `support.js` from the design zip into `docs/design/` in the repo (so Claude Code can open them directly). They are reference-only — never shipped/imported.
2. Work one phase per branch: `feat/ui-C0-tokens`, `feat/ui-C2-monitoring`, etc.
3. After each phase: `npm run build` (frontend) must pass; grep proofs where required.

---

## 0. THE KICKOFF PROMPT (paste this into Claude Code first)

```prompt
Read docs/design/LogiX_BUILD_BRIEF.md in full, then open docs/design/"LogiX Style Tile.dc.html" and docs/design/"LogiX Client Foundation.dc.html".

You are implementing a finished design system into an existing codebase. The .dc.html files in docs/design/ are the visual source of truth — match them closely (tokens, spacing, states, dark mode). Do NOT redesign; translate.

Two targets:
- Dashboard (web): frontend/ — React 19 + TypeScript + Vite + Astryx (@astryxdesign/*, StyleX) + Heroicons.
- Client (Windows): windows/ — PowerShell 5.1 + WPF, XAML built as interpolated strings.

Hard rules (from the brief §3): design tokens only (no raw hex in components — use the token layer you build in C0), zero prompt()/confirm()/alert() in final web code, keep the API contract & session semantics unchanged, keep all client colors/text config-driven and Segoe-UI-safe, bilingual ID-primary.

Start with phase C0 only (design tokens + dark mode + AccessTypeBadge), per the brief §4 and the detailed C0 spec in LogiX_UIUX_PRD.md. Show me the plan and the diff for C0, and stop. We proceed phase by phase; do not implement other phases until I say go.
```

> The detailed, per-phase implementation prompts already exist in `LogiX_UIUX_PRD.md` (§10, phases C0–C7) and `LogiX_PRD_D8_Client.md` (§5, phases C8.0–C8.5). This brief is the layer that binds them to the actual finished designs. For each phase: run its prompt from those PRDs **plus** "match docs/design/<the mapped file> exactly."

---

## 1. Token lockfile (extracted from the Style Tile — treat as canonical)

Implement these in C0 as the token layer (CSS variables + a TS map). Every component reads tokens, never raw hex.

**Brand & accent**
| Token | Light | Dark |
|---|---|---|
| `accent` (Blue 600) | `#2563EB` | `#2563EB` |
| accent-hover | `#1D4ED8` | `#1E40AF` |
| accent-weak (tint) | `#DBEAFE` | `#1E3A8A` |

**Surfaces & text**
| Token | Light | Dark |
|---|---|---|
| bg (app) | `#EEF1F5` | `#0B1120` |
| surface (card) | `#FFFFFF` | `#0F172A` |
| surface-elevated | `#FFFFFF` | `#1E293B` |
| border | `#DBE1EA` | `#1E293B` |
| text-primary | `#0F172A` | `#E2E8F0` |
| text-secondary | `#475569` | `#94A3B8` |
| text-muted | `#64748B` | `#94A3B8` |

**Semantic status** (this is the differentiator — use everywhere status/access appears)
| State | Light | Dark |
|---|---|---|
| in-use (green) | `#16A34A` | `#22C55E` |
| locked (amber) | `#D97706` | `#F59E0B` |
| idle (slate) | `#64748B` | `#94A3B8` |
| offline / stale (gray) | `#94A3B8` | `#6B7280` |
| alert / critical (red) | `#DC2626` | `#EF4444` |

**Client-only surfaces** (WPF): widget near-black `#0B0F19`; fullscreen popup dark navy surface. Accent = same `#2563EB` (brand verdict: *"Blue is the direction; everything else is a theme."* — `#741B47` maroon is retired as the accent, kept only as legacy comparison).

**Radius:** base `6px` (cards up to `12px` per Style Tile). **Type scale (px):** 10, 11, 12, 13, 14, 15, 16, 18, 20, 24, 26, 30, 34, 40. **Wordmark:** `LOGI` + accent `X`, weight 800, letter-spacing `0.2em`. **Fonts:** system stack only (`-apple-system, "Segoe UI", Roboto, …`); timer digits `Consolas`/ui-monospace. **Animations:** `lx-pulse` (in-use dot), `lx-shimmer` (skeleton) — respect `prefers-reduced-motion`.

**Access-type taxonomy (unify web + client):** exactly three — **Physical** (keyboard glyph), **SSH** (terminal `>_`), **AnyDesk** (remote glyph). Display pattern seen in designs: `SSH · since 09:14 · 2h 41m`.

---

## 2. Design file → repo target map

| Design file (`docs/design/…`) | Phase | Implement in |
|---|---|---|
| `LogiX Style Tile.dc.html` | **C0** | `frontend/src/theme.ts`, new `frontend/src/tokens.css` (or StyleX vars), `frontend/src/components/AccessTypeBadge.tsx`, skeleton/empty/error primitives |
| `LogiX App Shell & Login.dc.html` | **C1** | `frontend/src/App.tsx` (TopNav/SideNav, dark toggle, connectivity), `frontend/src/chrome/Login.tsx`, global loading/empty/error/toast |
| `LogiX Monitoring.dc.html` | **C2** | `frontend/src/views/Monitoring.tsx` (occupancy summary, station cards, visible actions) |
| `LogiX Action Modals.dc.html` | **C3** | new modals in `frontend/src/components/` (Rename, SendMessage, ScreenshotRequest, PowerAction, EmergencyBroadcast, Replies) + `SensitiveActionModal` template; remove all native dialogs |
| `LogiX Screens Wall.dc.html` + `LogiX Wall Mode.dc.html` | **C4** | `frontend/src/views/Screens.tsx` + new Wall/Kiosk route |
| `LogiX Devices.dc.html` | **C5** | `frontend/src/views/Devices.tsx`, `frontend/src/components/EnrollDialog.tsx`, device detail drawer |
| `LogiX Analytics.dc.html` | **C6** | `frontend/src/views/Analytics.tsx` (KPI row, heatmap, timeline, session log, audit, export) |
| `LogiX Settings.dc.html` | **C7** | `frontend/src/views/Settings.tsx` (sectioned config + branding preview) |
| `LogiX Client Foundation.dc.html` | **C8.0** | `windows/logbook_common.ps1` defaults, `windows/logbook_config.example.json`, `docs/config.schema.json`, `windows/preview_popup.ps1` harness |
| `LogiX Sign-in Popup.dc.html` | **C8.1** | popup XAML in `windows/logbook_common.ps1` (~L821–978) + fast-path persistence |
| `LogiX Timer Widget.dc.html` | **C8.2** | timer XAML (~L1047+) + `windows/logbook_timer.ps1` (SELESAI + 3 states) |
| `LogiX Notifications.dc.html` | **C8.3** | `Set-LogbookIncomingMessage` / message renderer (3 variants + 30s countdown + notice history) |
| `LogiX Lock & Setup.dc.html` | **C8.4** | lock overlay XAML + `windows/logbook_setup.ps1` wizard |
| `LogiX Copy Deck.dc.html` | **C8.5** | move all strings to `text.*` config namespace + add `locale` (id/en) |

---

## 3. Global rules (non-negotiable, every phase)

1. **Tokens only.** After C0, no raw hex/px in components — read the token layer (`var(--lx-*)` / StyleX vars / the TS token map). Follow `frontend/.claude/CLAUDE.md`; prefer Astryx `Stack/Grid/Card`.
2. **Zero `prompt()`/`confirm()`/`alert()`** in shipped web code. C3 must grep-prove none remain.
3. **API contract frozen** during UI work. Reuse existing endpoints/shapes in `frontend/src/types.ts` and `API_CONTRACT.md`. Where a design needs data the backend doesn't expose yet (session start time, enrolled count, analytics date range, day×hour matrix), derive best-effort from existing fields and leave a `// TODO(backend): …`. Collect these into a backlog list at the end of C6.
4. **Client config-driven.** All client colors/text stay in the config cascade (`branding.colors`, `text.*`); absent config must still render the current FTMM look. Escape every interpolated string via `ConvertTo-LogbookXmlText`.
5. **Fallback-safe fonts** on client: every `FontFamily` ends in `Segoe UI` / `Consolas`.
6. **Session semantics unchanged.** Lock/sleep = pause, not departure. A session ends only on SELESAI / OS shutdown-logoff / genuine idle-unlocked timeout.
7. **Privacy invariant.** No silent screenshots — the "Screen View Notice" must render whenever a capture happens; the two non-replyable notice variants must honor `allow_reply=$false`.
8. **Bilingual ID-primary.** Never hardcode English-only.
9. **Dark mode** everywhere the Style Tile shows a dark variant; default follows system + toggle.

---

## 4. Build sequence & acceptance

Run in order. Each phase = its PRD prompt (C0–C7 / C8.0–C8.5) **+** "match the mapped design file." Definition of done per phase:

- [ ] **C0** — tokens (light+dark) + dark-mode plumbing + `AccessTypeBadge` + skeleton/empty/error primitives. *Accept:* a demo renders all tokens in both modes; badge renders all 3 access types.
- [ ] **C1** — shell + login + global states match `App Shell & Login`. *Accept:* dark toggle works; connectivity 3-state; skeletons replace "Memuat data…".
- [ ] **C2** — Monitoring matches design; actions are visible buttons; modal handlers stubbed. *Accept:* occupancy summary correct from `/api/active`; no data-flow regressions.
- [ ] **C3** — all modals built + wired; **grep proof** `prompt(|confirm(|alert(` returns nothing in `frontend/src`. *Accept:* every prior native dialog now a styled modal hitting the same endpoint/payload.
- [ ] **C4** — Screens wall restyled (still manual) + Wall mode route. *Accept:* no auto screenshot capture; Wall mode read-only on `/api/active`.
- [ ] **C5** — Devices list + enroll (copyable code + 15-min countdown + revoke) + detail drawer. *Accept:* matches `API_CONTRACT.md` shapes.
- [ ] **C6** — Analytics: KPI + heatmap + timeline + session log + audit + prominent export. *Accept:* degrades gracefully; `TODO(backend)` list emitted.
- [ ] **C7** — Settings sectioned + live branding preview; PUT merges unknown keys. *Accept:* unexposed config keys preserved on save.
- [ ] **C8.0** — unified blue palette in client defaults + preview harness renders every surface.
- [ ] **C8.1** — sign-in popup: returning-user fast path + privacy panel; identity persisted locally only.
- [ ] **C8.2** — timer: visible `SELESAI` (two-step) + collapsed/default/expanded states.
- [ ] **C8.3** — 3 notification variants + real 30→0 DispatcherTimer countdown (centered overlay) + notice history.
- [ ] **C8.4** — lock overlay (pause, not shame) + 3-step enrollment wizard.
- [ ] **C8.5** — all strings in `text.*`; `locale` id/en resolves every key (test fails on missing string).

**If time-boxed, do:** C0 → C2+C3 (biggest quality jump) → C6 → then the rest; on client: C8.0 → C8.3 → C8.1 → rest.

**Post-UI backlog (functionality phase, separate):** the collected `TODO(backend)` items (session_started_at, enrolled count, analytics range param, day×hour matrix, session start/end pairing, unified access-type taxonomy) — implemented against `server/main.py` + `logix/`, without reintroducing the security findings in `docs/AUDIT_AND_ROADMAP.md §3`.
