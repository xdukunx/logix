# Offline client — product & UX contract

Phase 1. Contract only: nothing here is implemented yet. Written against
`ab4ed1e` on `feat/logix-offline-client`, on top of the findings in
[AUDIT_OFFLINE_CLIENT.md](AUDIT_OFFLINE_CLIENT.md).

Every rule below is grounded in code that exists today. Where a rule requires
something the code cannot currently express, that is called out explicitly as an
**implementation gap** rather than assumed to work.

---

## 1. Product identity

Logix signs **a person** in to **a shared lab workstation**. It is not a
personal time tracker, and this phase does not turn it into one.

What is captured today, at sign-in, into `session.json`
([logbook_popup.ps1:399](../windows/logbook_popup.ps1)):

| Field | Meaning | Source |
|---|---|---|
| `nama` | person's name | typed, remembered |
| `nim` | student/user ID | typed, remembered |
| `tujuan` | purpose of this visit | typed, remembered |
| `keterangan` | free-text notes | typed, remembered |
| `session_type` | `Langsung` or `AnyDesk` | chosen |
| `anydesk_detected` | remote-access flag | derived |
| `username`, `windows_user`, `hostname` | workstation identity | automatic |
| `session_id` | `win-<user>-<epoch>-<8hex>` | generated |
| `start_time` | ISO-8601 | generated |

Two facts drive the whole UX decision:

1. **Identity is already remembered between sessions.** The popup writes
   `last_profile.json` with `nama`/`nim`/`tujuan`/`keterangan` so a returning
   user does not retype it.
2. **`tujuan` already *is* "what are you working on".** The field the original
   brief wanted to introduce exists in the schema and is the one value that
   genuinely varies from session to session.

**Therefore:** identity is *persistent context*, not a per-session form. The new
UI shows identity as a confirmable line and gives `tujuan` the prominence the
brief wanted, without removing anything.

```
  identity  →  a line you confirm      (nama · nim · station)   [Ganti]
  purpose   →  the one field you fill  (tujuan)
  notes     →  optional, collapsed     (keterangan)
  access    →  Langsung / AnyDesk      (pre-selected, auto-detected)
```

First-time or changed user gets the full form. Returning user gets one field and
a button. Same data, far less typing.

## 2. State machine

The original brief listed one machine mixing `ACTIVE` with `SYNC_PENDING`. That
conflates two things that vary independently: a session can be ACTIVE while
synced, ACTIVE while the server is down, or IDLE with rows still waiting.
Modelling them as one machine produces states that cannot occur and misses ones
that do.

**Two orthogonal axes.**

### 2a. Session axis — authoritative, local, never gated by network

```
                    ┌──────────────────────────────┐
                    ▼                              │
   ┌──────┐    ┌──────────┐    ┌────────┐    ┌──────────┐
   │ IDLE │───►│ STARTING │───►│ ACTIVE │───►│ STOPPING │
   └──────┘    └──────────┘    └────┬───┘    └──────────┘
       ▲                            │ ▲
       │                       lock │ │ unlock
       │                            ▼ │
       │                        ┌────────┐
       │                        │ PAUSED │   display only — the session
       │                        └────────┘   continues, the clock continues
       │
       │  launch with an active session found
       │            ┌────────────────────┐
       └────────────│ RECOVERY_REQUIRED  │
                    └────────────────────┘
                         │           │
                    resume│           │end
                         ▼           ▼
                     ACTIVE        STOPPING

   any state ──► ERROR (local state unreadable; never entered for network)
```

`PAUSED` is a presentation substate, not a lifecycle change. A lock or
sleep/resume cycle is **not** a session boundary — that is an existing,
deliberate product decision recorded in `logbook_common.ps1`: stepping away for
coffee must not split one lab visit into two logbook rows.

Maps onto the existing `Get-LogbookSessionState`
(`IDLE`/`STARTING`/`RUNNING`/`PAUSED`/`ENDING`/`ERROR`). `RUNNING` → `ACTIVE`,
`ENDING` → `STOPPING`. `RECOVERY_REQUIRED` is the one genuinely new state.

### 2b. Sync axis — advisory, per device, never blocks the session axis

```
   LOCAL_ONLY          no server paired. Terminal and normal.
                       Nothing is waiting. Nothing is wrong.

   SYNC_BLOCKED        server paired, but policy forbids sending.
                       Terminal until policy changes.

   SYNC_PENDING ⇄ SYNCING ──► SYNCED
        ▲                        │
        └────────────────────────┘  new rows

   SERVER_UNAVAILABLE  allowed, but the server cannot be reached.
   SYNC_ERROR          allowed, reached, and it failed.
```

