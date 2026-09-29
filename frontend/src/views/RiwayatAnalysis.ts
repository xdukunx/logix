// Riwayat's period analysis. Computed in the browser from the same session
// spans the log table pages through (GET /api/sessions/spans), so every chart
// agrees with the rows under it and no new server endpoint is needed.
//
// Like the summary and the exports, a session belongs to the period it
// STARTED in (the server filters on the start date), and timestamps are the
// server's naive local times, parsed as local here. Hours are split across
// hour / day / week buckets at the real clock boundaries, so a session over
// midnight lands on both days. A session still running counts up to now;
// that is deliberately NOT the rule behind the headline total
// (/api/sessions/summary counts an open session as 0 h, to match the
// exports), which is why the page states the running hours separately
// instead of letting the two numbers silently disagree.
import { ACCESS_LABEL, resolveAccessType, type AccessType } from "../tokens";
import type { Device, SessionSpan } from "../types";
import { splitDeviceName } from "../util";

export type Period = "hari" | "7hari" | "bulan" | "semester" | "semua";

const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;

export const DAYS_SHORT = ["Sen", "Sel", "Rab", "Kam", "Jum", "Sab", "Min"];
export const DAYS_LONG = ["Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"];

/** Mirrors MAX_SESSION_HOURS in server/main.py: the cap a capped span hit. */
export const MAX_SESSION_HOURS = 16;

export const pad = (n: number) => String(n).padStart(2, "0");

