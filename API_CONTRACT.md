# Logix — device enrollment API contract

Status: **implemented** (roadmap item E in
[docs/AUDIT_AND_ROADMAP.md](docs/AUDIT_AND_ROADMAP.md)) — `POST
/api/enroll/invite`, `POST /api/enroll`, `POST
/api/devices/{device_id}/revoke`, and the agent-side `device.json` identity
file described below all exist in `server/main.py` / `logix/paths.py` /
`windows/logbook_setup.ps1`, covered by `tests/test_server_enroll.py`. This
document remains the contract reference for the exact shapes and error
codes. Terminology matches the repo, not an earlier planning draft: devices
are assigned a `category` (see
[docs/config.schema.json](docs/config.schema.json)), not a "device_profile."

## Design decisions this contract encodes

- **Enrollment model: single-use invite code**, not an approval queue. Admin
  generates a code from the dashboard; it is relayed to the device
  out-of-band (typed into the wizard during setup, or told to the operator
  verbally/securely) — never over a channel that doubles as the enrollment
  transport itself.
- **Local-first identity.** A device writes `device.json` locally as soon as
  it decides its identity; enrollment with the server happens whenever the
  server is reachable, and is retried — it never blocks first run. This
  matches the already-implemented `sync_unsynced_logs()` pattern in
  `logix/log_physical.py` (best-effort inline attempt + designed for a
  scheduled retry layer).
- **Category, not ad hoc config.** `category` (`lab_workstation` |
  `office_workstation` | `loaned_laptop` | `mobile_device` | `server` |
  `custom`) is the only thing an operator sets. Category drives defaults —
  heartbeat interval, popup frequency — via a server-side lookup table, so a
  fork with a different device taxonomy edits config, not code.
- **Per-device API key**, issued only at successful enrollment, replaces the
  shared `LOGIX_INGEST_API_KEY` for that device going forward. The shared key
  (Batch 2) remains as the bootstrap/dev-mode fallback and for deployments
  that don't need per-device revocation.

## 1. Admin: create an invite code

```
POST /api/enroll/invite
Authorization: Bearer <admin session token>   (verify_token, same as dashboard)
```

Request body:

```json
{
  "category": "lab_workstation",
  "display_name": "Lab PC 03",
  "note": "optional operator note, shown in the devices list"
}
```

- `category` is optional; if omitted, the device chooses `custom` at
  enrollment and an admin can reclassify it later from the dashboard.

Response `201`:

```json
{
  "invite_code": "7K2P-9QXR-4M1D",
  "expires_at": "2026-07-02T09:15:00+07:00",
  "category": "lab_workstation"
}
```

- Code is single-use, **15-minute TTL**, high-entropy (not a 4–6 digit PIN —
  brute-forcing `/api/enroll` must not be practical even unauthenticated).
- Codes are persisted the same way sessions are (not a plain in-memory dict
  that a server restart silently invalidates without operator visibility).

## 2. Device: redeem the invite code

```
POST /api/enroll
```

No `Authorization` / `X-API-Key` header — the device has no credential yet.
This is why the invite code itself must be short-lived, single-use, and rate
limited at this endpoint specifically.

Request body:

```json
{
  "invite_code": "7K2P-9QXR-4M1D",
  "hostname": "LAB-PC-03",
  "os": "windows",
  "os_version": "10.0.19045",
  "agent_version": "0.2.0"
}
```

- `os` is one of `windows` | `linux` | `macos`. This is a data field only —
  the server does not branch enrollment behavior on it. Platform-support
  status (Windows/Linux verified, macOS beta pending hardware access) is an
  agent/installer-side concern, not something the contract encodes.

Success response `200`:

```json
{
  "device_id": "3fae1c2e-6b9d-4e2a-9b0a-1a2b3c4d5e6f",
  "api_key": "a9f2...redacted...",
  "category": "lab_workstation",
  "profile": {
    "heartbeat_interval_seconds": 30,
    "popup_frequency": "every_unlock"
  },
  "server_time": "2026-07-02T09:03:11+07:00"
}
```

- `device_id` is a stable UUID, generated server-side, persisted in
  `device.json` on the agent — this is the durable identity, not `hostname`
  (hostnames get reimaged/renamed).
- `profile` is the category's current defaults, returned so the agent can
  self-configure immediately without a second round trip. The agent still
  polls `/api/config` (existing endpoint) for branding/text updates.

Error responses:

| Status | Body `detail` | Cause |
|---|---|---|
| 400 | `"Invalid or already-used invite code"` | Code doesn't exist / already redeemed |
| 410 | `"Invite code expired"` | Past the 15-minute TTL |
| 429 | `"Too many enrollment attempts, try again later"` | Rate limit on this unauthenticated endpoint |

## 3. Admin: device registry

```
GET /api/devices          → list, same category/status fields as device.json
POST /api/devices/{id}/revoke   → invalidate that device's api_key immediately
```

Revocation is the mechanism for "loaned laptop came back" / "laptop was
lost" — the device's next heartbeat/log push gets `401` and the agent falls
back to local-only logging until re-enrolled.

## 4. `category` profile defaults (server-side config, not code)

Lives alongside `server_config.json`, edited by an operator, not a developer:

```json
{
  "category_profiles": {
    "lab_workstation":    { "heartbeat_interval_seconds": 30,  "popup_frequency": "every_unlock" },
    "office_workstation": { "heartbeat_interval_seconds": 60,  "popup_frequency": "every_unlock" },
    "loaned_laptop":      { "heartbeat_interval_seconds": 300, "popup_frequency": "once_per_day" },
    "mobile_device":      { "heartbeat_interval_seconds": 300, "popup_frequency": "once_per_day" },
    "server":             { "heartbeat_interval_seconds": 300, "popup_frequency": "never" },
    "custom":             { "heartbeat_interval_seconds": 60,  "popup_frequency": "every_unlock" }
  }
}
```

A device may override any individual field post-enrollment from the
dashboard without changing its category.

## 5. Popup gate — Option A+ (marker + identity, silent re-session)

Applies when `popup_frequency = "once_per_day"`. Decouples two concerns that
a plain daily boolean conflates: *"has this user been prompted today"* vs.
*"is there a live session tracking right now."* The second must never have
gaps — that's the entire point of the tool.

Local marker file (survives reboot, one per device):

```json
{ "date": "2026-07-02", "identity": { "nama": "...", "nim": "..." } }
```

On every unlock event:

- Marker's `date` matches today → **skip the popup**, but silently start a
  new session using the cached `identity` from the marker (no prompt). This
  is what makes "once per day" apply to the *prompt*, not to session
  coverage — a user unlocking again 8 hours later is still logged correctly.
- Marker missing or stale → show the popup as normal; write the marker on
  submit.

`popup_frequency = "every_unlock"` skips the marker entirely and always
prompts. `"never"` never prompts and never gates a session (used for
`category: server`, where there is no interactive user to identify).

## 6. Privacy-mode interaction

`privacyMode` (`local_only` | `redacted_sync` | `admin_full_sync`, see
[docs/PRIVACY.md](docs/PRIVACY.md)) is orthogonal to enrollment: a device can
be enrolled (has an identity, appears in the registry, gets category
defaults) while still being `local_only` and never calling `/api/log`.
Enrollment ≠ consent to sync PII; those are two separate opt-ins.