Mapping from the existing `sync_status().connection_state`
([log_physical.py:492](../logix/log_physical.py)):

| existing | + condition | user-facing |
|---|---|---|
| `disabled` | — | `LOCAL_ONLY` |
| `blocked` | — | `SYNC_BLOCKED` |
| `pending` | — | `SYNC_PENDING` |
| `connected` | `pending_count == 0` | `SYNCED` |
| `connected` | `pending_count > 0` | `SYNC_PENDING` |
| — | last attempt failed, unreachable | `SERVER_UNAVAILABLE` |
| — | last attempt failed, reached | `SYNC_ERROR` |

> **Implementation gap.** The last two rows are **not derivable today**.
> `_record_sync_attempt(con, ok, detail)` stores a free-text `detail`, so
> "connection refused" and "HTTP 500" are indistinguishable to a UI. Phase 2
> must record a **failure class** (`unreachable` | `rejected` | `server_error`)
> alongside the text. Until it does, both collapse to `SYNC_ERROR`, and the UI
> must not claim to know which.

## 3. Local-first guarantees

Confirmed against the code, not assumed:

```
START:  click → session.json → detached python → SQLite INSERT → ACTIVE
STOP:   hold  → session_ending.flag → SQLite UPDATE → IDLE
```

Network is not on either path. `Invoke-WSLLogbook -Async` detaches, and sync is
a separate later step gated by policy.

**Guarantee.** None of the following may ever wait on, or fail because of, the
network:

- START · STOP · session recovery · viewing current session
- viewing local history · viewing local state · the timer/clock

**One current violation.** [logbook_popup.ps1:26](../windows/logbook_popup.ps1)
calls `Get-LogbookConfig -MaxCacheAgeSeconds 300`, reaching `Invoke-RestMethod`
(1 s with cache, 2 s without) **before the sign-in window renders**. Skipped
entirely when no `LOGIX_SERVER_URL` is set.

Required sequence after Phase 2:

```
  launch → render from cached/local config immediately
         → refresh from server in the background
         → update branding/labels in place if the reply differs
```

The network enriches the UI; it does not gate it. Before/after numbers required.

## 4. Sync semantics

- The local commit always happens **before** any sync attempt.
- Sync failure never modifies, deletes, or invalidates local data. Rows stay
  `synced = 0` and are retried by the monitor every 120 s.
- `event_uid` is the idempotency key; the server holds a partial UNIQUE index on
  it, so a duplicate POST is absorbed. Proven by `tests/test_sync_integration.py`.
- 4xx fails fast; 5xx retries with backoff. Unchanged.
- Sync is never triggered by, and never blocks, a UI interaction.

## 5. Privacy semantics

`paths.privacy_mode()` defaults to `local_only`, and `sync_unsynced_logs()`
refuses anything that is not `admin_full_sync`. **On a stock install no session
data leaves the device, by design.**

Consequences that bind the UI:

1. `LOCAL_ONLY` is a **success state**. It gets no warning colour, no badge, no
   call to action. Copy: *"Tersimpan di workstation ini."*
2. The UI must **never** show a pending count on a `LOCAL_ONLY` or
   `SYNC_BLOCKED` device. Those rows are finished, not queued.
3. `SYNC_BLOCKED` describes policy, not failure: *"Sinkronisasi dinonaktifkan
   oleh kebijakan."* No retry button — there is nothing for the user to fix.
4. Identity (`nama`, `nim`) is local unless `admin_full_sync` is set. No UI
   surface may imply otherwise.

## 6. Recovery semantics

Three situations exist today and are currently handled by two functions that
both call `Close-ActiveLogbookSession -Reason 'AUTO_CLOSE'`. Important
correction to the Phase 0 audit: **neither discards data** — both close the
session and write the row. What is missing is that the user is never *told*.

| # | Condition | Today | Contract |
|---|---|---|---|
| 1 | `start_time` predates last boot (`Close-StaleLogbookSessionIfAny`) | auto-close | **keep auto-close** + notify |
| 2 | age ≥ `LOGIX_MAX_SESSION_HOURS` (default 8 h), on resume/unlock (`Close-OverAgeLogbookSessionIfAny`) | auto-close | **ask first**, auto-close as fallback |
| 3 | active session, app restarted, no reboot, under cap | resumes silently | **ask** — `RECOVERY_REQUIRED` |

