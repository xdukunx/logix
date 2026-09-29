// Perangkat's rules about devices, apart from how they are drawn: which agent
// build counts as behind, what earns a place in "Perlu perhatian", and how the
// registry filters and sorts.
import { categoryLabel, type StationStatus } from "../tokens";
import type { Device, SyncStatus } from "../types";
import { formatSince, splitDeviceName, timeAgo } from "../util";

export const SYNC_STATUS: Record<SyncStatus, StationStatus> = {
  online: "active",
  stale: "locked",
  offline: "offline",
  never_seen: "idle",
};

// "Tersendat" is the server's `stale`: heartbeats missed against the
// category's cadence, but recently enough that the machine is plausibly up.
export const SYNC_LABEL: Record<SyncStatus, string> = {
  online: "Online",
  stale: "Tersendat",
  offline: "Offline",
  never_seen: "Belum terlihat",
};

export const SYNC_ORDER: SyncStatus[] = ["online", "stale", "offline", "never_seen"];

// A machine that has gone dark outranks one that is merely late, which
// outranks one that has never reported at all. Both "Perlu perhatian" and the
// registry's status sort put the worst first.
const SYNC_SEVERITY: Record<SyncStatus, number> = { offline: 3, stale: 2, never_seen: 1, online: 0 };

// Monitoring warns at the same threshold.
const SKEW_WARN_SECONDS = 120;

export const nameOf = (d: Device) => splitDeviceName(d.display_name || d.hostname);

const compareIds = (a: Device, b: Device) => nameOf(a).id.localeCompare(nameOf(b).id, "id", { numeric: true });

export const byId = (list: Device[]) => [...list].sort(compareIds);

// The registry column is `agent_version`. The old table read `client_version`,
// which the server has never sent, so every row said "-".
export const agentVersion = (d: Device): string | null =>
  typeof d.agent_version === "string" && d.agent_version.trim() ? d.agent_version.trim() : null;

/** How far this device's clock is off, in minutes -- only when it is enough to shift session times. */
export const skewMinutes = (d: Device): number | null => {
  const s = d.clock_skew_seconds;
  return typeof s === "number" && Math.abs(s) > SKEW_WARN_SECONDS ? Math.round(Math.abs(s) / 60) : null;
};

/** Numeric, part by part: "1.10.0" is newer than "1.9.3". */
const compareVersions = (a: string, b: string): number => {
  const pa = a.split(/[^0-9]+/).filter(Boolean).map(Number);
  const pb = b.split(/[^0-9]+/).filter(Boolean).map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d;
  }
  return a.localeCompare(b);
};

export const isOutdated = (d: Device, newest: string | null) => {
  const v = agentVersion(d);
  return Boolean(v && newest && compareVersions(v, newest) < 0);
};

export interface VersionRow {
  version: string | null;
  count: number;
}

/**
 * Agent builds in use, newest first, then the devices that never reported one.
 * The server has no notion of a current release, so the newest build seen
 * anywhere in the fleet is the reference and "behind" means behind the fleet.
 */
export const summariseVersions = (list: Device[]) => {
  const counts = new Map<string, number>();
  let unknown = 0;
  for (const d of list) {
    const v = agentVersion(d);
    if (v) counts.set(v, (counts.get(v) ?? 0) + 1);
    else unknown += 1;
  }
  const rows: VersionRow[] = [...counts]
    .sort((a, b) => compareVersions(b[0], a[0]))
    .map(([version, count]) => ({ version, count }));
  const newest = rows[0]?.version ?? null;
  const outdated = rows.slice(1).reduce((s, r) => s + r.count, 0);
  if (unknown > 0) rows.push({ version: null, count: unknown });
  return { rows, newest, outdated };
};

export type VersionSummary = ReturnType<typeof summariseVersions>;

/** `value` is the time, duration or version part, which is drawn in mono. */
export interface Reason {
  label: string;
  value?: string;
}

export const reasonText = (r: Reason) => (r.value ? `${r.label} ${r.value}` : r.label);

