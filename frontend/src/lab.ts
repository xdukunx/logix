// The lab as a live screen reads it: which station is in use, which ones are
// beating, and how much the lab was used this week. Monitoring, wall mode and
// the Pesan inbox all read stations and sessions through here, so a station
// can never carry one status on the wall and another in a thread, and an hour
// of use is counted the same way on every screen.
import { useRef, useState } from "react";

import { getJson } from "./api";
import { categoryLabel, type StationStatus } from "./tokens";
import type { ActiveWorkstation, Device, SessionSpan } from "./types";
import type { DayBar } from "./ui/viz";
import { splitDeviceName, usePolling } from "./util";

export const BEAT_WINDOW_MS = 60_000;
export const HOUR_MS = 3_600_000;
export const DAY_MS = 24 * HOUR_MS;
export const DAYS_SHORT = ["Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"];

export const pad = (n: number) => String(n).padStart(2, "0");
export const ymd = (t: number) => {
  const d = new Date(t);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};
export const startOfDay = (t: number) => {
  const d = new Date(t);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
};
export const spanStart = (s: SessionSpan) => Date.parse(s.timestamp);
/** An open span (no close event yet) runs until now. */
export const spanEnd = (s: SessionSpan, now: number) =>
  s.duration_seconds === null ? now : spanStart(s) + s.duration_seconds * 1000;
export const overlapMs = (a0: number, a1: number, b0: number, b1: number) => Math.max(0, Math.min(a1, b1) - Math.max(a0, b0));
export const hoursLabel = (h: number) => `${h.toLocaleString("id-ID", { maximumFractionDigits: 1 })} j`;

/** What a heartbeat can say about a station; "alert" comes from the alerts feed. */
export type LabStatus = Exclude<StationStatus, "alert">;

export const LAB_STATUS_LABEL: Record<LabStatus, string> = {
  active: "Dipakai",
  locked: "Terkunci",
  idle: "Bebas",
  offline: "Offline",
};
export const LAB_STATUSES = Object.keys(LAB_STATUS_LABEL) as LabStatus[];

export const stationStatus = (live: ActiveWorkstation | null | undefined): LabStatus => {
  if (!live) return "offline";
  if (live.status === "LOCKED") return "locked";
  // Online but nobody signed in -- the station is free.
  return live.username ? "active" : "idle";
};

export interface LabStation {
  hostname: string;
  id: string;
  spec: string;
  status: LabStatus;
  live: ActiveWorkstation | null;
  lastSeen: string | null;
}

export const mergeStations = (devices: Device[], active: ActiveWorkstation[]): LabStation[] => {
  const liveByHost = new Map(active.map((a) => [a.hostname, a]));
  return devices
    .map((d) => {
      const live = liveByHost.get(d.hostname) ?? null;
      const { id, spec } = splitDeviceName(d.display_name || live?.device_name || d.hostname);
      return {
        hostname: d.hostname,
        id,
        // A display_name with no " - <spec>" half leaves spec empty; the raw
        // category KEY would print "WS-01 - lab_workstation".
        spec: spec || categoryLabel(d.category),
        status: stationStatus(live),
        live,
        lastSeen: live?.last_seen ?? d.last_seen,
      };
    })
    .sort((a, b) => a.id.localeCompare(b.id, "id", { numeric: true }));
};

/** The last seven days of use as totals, today last. */
export const weekUsage = (spans: SessionSpan[], now: number) => {
  const today0 = startOfDay(now);
  const hoursIn = (d0: number, d1: number) =>
    spans.reduce((sum, s) => sum + overlapMs(spanStart(s), spanEnd(s, now), d0, d1), 0) / HOUR_MS;
  const days: DayBar[] = [];
  for (let i = 6; i >= 0; i -= 1) {
    const d0 = today0 - i * DAY_MS;
    const hours = hoursIn(d0, d0 + DAY_MS);
    days.push({
      key: ymd(d0),
      label: i === 0 ? "Hari ini" : DAYS_SHORT[new Date(d0).getDay()],
      value: hours,
      tag: hoursLabel(hours),
      isToday: i === 0,
    });
  }
  const todayHours = days[6].value;
  // Yesterday only up to this same time of day: a whole day against half of
  // one would always read as a drop.
  const yesterdaySoFar = hoursIn(today0 - DAY_MS, now - DAY_MS);
  const todaySpans = spans.filter((s) => spanEnd(s, now) > today0);
  // Identity is used to COUNT people and goes no further.
  const people = new Set(todaySpans.map((s) => s.nim || s.nama || s.username).filter(Boolean));
  return {
    days,
    todayHours,
    delta: yesterdaySoFar > 0 ? ((todayHours - yesterdaySoFar) / yesterdaySoFar) * 100 : null,
    todaySpans,
    peopleToday: people.size,
  };
};

/**
 * Polls the lab: the registry every 15s, liveness every 3s and a week of spans
 * every minute. A failed poll keeps the last good answer, so the caller reads
 * staleness from `liveAt` instead of watching the board blank out.
 */
export const useLabLive = () => {
  const [devices, setDevices] = useState<Device[] | null>(null);
  const [active, setActive] = useState<ActiveWorkstation[]>([]);
  // "unavailable": an account without sessions_read, or a server that was away
  // before the first answer. A zero there would read as an empty lab.
  const [spans, setSpans] = useState<SessionSpan[] | "unavailable" | null>(null);
  const [liveAt, setLiveAt] = useState<number | null>(null);
  const [lastBeatAt, setLastBeatAt] = useState<number | null>(null);
  // Heartbeats per station, as the times we SAW last_seen move between two
  // polls. The first reading of a station is not a beat: we did not see it arrive.
  const beatsRef = useRef(new Map<string, number[]>());
  const lastSeenRef = useRef(new Map<string, string>());

  usePolling(async () => {
    try {
      setDevices(await getJson<Device[]>("/api/devices", ""));
    } catch {
      /* keep the last good registry */
    }
  }, 15000);

  usePolling(async () => {
    try {
      const list = await getJson<ActiveWorkstation[]>("/api/active", "");
      const now = Date.now();
      let sawBeat = false;
      for (const a of list) {
        const prev = lastSeenRef.current.get(a.hostname);
        if (prev !== undefined && prev !== a.last_seen) {
          beatsRef.current.set(a.hostname, [...(beatsRef.current.get(a.hostname) ?? []), now]);
          sawBeat = true;
        }
        lastSeenRef.current.set(a.hostname, a.last_seen);
      }
      for (const [host, beats] of beatsRef.current) {
        beatsRef.current.set(host, beats.filter((t) => now - t < BEAT_WINDOW_MS));
      }
      setActive(list);
      setLiveAt(now);
      if (sawBeat) setLastBeatAt(now);
    } catch {
      /* keep the last good board */
    }
  }, 3000);

  usePolling(async () => {
    try {
      const page = await getJson<{ sessions: SessionSpan[] }>(
        `/api/sessions/spans?start_date=${ymd(Date.now() - 6 * DAY_MS)}&limit=5000`,
        "",
      );
      setSpans(page.sessions);
    } catch {
      setSpans((prev) => prev ?? "unavailable");
    }
  }, 60000);

  const beatsOf = (hostname: string) => beatsRef.current.get(hostname) ?? [];
  return { devices, active, spans, liveAt, lastBeatAt, beatsOf };
};