**Rule 1 — reboot.** Keep closing automatically. The machine restarted; the
person is gone, and resuming would produce a duration spanning a reboot. There
is no one present to ask. But the closure must be **surfaced at the next
sign-in** as a dismissible notice: *"Sesi sebelumnya ditutup otomatis (komputer
restart). 07:42 → 08:15, tercatat."* Never silent.

**Rule 2 — over-age.** Show the recovery card. If nobody answers within **60 s**,
fall back to the existing auto-close. This keeps the safety property for an
unattended machine while giving a present user the choice. The cap exists for a
real reason — a machine locked overnight resuming at `25:00:00` — and is not
removed.

**Rule 3 — restart.** Show the recovery card. No timeout; the session stays
`RECOVERY_REQUIRED` until answered.

**Invariants for all three.**

- `Resume` preserves `session_id`, `start_time`, and all identity fields. It
  creates no new row and no new event.
- `End` closes the **existing** session with its original identity.
- Neither ever creates a second session for the same visit.
- Every automatic closure records its reason and is visible to the user
  afterwards.

> **Implementation gap.** What end time `AUTO_CLOSE` records is unverified. If
> it records "now", a machine locked overnight produces a ~25-hour row rather
> than one clamped to the cap or to last known activity. Phase 2 must check this
> before relying on rule 2, and clamp if needed.

## 7. YASB state contract

YASB is a **consumer**. It renders state; it never owns it. Logix is fully
functional with YASB absent, and `bar_status.json` stays — a file is already
atomic here, already cheap, and no measurement justifies a named pipe.

The payload changes from rendered text to state:

```json
{
  "schema_version": 1,
  "state": "active",
  "session_id": "win-...",
  "started_at": "2026-08-15T07:42:11.4210000+07:00",
  "title": "DFTB Parameterization",
  "station": "LAB-03",
  "sync_state": "local_only",
  "pending_events": 0,
  "updated_at": "2026-08-15T07:42:11.4210000+07:00"
}
```

`state ∈ {none, starting, active, paused, stopping, recovery_required, error}`
· `sync_state` = the seven names from §2b, lowercased.

**Privacy rule — binding.** `nim` **must never** appear in this file, and `nama`
must not by default. This file is read and rendered by a third-party process
onto a shared workstation's taskbar, where anyone walking past sees it. The
current payload already carries only the station label, and that is correct.
`station` and `title` stay; identity does not. If a future option surfaces
`nama`, it is opt-in and off by default.

**Write triggers** — no per-second write:

- session start · stop · recovery resolved
- `state` change (including lock → `paused`)
- `sync_state` or `pending_events` change
- `title`/context change
- a **liveness beacon every 60 s**, and nothing else

The beacon is the one justified periodic write. Without it, a killed widget
leaves the bar showing `active` forever, and `Clear-LogbookBarStatus` cannot run
from a process that was killed. 60 s is 60× fewer writes than today while
preserving the staleness signal. Consumers treat `now - updated_at > 150 s` as
`unknown`, not as `active`.

**Migration.** `logix_yasb.ps1` reads this file today. Phase 2 keeps the legacy
`text`/`alt`/`tooltip` keys alongside the new ones for one release so an
un-updated YASB config keeps working, and `schema_version` lets a consumer tell
which it is holding.

**Quick actions** stay as they are: the existing one-shot `bar_action` file the
widget consumes and deletes. No new IPC. A bar may request *open* or *posture*;
a bar may **not** start or end a session — see §10.

## 8. Main UI states

Six, matching §2a × §2b. Wireframes in §13.

| State | Primary action |
|---|---|
| A · No active session | `MULAI SESI` |
| B · Active session | `SELESAI` (hold to confirm) |
| C · Recovery required | `Lanjutkan` / `Akhiri` |
| D · Local-only | none — informational |
| E · Sync pending / blocked | `Sinkronkan` / none |
| F · Sync error | `Coba lagi` |

D, E and F are **not separate screens**. They are the status line on A and B.
Only C takes over the window, because it is a question that must be answered.

## 9. Identity / workstation UX

