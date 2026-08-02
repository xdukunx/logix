// Response shapes for the endpoints the dashboard consumes, transcribed from
// server/main.py. Kept minimal: only fields the UI actually reads.

export interface ActiveWorkstation {
  hostname: string;
  device_name: string;
  status: string; // "ACTIVE" | "LOCKED"
  username: string | null;
  anydesk_id: string;
  last_seen: string;
  /** When `status` last changed -- drives "Dikunci admin · 14:02". */
  status_since: string | null;
  /** Session start, for the card's live duration. Null when nobody is signed in. */
  session_started_at: string | null;
  /** "Fisik" | "SSH" | "AnyDesk" as reported by the agent. */
  access_type: string | null;
  purpose: string | null;
}

export type SyncStatus = "online" | "stale" | "offline" | "never_seen";

export interface Device extends Record<string, unknown> {
  device_id: string;
  hostname: string;
  display_name: string | null;
  category: string;
  sync_status: SyncStatus;
  currently_online: boolean;
  last_seen: string | null;
  policy_profile: string | null;
  privacy_mode: string | null;
}

export type CommandStatus = "queued" | "done" | "failed" | "expired";

export interface DeviceAction extends Record<string, unknown> {
  action_id: number;
  timestamp: string;
  action_type: string;
  status: CommandStatus;
  result_summary: string | null;
  error_message: string | null;
  retry_count: number;
  retryable: boolean;
}

export interface DeviceDetail {
  device: Device;
  policy: { description: string } | null;
  recent_actions: DeviceAction[];
  sync_health: Record<CommandStatus, number>;
}

export interface DeviceScreenshot {
  hostname: string;
  content_type: string | null;
  image_base64: string;
  captured_at: string;
}

export interface Reply {
  id: number;
  hostname: string;
  device_name: string | null;
  message: string;
  created_at: string;
  read_at: string | null;
}

export interface Alert {
  id: number;
  severity: "info" | "warning" | "critical";
  status: "active" | "acknowledged";
  title: string;
  message: string;
  created_at: string;
}

export interface SessionLog extends Record<string, unknown> {
  timestamp: string;
  hostname: string | null;
  event: string;
  session_type: string | null;
  username: string | null;
  nama: string | null;
  nim: string | null;
  tujuan: string | null;
  keterangan: string | null;
}

/**
 * One paired session (GET /api/sessions/spans): a START matched with its
 * close event. `duration_seconds` is null while the session is still running.
 */
export interface SessionSpan extends Record<string, unknown> {
  session_id: string;
  timestamp: string;
  hostname: string;
  nama: string;
  nim: string;
  username: string;
  tujuan: string;
  session_type: string;
  duration_seconds: number | null;
}

export interface AuditAction extends Record<string, unknown> {
  timestamp: string;
  actor_email: string;
  target_device: string | null;
  action_type: string;
  status: CommandStatus;
  reason: string | null;
  result_summary: string | null;
}

export interface Analytics {
  totals: { hours: number; sessions: number; workstations: number };
  by_workstation: { hostname: string; hours: number }[];
  by_purpose: { purpose: string; count: number }[];
  by_hour: { hour: string; count: number }[];
  // Day-of-week (Mon..Sun) x hour occupancy matrix for the heatmap; each
  // entry's `hours` is a 24-length count array. Optional for backward compat.
  by_dow_hour?: { day: string; hours: number[] }[];
}

// GET/PUT /api/config -- the config object the Settings tab edits. Fields the
// UI doesn't expose (text.*, requiredFields, ...) ride along untouched.
export interface LogixConfig {
  branding?: {
    logoText?: string;
    title?: string;
    subtitle?: string;
    colors?: { primary?: string; accent?: string; [k: string]: string | undefined };
    [k: string]: unknown;
  };
  accessTypes?: string[];
  purposes?: string[];
  devices?: { device_types?: string[]; naming_pattern?: string };
  reports?: {
    default_scope?: string;
    include_branding?: boolean;
    include_purpose_summary?: boolean;
    include_device_summary?: boolean;
  };
  privacy?: {
    notice?: string;
    collected?: string[];
    not_collected?: string[];
    /** Settings > Privasi: suppress user names on the /wall TV display. */
    hide_names_on_wall?: boolean;
    [k: string]: unknown;
  };
  [k: string]: unknown;
}