export const iso = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const dayMonth = (t: number) => {
  const d = new Date(t);
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}`;
};
/** Monday-first weekday index (Sen = 0), the Indonesian calendar week. */
export const weekdayOf = (t: number) => (new Date(t).getDay() + 6) % 7;

const startOfDay = (t: number) => {
  const d = new Date(t);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
};
const parseDay = (ymd: string) => {
  const [y, m, d] = ymd.split("-").map(Number);
  return new Date(y, m - 1, d).getTime();
};
// Calendar arithmetic through Date setters rather than +/- DAY_MS, so a
// daylight-saving hop on the viewer's machine cannot shift a boundary.
const shiftDays = (t: number, days: number) => {
  const d = new Date(t);
  d.setDate(d.getDate() + days);
  return d.getTime();
};
const shiftMonths = (t: number, months: number) => {
  const d = new Date(t);
  const target = new Date(d.getFullYear(), d.getMonth() + months, 1, d.getHours(), d.getMinutes(), d.getSeconds());
  const lastDay = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate();
  target.setDate(Math.min(d.getDate(), lastDay));
  return target.getTime();
};

/**
 * Resolve a preset to an inclusive YYYY-MM-DD range. "Semester ini" follows
 * the Indonesian academic split: Feb-Jul (genap) and Aug-Jan (ganjil).
 */
export const rangeFor = (period: Period, now = Date.now()): { start_date?: string; end_date?: string } => {
  const today = new Date(now);
  const end = iso(today);
  switch (period) {
    case "hari":
      return { start_date: end, end_date: end };
    case "7hari":
      return { start_date: iso(new Date(shiftDays(now, -6))), end_date: end };
    case "bulan":
      return { start_date: iso(new Date(today.getFullYear(), today.getMonth(), 1)), end_date: end };
    case "semester": {
      const m = today.getMonth();
      const start =
        m >= 1 && m <= 6
          ? new Date(today.getFullYear(), 1, 1)
          : new Date(m === 0 ? today.getFullYear() - 1 : today.getFullYear(), 7, 1);
      return { start_date: iso(start), end_date: end };
    }
    default:
      return {};
  }
};

/** "01/09–25/09", or one date for a single day. */
export const rangeLabel = (range: { start_date?: string; end_date?: string }) => {
  if (!range.start_date || !range.end_date) return "semua waktu";
  const a = dayMonth(parseDay(range.start_date));
  const b = dayMonth(parseDay(range.end_date));
  return a === b ? a : `${a}–${b}`;
};

/**
 * The window a period is compared against: the same stretch of the previous
 * day / week / month / semester, cut at the same point in time. Comparing a
 * whole previous period with one that is only partly over would always read
 * as a drop.
 */
export const previousWindow = (period: Period, from: number, now: number) => {
  switch (period) {
    case "hari":
      return { from: shiftDays(from, -1), to: shiftDays(now, -1), caption: "vs kemarin di jam yang sama" };
    case "7hari":
      return { from: shiftDays(from, -7), to: shiftDays(now, -7), caption: "vs 7 hari sebelumnya" };
    case "bulan":
      return { from: shiftMonths(from, -1), to: shiftMonths(now, -1), caption: "vs bulan lalu s.d. tanggal yang sama" };
    case "semester":
      return { from: shiftMonths(from, -6), to: shiftMonths(now, -6), caption: "vs semester lalu di titik yang sama" };
    default:
      return null;
  }
};

export const periodStart = (range: { start_date?: string }) => (range.start_date ? parseDay(range.start_date) : null);

/**
 * The day before `date` (YYYY-MM-DD). The server keeps a session only when its
 * START falls inside the requested dates, so a session that began before a
 * period and ran into it would be missing altogether. The charts ask for one
 * extra day and clip at the edge; a session is capped at MAX_SESSION_HOURS by
 * the server, so one day catches every one that can cross it.
 */
export const leadInDate = (date: string) => iso(new Date(shiftDays(parseDay(date), -1)));

const spanStart = (s: SessionSpan) => Date.parse(s.timestamp);
/**
 * An open span (no close event yet) runs until now -- but no further than
 * the server's cap, which is all it will be credited with once it closes. A
 * session left open for days would otherwise paint days of the charts.
 */
export const spanEnd = (s: SessionSpan, now: number) =>
  s.duration_seconds === null
    ? Math.min(now, spanStart(s) + MAX_SESSION_HOURS * HOUR_MS)
    : spanStart(s) + s.duration_seconds * 1000;
const overlapMs = (a0: number, a1: number, b0: number, b1: number) => Math.max(0, Math.min(a1, b1) - Math.max(a0, b0));

export const clippedHours = (spans: SessionSpan[], from: number, to: number, now: number) =>
  spans.reduce((sum, s) => {
    const start = spanStart(s);
    return Number.isNaN(start) ? sum : sum + overlapMs(start, spanEnd(s, now), from, to);
  }, 0) / HOUR_MS;

export const hoursText = (h: number) => {
  if (h > 0 && h < 0.05) return "<0,1 j";
  return `${h.toLocaleString("id-ID", { maximumFractionDigits: 1 })} j`;
};

// ---------------------------------------------------------------------------

type Grain = "hour" | "day" | "week" | "month";

/** One bar of a PillBars chart (the hours trend, the session-length histogram). */
export interface Bar {
  key: string;
  /** Axis label under the bar. */
  label: string;
  /** Text of the ink tag riding on the bar. */
  tag: string;
  value: number;
  /** The one lime bar: the bucket "now" falls in, or the most common length. */
  isLead: boolean;
  isFuture: boolean;
}

interface TrendBucket extends Bar {
  start: number;
  end: number;
}

export interface Ranked {
  key: string;
  label: string;
  hours: number;
  sessions: number;
}

export interface HeatMap {
  /** Visible hour columns, inclusive. */
  hourFrom: number;
  hourTo: number;
  /** [weekday Sen..Min][hour 0..23]: stations in use on average, null = no such hour in the period. */
  cells: (number | null)[][];
  max: number;
  peak: { day: number; hour: number; value: number } | null;
}

interface Analysis {
  grain: Grain;
  trend: TrendBucket[];
  /** Hours per bucket's worth of elapsed time, so a half-over bucket does not drag it down. */
  trendAverage: number;
  totalHours: number;
  runningCount: number;
  runningHours: number;
  autoClosedCount: number;
  cappedCount: number;
  /** Hours of sessions closed by a real event from the device: not running, not inferred, not capped. */
  observedHours: number;
  stations: Ranked[];
  stationCount: number;
  purposes: Ranked[];
  access: { type: AccessType; label: string; count: number }[];
  durations: Bar[];
  medianSeconds: number | null;
  maxSeconds: number | null;
  heat: HeatMap;
}

const DURATION_BINS: { key: string; label: string; below: number }[] = [
  { key: "lt30", label: "<30m", below: 30 * 60 },
  { key: "lt60", label: "30m–1j", below: 3600 },
  { key: "lt2h", label: "1–2j", below: 2 * 3600 },
  { key: "lt4h", label: "2–4j", below: 4 * 3600 },
  { key: "lt8h", label: "4–8j", below: 8 * 3600 },
  { key: "rest", label: "≥8j", below: Infinity },
];

const grainFor = (period: Period, from: number, to: number): Grain => {
  if (period === "hari") return "hour";
  const days = (to - from) / DAY_MS;
  if (days <= 45) return "day";
  if (days <= 220) return "week";
  return "month";
};

const buildBuckets = (grain: Grain, from: number, to: number, now: number): TrendBucket[] => {
  const out: TrendBucket[] = [];
  const push = (start: number, end: number, label: string, tagLabel: string) =>
    out.push({
      key: String(start),
      label,
      tag: tagLabel,
      start,
      end,
      value: 0,
      isLead: start <= now && now < end,
      isFuture: start > now,
    });

  if (grain === "hour") {
    const d = new Date(startOfDay(from));
    for (let h = 0; h < 24; h += 1) {
      const start = new Date(d.getFullYear(), d.getMonth(), d.getDate(), h).getTime();
      const end = new Date(d.getFullYear(), d.getMonth(), d.getDate(), h + 1).getTime();
      push(start, end, pad(h), `${pad(h)}:00`);
    }
    return out;
  }
  if (grain === "day") {
    const days = Math.round((startOfDay(to) - startOfDay(from)) / DAY_MS) + 1;
    for (let t = startOfDay(from); t <= to; t = shiftDays(t, 1)) {
      const isToday = t === startOfDay(now);
      const label = days <= 7 ? (isToday ? "Hari ini" : DAYS_SHORT[weekdayOf(t)]) : String(new Date(t).getDate());
      push(t, shiftDays(t, 1), label, `${DAYS_SHORT[weekdayOf(t)]} ${dayMonth(t)}`);
    }
    return out;
  }
  if (grain === "week") {
    // Calendar weeks (Monday first); the first one may start before `from`
    // and is clipped to it when hours are summed.
    for (let t = shiftDays(startOfDay(from), -weekdayOf(from)); t <= to; t = shiftDays(t, 7)) {
      push(t, shiftDays(t, 7), dayMonth(t), `mg ${dayMonth(t)}`);
    }
    return out;
  }
  const first = new Date(from);
  const years = new Date(to).getFullYear() !== first.getFullYear();
  for (let t = new Date(first.getFullYear(), first.getMonth(), 1).getTime(); t <= to; t = shiftMonths(t, 1)) {
    const d = new Date(t);
    const label = years ? `${MONTHS[d.getMonth()]} ${String(d.getFullYear()).slice(2)}` : MONTHS[d.getMonth()];
    push(t, shiftMonths(t, 1), label, `${MONTHS[d.getMonth()]} ${d.getFullYear()}`);
  }
  return out;
};

/**
 * Everything the Riwayat charts show, for one period.
 * `from` is the period's first midnight, or null for "Semua waktu" (the
 * earliest session then starts the window).
 */
export const analyse = (
  spansIn: SessionSpan[],
  period: Period,
  periodFrom: number | null,
  now: number,
  devices: Device[] | null,
): Analysis => {
  const spans = spansIn.filter((s) => !Number.isNaN(spanStart(s)));
  const earliest = spans.reduce((min, s) => Math.min(min, spanStart(s)), now);
  const from = periodFrom ?? startOfDay(earliest);
  const to = now;
  const grain = grainFor(period, from, to);
  const trend = buildBuckets(grain, from, to, now);

  // ---- Stations: the registry first, so a station nobody used still shows ----
  const stations = new Map<string, Ranked>();
  for (const d of devices ?? []) {
    const key = d.hostname.toUpperCase();
    stations.set(key, { key: d.hostname, label: splitDeviceName(d.display_name || d.hostname).id, hours: 0, sessions: 0 });
  }
  const purposes = new Map<string, Ranked>();
  const access = new Map<AccessType, number>();
  const closed: number[] = [];
  const durationCounts = DURATION_BINS.map(() => 0);

  // [weekday][hour] station-hours in use, and how many hours of each slot the
  // window actually contains -- their ratio is "stations in use on average".
  const busy = Array.from({ length: 7 }, () => new Array<number>(24).fill(0));
  const slots = Array.from({ length: 7 }, () => new Array<number>(24).fill(0));
  const occupied = new Map<string, [number, number][]>();

  let totalMs = 0;
  let runningCount = 0;
  let runningMs = 0;
  let autoClosedCount = 0;
  let cappedCount = 0;
  let observedMs = 0;

  for (const s of spans) {
    const s0 = Math.max(spanStart(s), from);
    const s1 = Math.min(spanEnd(s, now), to);
    const ms = Math.max(0, s1 - s0);
    // The fetch starts a day early (see leadInDate): a session that began
    // before the period but ran into it is clipped at the edge and counts
    // toward HOURS only -- as a session it belongs to the period it began in.
    const isCarried = spanStart(s) < from;
    if (isCarried && ms <= 0) continue;
    const seconds = s.duration_seconds;
    const hostKey = (s.hostname || "-").toUpperCase();
    const station = stations.get(hostKey) ?? { key: s.hostname || "-", label: s.hostname || "-", hours: 0, sessions: 0 };
    stations.set(hostKey, station);
    const purposeLabel = (s.tujuan || "").trim() || "Tanpa tujuan";
    const purposeKey = purposeLabel.toLowerCase();
    const purpose = purposes.get(purposeKey) ?? { key: purposeKey, label: purposeLabel, hours: 0, sessions: 0 };
    purposes.set(purposeKey, purpose);

    // ---- Hours ----
    totalMs += ms;
    if (seconds === null) runningMs += ms;
    else if (s.auto_closed !== true && s.duration_capped !== true) observedMs += ms;
    purpose.hours += ms / HOUR_MS;
    // Station hours come from the merged intervals below, not from this sum:
    // two overlapping sessions on one machine are one machine in use.
    for (const b of trend) {
      if (b.end <= s0 || b.start >= s1) continue;
      b.value += overlapMs(s0, s1, Math.max(b.start, from), Math.min(b.end, to)) / HOUR_MS;
    }
    if (ms > 0) {
      const list = occupied.get(hostKey) ?? [];
      list.push([s0, s1]);
      occupied.set(hostKey, list);
    }
    if (isCarried) continue;

    // ---- Sessions (only those that began in the period) ----
    if (seconds === null) {
      runningCount += 1;
    } else {
      closed.push(seconds);
      durationCounts[DURATION_BINS.findIndex((b) => seconds < b.below)] += 1;
    }
    if (s.auto_closed === true) autoClosedCount += 1;
    if (s.duration_capped === true) cappedCount += 1;
    station.sessions += 1;
    purpose.sessions += 1;
    const type = resolveAccessType(s.session_type);
    access.set(type, (access.get(type) ?? 0) + 1);
  }

  // Occupancy counts machines, not sessions: an SSH login beside the person at
  // the keyboard, or a crashed client's START left open under a new one, is
  // still one busy station. So each station's spans are merged first, then
  // walked one clock hour at a time.
  const walk = (a: number, b: number) => {
    for (let t = a; t < b; ) {
      const d = new Date(t);
      const next = new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours() + 1).getTime();
      busy[weekdayOf(t)][d.getHours()] += (Math.min(next, b) - t) / HOUR_MS;
      t = next;
    }
  };
  for (const [hostKey, list] of occupied) {
    list.sort((x, y) => x[0] - y[0]);
    let [a, b] = list[0];
    let mergedMs = 0;
    for (const [c, d] of list) {
      if (c > b) {
        walk(a, b);
        mergedMs += b - a;
        a = c;
      }
      b = Math.max(b, d);
    }
    walk(a, b);
    mergedMs += b - a;
    const station = stations.get(hostKey);
    if (station) station.hours = mergedMs / HOUR_MS;
  }

  for (const b of trend) b.tag = `${b.tag} · ${b.isFuture ? "belum" : hoursText(b.value)}`;

  for (let t = startOfDay(from); t < to; t = shiftDays(t, 1)) {
    const d = new Date(t);
    const wd = weekdayOf(t);
    for (let h = 0; h < 24; h += 1) {
      const a = new Date(d.getFullYear(), d.getMonth(), d.getDate(), h).getTime();
      const b = new Date(d.getFullYear(), d.getMonth(), d.getDate(), h + 1).getTime();
      slots[wd][h] += overlapMs(a, b, from, to) / HOUR_MS;
    }
  }

  const cells = busy.map((row, wd) => row.map((v, h) => (slots[wd][h] > 0 ? v / slots[wd][h] : null)));
  let max = 0;
  let peak: HeatMap["peak"] = null;
  let minHour = 24;
  let maxHour = -1;
  cells.forEach((row, day) =>
    row.forEach((v, hour) => {
      if (v === null || v <= 0) return;
      minHour = Math.min(minHour, hour);
      maxHour = Math.max(maxHour, hour);
      if (v > max) {
        max = v;
        peak = { day, hour, value: v };
      }
    }),
  );
  const mode = durationCounts.reduce((best, c, i) => (c > durationCounts[best] ? i : best), 0);

  // How many buckets' worth of time the window has covered: the current
  // bucket, and a first one that starts before `from`, count only in part.
  const elapsedBuckets = trend.reduce((sum, b) => sum + overlapMs(b.start, b.end, from, to) / (b.end - b.start), 0);
  const sortRanked = (a: Ranked, b: Ranked) =>
    b.hours - a.hours || b.sessions - a.sessions || a.label.localeCompare(b.label, "id", { numeric: true });
  const sortedClosed = [...closed].sort((a, b) => a - b);
  const mid = sortedClosed.length >> 1;

  return {
    grain,
    trend,
    trendAverage: elapsedBuckets > 0 ? totalMs / HOUR_MS / elapsedBuckets : 0,
    totalHours: totalMs / HOUR_MS,
    runningCount,
    runningHours: runningMs / HOUR_MS,
    autoClosedCount,
    cappedCount,
    observedHours: observedMs / HOUR_MS,
    stations: [...stations.values()].sort(sortRanked),
    stationCount: Math.max(devices?.length ?? 0, new Set(spans.map((s) => (s.hostname || "-").toUpperCase())).size),
    purposes: [...purposes.values()].sort(sortRanked),
    access: [...access.entries()]
      .map(([type, count]) => ({ type, label: ACCESS_LABEL[type], count }))
      .sort((a, b) => b.count - a.count),
    durations: DURATION_BINS.map((b, i) => ({
      key: b.key,
      label: b.label,
      tag: `${b.label} · ${durationCounts[i]} sesi`,
      value: durationCounts[i],
      isLead: i === mode && durationCounts[i] > 0,
      isFuture: false,
    })),
    medianSeconds: sortedClosed.length
      ? sortedClosed.length % 2
        ? sortedClosed[mid]
        : (sortedClosed[mid - 1] + sortedClosed[mid]) / 2
      : null,
    maxSeconds: sortedClosed.length ? sortedClosed[sortedClosed.length - 1] : null,
    heat: {
      hourFrom: maxHour < 0 ? 7 : Math.min(7, minHour),
      hourTo: maxHour < 0 ? 18 : Math.max(18, maxHour),
      cells,
      max,
      peak,
    },
  };
};