```
 ┌───────────────────────────────────────────────┐
 │ LOGIX                    LAB-03    ● Tersimpan│   station is always visible,
 ├───────────────────────────────────────────────┤   in the chrome, not a field
 │                                               │
 │  Dhana · 000000000                    [Ganti] │   identity: confirm, don't retype
 │                                               │
 │  Sedang mengerjakan                           │
 │  ┌─────────────────────────────────────────┐  │   tujuan: the one field that
 │  │ DFTB Parameterization                   │  │   actually varies
 │  └─────────────────────────────────────────┘  │
 │                                               │
 │  Akses  ● Langsung   ○ AnyDesk                │   pre-selected, auto-detected
 │  + Keterangan                                 │   collapsed until needed
 │                                               │
 │            [   MULAI SESI   ]                 │
 └───────────────────────────────────────────────┘
```

- **Station** lives in the window chrome. It is a property of the machine, never
  typed, derived as today from the device display name with `COMPUTERNAME` as
  fallback ([logbook_timer.ps1:1246](../windows/logbook_timer.ps1)).
- **Identity** is one confirmable line, restored from `last_profile.json`.
  `[Ganti]` expands the full form.
- **First run**, or after `[Ganti]`, shows every field exactly as today. Nothing
  is removed — only reordered by how often it changes.
- **`keterangan`** is collapsed by default; it is optional and usually empty.

## 10. Performance principles

- **Baseline is `~184–208 ms` cold** for START (merged in `89aff59`). It must
  not regress. Any change to the START path is benchmarked before and after.
- Optimise **perceived** latency, not the number. Click → visual acknowledgement
  → `STARTING` → `ACTIVE`. The window never freezes and never shows a modal.
- **Nothing resident.** No persistent WPF widget, no Python daemon, no agent.
  Both were profiled in the previous phase and rejected on measurement
  (182 MB for ~75 ms; 25–43 ms because Python startup is already detached).
- **No WMI on interactive paths**, no per-second process spawning, no network
  polling, no database polling.
- The config fetch moves off the render path (§3) — with numbers.
- Idle cost target: no timers running when no session is active.

## 11. Error handling principles

- **Network failure is not an error.** It is a normal condition and produces no
  popup, no red, no sound, no badge. It changes one status line.
- **Never imply local data is at risk.** Copy for every sync failure states the
  opposite explicitly: *"Data lokal aman."*
- Errors carry a **class**, not just a message, so the UI can distinguish
  unreachable from rejected (§2b gap).
- **`ERROR` on the session axis is reserved for local state corruption** — an
  unreadable `session.json`, an unopenable database. Never for the server.
- Copy is plain and calm. No exclamation marks, no "failed!", no jargon leaking
  into user-visible text.
- Anything automatic that changed the user's data is disclosed afterwards (§6).

## 12. Out of scope

Explicitly not in this or the next phase: analytics · charts · productivity
scoring · AI categorisation · plugin system · multi-device conflict UI ·
permanent background daemon · named-pipe IPC · server rewrite · cloud-first
architecture · Google Sheets sync · global start/stop hotkey · removal of
identity capture · schema changes to `physical_log` · changes to the sync
engine's retry/backoff · changes to the server API.

Hotkeys: only `Ctrl+Shift+L` (focus/open) is permitted, and only after checking
it is unclaimed. **`Ctrl+Shift+S` is rejected** — ending a session is
hold-to-confirm precisely so it cannot happen by accident, and a global hotkey
that ends a session destroys that property.

## 13. Wireframes

ASCII, Indonesian UI strings to match the shipping product.

### 13.1 Idle — no active session

```
 ┌───────────────────────────────────────────────┐
 │ LOGIX                    LAB-03    ● Tersimpan│
 ├───────────────────────────────────────────────┤
 │                                               │
 │  Dhana · 000000000                    [Ganti] │
 │                                               │
 │  Sedang mengerjakan                           │
 │  ┌─────────────────────────────────────────┐  │
 │  │                                         │  │
 │  └─────────────────────────────────────────┘  │
 │                                               │
 │  Akses  ● Langsung   ○ AnyDesk                │
 │  + Keterangan                                 │
 │                                               │
 │            [   MULAI SESI   ]                 │
 │                                               │
 ├───────────────────────────────────────────────┤
 │ HARI INI                                      │
 │  07:42  Literature Review          1j 12m   ● │
 │  06:15  Simulation Setup              48m   ● │
 ├───────────────────────────────────────────────┤
 │ 2 sesi · 2j 00m                               │
 └───────────────────────────────────────────────┘
```

