# Backend TODO backlog — collected during the UI pass (C0–C7)

The UI translation froze the API contract (brief §3.3). Where a design needed
data the backend doesn't expose, the UI derives a best-effort value (or omits
the element) and leaves a `// TODO(backend): …` marker. This file collects
those markers. Implement them in the separate **functionality phase** against
`server/main.py` + `logix/`, without reintroducing the findings in
`docs/AUDIT_AND_ROADMAP.md §3`.

| # | Need | Where the UI works around it | Current best-effort |
|---|------|------------------------------|---------------------|
| 1 | **Per-session access type** (physical / SSH / AnyDesk) on `/api/active`. The heartbeat DB already stores `session_type`, but `/api/active` and the in-memory `HEARTBEATS` cache drop it. | `frontend/src/tokens.ts` (`resolveAccessType`), Monitoring/Screens/Wall station cards | Defaults every station's `AccessTypeBadge` to **Fisik** (physical). |
| 2 | **Enrolled-station total** for the true "X / 12" occupancy denominator. `/api/active` only returns currently-online stations. | `frontend/src/views/Monitoring.tsx`, `WallMode.tsx` | Uses signed-in count as the denominator; occupancy meter/label reflect online stations only. |
| 3 | **`session_started_at`** per active session, for the "Dipakai 2j 14m" duration on station cards. | `frontend/src/views/Monitoring.tsx` | Shows the status word (Digunakan/Terkunci) + "Terlihat {last_seen}" instead of a running duration. |
| 4 | **Analytics date-range parameter** on `/api/analytics` (`today` / `7d` / `30d` / custom). | `frontend/src/views/Analytics.tsx` (`range` state) | The range segmented control is rendered but does not yet re-query. |
| 5 | **Day × hour occupancy matrix** for the Analytics heat map. `/api/analytics` only returns a 24-value `by_hour` aggregate. | `frontend/src/views/Analytics.tsx` (`HeatStrip`) | Renders a single-row per-hour heat strip from `by_hour`. |
| 6 | **Session start/end pairing** (+ access type) for the Analytics "Linimasa Sesi" timeline. | `frontend/src/views/Analytics.tsx` | Timeline section omitted (degrades gracefully). |
| 7 | **Period-over-period deltas** (e.g. "▲ 12% vs. bulan lalu") for KPI cards. No historical comparison is exposed. | `frontend/src/views/Analytics.tsx` (`KpiCard`) | KPI cards show current values only, no deltas. |
| 8 | **Distinct active-user count** vs. enrolled users for a "Pengguna Aktif 37 / 42" KPI. | `frontend/src/views/Analytics.tsx` | Shows "Workstation Terpakai" (`totals.workstations`) instead. |

All eight are additive, read-only data-shape extensions — none require changing
existing endpoints' semantics or the session lifecycle.
