# Audit — offline-first client

Phase 0 of the offline-first client work. Written before any behaviour changed,
against `671aaab` (branch point of `feat/logix-offline-client`).

The short version: **the offline-first data architecture the brief asks for
already exists and works.** The gaps are in what the user can *see* — recovery,
sync visibility, history — plus one genuine network dependency on the sign-in
path and one wasteful status-file write. Four of the brief's assumptions do not
match what is in the repository; they are listed at the end, because they change
what should be built.

---

## 1. Current architecture

```
  ┌─────────────────────── Windows device ────────────────────────┐
  │                                                                │
  │   logbook_monitor.ps1        the only resident process         │
  │     · session/lock watch      (scheduled task, non-elevated)   │
  │     · periodic sync retry (120s)                               │
  │     · heartbeat                                                │
  │        │ spawns                                                │
  │        ▼                                                       │
  │   logbook_popup.ps1  ──────►  logbook_timer.ps1                │
  │     sign-in (WPF)     spawns   widget + clock (WPF)            │
  │        │                          │                            │
  │        │ Invoke-WSLLogbook -Async │ Write-LogbookBarStatus (1s) │
  │        ▼                          ▼                            │
  │   ┌─────────────────┐      bar_status.json ──► YASB            │
  │   │ log_physical.py │                                          │
  │   └────────┬────────┘                                          │
  │            ▼                                                   │
  │      SQLite (WAL)  ◄── source of truth                         │
  │       physical_log · event_uid · synced                        │
  │            │                                                   │
  │            ├──► session.json      (client session state)       │
  │            ├──► sync_state.json   (last attempt, sidecar)      │
  │            └──► report_server.py  (localhost report UI)        │
  │                                                                │
  └────────────────────────────┬───────────────────────────────────┘
                               │ optional, gated, asynchronous
                               ▼
                     FastAPI server  ·  POST /api/log
```

The dependency arrow already points the way the brief wants: UI → local engine →
SQLite → sync queue → server. Nothing on the START or STOP path waits on the
network, with one exception documented as **F3** below.

## 2. START flow (measured, not assumed)

```
click START
  → popup validates fields, writes session.json          local
  → Invoke-WSLLogbook -Async  ─┐ detached python, UI does not wait
  → Start-LogbookTimer         │  → INSERT into physical_log (event_uid)
  → popup closes               │  → sync attempted only if policy allows
  → widget appears            ─┘
```

Blocking cost on the UI thread, cold: **~184–208 ms** (merged in `89aff59`).
The SQLite write is ~6.6 ms of that and happens in the detached process, so it
is not on the click path at all.

## 3. STOP flow

```
hold SELESAI (ring fills)
  → Complete-LogbookSelesai (deferred 650 ms so the ring is seen to finish)
  → session_ending.flag → logbook_end.ps1
  → UPDATE physical_log (end time, duration)              local
  → session.json cleared, Clear-LogbookBarStatus
  → sync attempted later, by the monitor's 120 s retry
```

## 4. Sync flow

```
log_physical.py --sync
  → paths.privacy_mode() must be 'admin_full_sync'   ← hard gate
  → SELECT rows WHERE synced = 0
  → POST /api/log  (event_uid = idempotency key)
  → 2xx  → UPDATE synced = 1
  → 4xx  → fail fast, row stays unsynced
  → 5xx  → retry with backoff
  → _record_sync_attempt() → sync_state.json
```

Server-side idempotency is a partial UNIQUE index on `event_uid`, so a duplicate
POST is absorbed rather than duplicated. Proven by the 13 live-server tests in
`tests/test_sync_integration.py` (lost response, crash-before-ack, 300-row race).

## 5. Offline behaviour today

| Scenario | Today |
|---|---|
| START with no network | works, fully local |
| STOP with no network | works, fully local |
| App restart mid-session | session.json + SQLite recover it |
| Windows restart | monitor task restarts, session recovered |
| Network lost mid-session | nothing happens; sync is not on this path |
| Sync fails | row stays `synced = 0`, retried every 120 s, never destroyed |

## 6. Failure modes found

**F1 — Offline-first is already true at the data layer.** Phase 2 of the brief
is largely a verification exercise, not a build. Do not rewrite the SQLite
layer.