### 13.2 Active session

```
 ┌───────────────────────────────────────────────┐
 │ LOGIX                    LAB-03    ● Tersimpan│
 ├───────────────────────────────────────────────┤
 │                                               │
 │                 SESI BERJALAN                 │
 │                                               │
 │            DFTB Parameterization              │
 │              Dhana · 000000000                │
 │                                               │
 │                 03:18:42                      │
 │                                               │
 │            mulai 07:42 · Langsung             │
 │                                               │
 │       ╭─────────────────────────────╮         │
 │       │  tahan untuk SELESAI        │         │
 │       ╰─────────────────────────────╯         │
 │                                               │
 ├───────────────────────────────────────────────┤
 │ HARI INI                                      │
 │  07:42  DFTB Parameterization    berjalan   ○ │
 │  06:15  Simulation Setup              48m   ● │
 ├───────────────────────────────────────────────┤
 │ 2 sesi · 4j 06m                               │
 └───────────────────────────────────────────────┘
```

The STOP control keeps the hold-to-confirm ring shipped in `89aff59`.

### 13.3 Recovery required

Takes over the window. This is a question, and it must be answered.

```
 ┌───────────────────────────────────────────────┐
 │ LOGIX                    LAB-03    ● Tersimpan│
 ├───────────────────────────────────────────────┤
 │                                               │
 │            SESI AKTIF DITEMUKAN               │
 │                                               │
 │            DFTB Parameterization              │
 │              Dhana · 000000000                │
 │                                               │
 │  Mulai      13 Agu 2026, 07:42                │
 │  Berjalan   3j 18m                            │
 │  Status     tersimpan di workstation ini      │
 │                                               │
 │  Sesi ini masih terbuka saat Logix ditutup.   │
 │                                               │
 │   [  Lanjutkan sesi  ]   [  Akhiri sesi  ]    │
 │                                               │
 └───────────────────────────────────────────────┘
```

Over-age variant (rule 2) adds one line and a countdown:

```
 │  Sesi ini sudah berjalan lebih dari 8 jam.    │
 │  Tanpa jawaban, sesi ditutup otomatis (0:47)  │
```

### 13.4 Local-only

Status line only. No badge, no warning colour, no action.

```
 │ LOGIX                    LAB-03    ● Tersimpan│
   ...
 │ ● Tersimpan di workstation ini                │
 │   Tidak ada yang perlu diunggah.              │
```

### 13.5 Sync pending

```
 │ LOGIX                    LAB-03     ● 3 menunggu│
   ...
 │ ● 3 perubahan menunggu sinkronisasi           │
 │   Data lokal aman.          [ Sinkronkan ]    │
```

Sync **blocked** — same slot, different copy, and no button, because there is
nothing the user can do:

```
 │ LOGIX                    LAB-03      ● Lokal  │
 │ ● Sinkronisasi dinonaktifkan oleh kebijakan   │
 │   Data tersimpan lengkap di workstation ini.  │
```

### 13.6 Syncing

```
 │ LOGIX                    LAB-03    ↻ Menyinkron│
   ...
 │ ↻ Menyinkronkan 3 perubahan…                  │
```

### 13.7 Sync error / server unavailable

```
 │ LOGIX                    LAB-03    ● Tak terhubung│
   ...
 │ ● Server tidak dapat dihubungi                │
 │   3 perubahan tersimpan aman di komputer ini. │
 │                              [ Coba lagi ]    │
```

`SYNC_ERROR` differs only in the first line — *"Sinkronisasi gagal"* — and keeps
the same reassurance and the same retry. Until the failure-class gap in §2b is
closed, both render as `SYNC_ERROR`.

---

## 14. Next phase

Phase 2 implements, in this order:

1. Failure classification in `_record_sync_attempt` (§2b gap) — the smallest
   change, and everything in the sync UI depends on it.
2. Verify and, if needed, clamp the `AUTO_CLOSE` end time (§6 gap).
3. Move the config fetch off the sign-in render path (§3), with before/after
   numbers.
4. `bar_status.json` v1 payload + state-change writes + 60 s beacon (§7),
   keeping legacy keys.
5. `RECOVERY_REQUIRED` state and the recovery card (§6, §13.3).
6. The status line and its seven states (§13.4–13.7).
7. The idle/active screens (§13.1–13.2).

Nothing in Phase 2 touches the SQLite schema, the sync engine's retry/backoff,
or the server API.