export interface Issue {
  device: Device;
  /** Worst first. */
  reasons: Reason[];
}

/** Every device an admin should go and look at, worst first. */
export const attentionList = (list: Device[], newest: string | null): Issue[] =>
  list
    .map((device) => {
      const reasons: Reason[] = [];
      if (device.sync_status === "offline") reasons.push({ label: "Offline sejak", value: formatSince(device.last_seen) });
      else if (device.sync_status === "stale") reasons.push({ label: "Tersendat ·", value: timeAgo(device.last_seen) });
      else if (device.sync_status === "never_seen") reasons.push({ label: "Belum pernah terlihat" });
      if (isOutdated(device, newest)) reasons.push({ label: "Agent", value: `${agentVersion(device)} → ${newest}` });
      const skew = skewMinutes(device);
      if (skew !== null) reasons.push({ label: "Jam selisih", value: `${skew} mnt` });
      return { device, reasons };
    })
    .filter((x) => x.reasons.length > 0)
    .sort(
      (a, b) =>
        SYNC_SEVERITY[b.device.sync_status] - SYNC_SEVERITY[a.device.sync_status] ||
        b.reasons.length - a.reasons.length ||
        compareIds(a.device, b.device),
    );

export type SortKey = "status" | "id" | "seen" | "version";

export const SORT_OPTIONS: { value: SortKey; label: string }[] = [
  { value: "status", label: "Status" },
  { value: "id", label: "ID" },
  { value: "seen", label: "Terakhir terlihat" },
  { value: "version", label: "Versi agent" },
];

// Minute resolution: last_seen moves on every heartbeat, and sorting on the
// raw value would reshuffle the online rows on every poll.
const seenMinute = (d: Device) => (d.last_seen ? Math.floor(Date.parse(d.last_seen) / 60_000) : -Infinity);

const SORTERS: Record<SortKey, (a: Device, b: Device) => number> = {
  status: (a, b) => SYNC_SEVERITY[b.sync_status] - SYNC_SEVERITY[a.sync_status] || compareIds(a, b),
  id: compareIds,
  seen: (a, b) => seenMinute(b) - seenMinute(a) || compareIds(a, b),
  version: (a, b) => {
    const va = agentVersion(a);
    const vb = agentVersion(b);
    if (va && vb) return compareVersions(vb, va) || compareIds(a, b);
    return va ? -1 : vb ? 1 : compareIds(a, b);
  },
};

/** A registry filter, picked from one of the bento cards. */
export type Filter =
  | { kind: "sync"; value: SyncStatus }
  | { kind: "version"; value: string | null }
  | { kind: "attention" };

export const filterLabel = (f: Filter): string =>
  f.kind === "sync"
    ? SYNC_LABEL[f.value]
    : f.kind === "version"
      ? f.value
        ? `Versi ${f.value}`
        : "Versi belum dilaporkan"
      : "Perlu perhatian";

export const sameFilter = (a: Filter | null, b: Filter): boolean =>
  a !== null && a.kind === b.kind && ("value" in a && "value" in b ? a.value === b.value : true);

export const registryRows = (
  list: Device[],
  { search, filter, sort, attention }: { search: string; filter: Filter | null; sort: SortKey; attention: Issue[] },
): Device[] => {
  const needle = search.trim().toLowerCase();
  const flagged = new Set(attention.map((x) => x.device.device_id));
  return list
    .filter((d) => {
      if (filter?.kind === "sync" && d.sync_status !== filter.value) return false;
      if (filter?.kind === "version" && agentVersion(d) !== filter.value) return false;
      if (filter?.kind === "attention" && !flagged.has(d.device_id)) return false;
      return (
        !needle ||
        `${d.hostname} ${d.display_name ?? ""} ${d.category} ${categoryLabel(d.category)} ${agentVersion(d) ?? ""}`
          .toLowerCase()
          .includes(needle)
      );
    })
    .sort(SORTERS[sort]);
};
