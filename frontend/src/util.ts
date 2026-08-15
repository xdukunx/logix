import { useEffect, useRef, useState } from "react";

const DAYS_ID = ["Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"];

/**
 * Duration in the design's Indonesian short form: "45m" under an hour,
 * "1j 03m" above it (minutes zero-padded so the mono column stays aligned).
 */
export const formatDuration = (seconds: number | null | undefined): string => {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return "-";
  const totalMinutes = Math.floor(seconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours === 0) return `${minutes}m`;
  return `${hours}j ${String(minutes).padStart(2, "0")}m`;
};

/** Elapsed time since an ISO timestamp, in the same short form. */
export const durationSince = (iso: string | null | undefined): string => {
  if (!iso) return "-";
  const started = new Date(iso).getTime();
  if (Number.isNaN(started)) return "-";
  return formatDuration((Date.now() - started) / 1000);
};

/**
 * Freshness label for sync/heartbeat columns: seconds and minutes stay
 * relative ("8 dtk lalu"), anything older switches to an absolute weekday +
 * clock ("Sen 09:12") because "3 hari lalu" is useless for finding a device.
 */
export const timeAgo = (iso: string | null | undefined): string => {
  if (!iso) return "Belum pernah";
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return "Belum pernah";
  const seconds = Math.max(0, (Date.now() - then.getTime()) / 1000);
  if (seconds < 60) return `${Math.floor(seconds)} dtk lalu`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} mnt lalu`;
  const hours = Math.floor(minutes / 60);
  if (hours < 12) return `${hours} jam lalu`;
  return `${DAYS_ID[then.getDay()]} ${formatClock(iso)}`;
};

/** Wall-clock time only: "14:02". */
export const formatClock = (iso: string | null | undefined): string => {
  if (!iso) return "-";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "-";
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};

/** Log-table timestamp: "02/08 · 09:41". */
export const formatLogTime = (iso: string | null | undefined): string => {
  if (!iso) return "-";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "-";
  const day = String(d.getDate()).padStart(2, "0");
  const month = String(d.getMonth() + 1).padStart(2, "0");
  return `${day}/${month} · ${formatClock(iso)}`;
};

/** Absolute date + time, for drawers and detail rows. */
export const formatDateTime = (iso: string | null | undefined): string =>
  iso ? new Date(iso).toLocaleString("id-ID") : "-";

/** Weekday + clock, for "Offline sejak Sen 09:12". */
export const formatSince = (iso: string | null | undefined): string => {
  if (!iso) return "-";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "-";
  return `${DAYS_ID[d.getDay()]} ${formatClock(iso)}`;
};

/**
 * Split a device display name into its station ID and spec. Names read
 * "WS-07 - GPU-A100"; the ID itself contains a hyphen, so only a SPACED
 * separator divides the two. Mirrors the same rule in the WPF client.
 */
export const splitDeviceName = (name: string | null | undefined): { id: string; spec: string } => {
  const raw = (name || "").trim();
  if (!raw) return { id: "-", spec: "" };
  const parts = raw.split(/\s+[-·]\s+/);
  return { id: parts[0].trim(), spec: parts.slice(1).join(" ").trim() };
};

// Poll `fn` every `ms` while the component is mounted; fires once
// immediately. Matches the legacy per-tab polling (data refreshes only for
// the visible tab, since hidden views are unmounted).
export const usePolling = (fn: () => void, ms: number) => {
  const fnRef = useRef(fn);
  fnRef.current = fn;
  useEffect(() => {
    fnRef.current();
    const id = setInterval(() => fnRef.current(), ms);
    return () => clearInterval(id);
  }, [ms]);
};

/** Re-renders on an interval so relative labels ("2j 14m") stay live. */
export const useTicker = (ms = 1000) => {
  const [, setNow] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(id);
  }, [ms]);
};