**F2 — Sync is off by default, deliberately.** `paths.privacy_mode()` defaults
to `local_only`, and `sync_unsynced_logs()` refuses anything that is not
`admin_full_sync`. On a default install, no session data ever leaves the device.
`sync_status()` already models this correctly as
`connection_state ∈ {disabled, blocked, pending, connected}`.

Consequence for Phases 4 and 7: a UI that renders "3 pending · [Sync now]" on a
`local_only` device would be **wrong**. Those rows are not pending — they are
finished. The device is not degraded, it is configured. The status indicator
must distinguish *cannot reach server* from *not permitted to send*, or it will
describe a working private-by-default product as broken.

**F3 — One real network dependency on the UI path.**
`logbook_popup.ps1:26` calls `Get-LogbookConfig -MaxCacheAgeSeconds 300`, which
reaches `Invoke-RestMethod` at `logbook_common.ps1:1466` **before the sign-in
window renders**. Bounded to 1 s (cache present) or 2 s (no cache), and skipped
entirely when no `LOGIX_SERVER_URL` is set — so device-only installs never pay
it. But on a paired device behind a black-holed route or captive portal, sign-in
is delayed by a network call it does not need. This is the single clearest
violation of "the UI must not depend on network availability".

**F4 — `bar_status.json` is rewritten every second.** Full JSON serialise, temp
file, `Move-Item` — 3600 writes/hour per active session
(`logbook_timer.ps1:1175`, in the 1 s tick). It is written that often because
the payload carries *rendered strings* (`text: "03:18"`, `alt`, `tooltip`)
rather than state. A payload carrying `started_at` + `state` lets YASB compute
elapsed time itself, which removes the reason to write on every tick. One change
addresses both of the brief's Phase 8 concerns.

**F5 — No recovery UI, and one path silently ends sessions.**
The recovery *backend* exists and is proven
(`repair_active_session_from_windows_state` inserts a missing row;
`Close-StaleLogbookSessionIfAny`; `Close-OverAgeLogbookSessionIfAny`). But there
is no card that asks the user. `Close-OverAgeLogbookSessionIfAny` closes a
session past an upper bound without asking, which conflicts with the brief's
"never silently discard an active session". Phase 3's real work is UI plus a
decision about that auto-close, not new backend.

## 7. Disposition

**Do not touch** — SQLite schema, `event_uid` and idempotency, the async START
dispatch and warm-up, the sync retry/backoff, DB isolation via
`PRAGMA database_list`, the WMI-avoidance work in `Stop-LogbookTimers`.

**Reuse as-is** — `sync_status()` (it already returns exactly what a status
indicator needs), `Get-LogbookSessionState`, the recovery functions,
`report_server.py` for history, the atomic temp+rename write helper.

**Refactor** — the popup's config fetch (F3: render from cache, refresh in
background), the `bar_status.json` payload and write cadence (F4), and the
absence of recovery/sync/history surfaces (F5).

## 8. Where the brief and the repository disagree

1. **Sync is not the default path** (F2). The proposed state machine's
   `SYNC_PENDING → SYNCING → SYNCED` is unreachable on a stock install. Mapping:
   the brief's `SYNC_PENDING` splits into *blocked by policy* (terminal, normal)
   and *pending delivery* (transient).
2. **The proposed main window drops identity.** Logix signs a person in to a
   *shared lab workstation* — name, NIM, purpose. The brief's
   "What are you working on? [____]" is a single-user time tracker. Adopting the
   visual direction is right; dropping identity capture would change what the
   product is. Proceeding on the assumption that identity stays and the visual
   direction is adopted around it.
3. **`Ctrl+Shift+S` for start/stop is unsafe here** (Phase 9). Ending a lab
   session is the hold-to-confirm interaction precisely so it cannot happen by
   accident; a global hotkey that ends a session contradicts that. Open/focus is
   fine.
4. **Phase 2's guarantees are already met** (F1), so the effort belongs in
   Phases 3, 4, 6, 7 and 8.

## 9. Baseline at branch point

`pytest` **403 passed** (re-run on this branch, not inherited).
PowerShell config 288, interaction 58 — as merged at `671aaab`.
