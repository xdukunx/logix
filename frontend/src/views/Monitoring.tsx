// Monitoring -- the dashboard's home. v4 "Denyut".
//
// A bento row answers the three questions an admin opens this page with --
// how full is the lab, how much has it been used, is every machine alive --
// then Pita Waktu shows today's sessions on one time axis, then the station
// grid. Every station card carries a live heartbeat trace: one spike per
// heartbeat the server actually received from that machine, so a flatline
// here is a machine that has genuinely gone quiet.
//
// Stations come from merging /api/devices (the enrolled registry, so "5 dari
// 8" has a real denominator) with /api/active (live heartbeats and sessions,
// polled every 3s because it is what drives the traces). Usage numbers and
// the timeline come from /api/sessions/spans for the last 7 days.
import { Fragment, useCallback, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";

import { getJson, sendJson } from "../api";
import { ACCESS_LABEL, STATUS_LABEL, categoryLabel, resolveAccessType, type StationStatus } from "../tokens";
import { BEAT_WINDOW_MS, DAY_MS, DAYS_SHORT, HOUR_MS, LAB_STATUS_LABEL, LAB_STATUSES, hoursLabel, overlapMs, spanEnd, spanStart, startOfDay, stationStatus, ymd } from "../lab";
import type { ActiveWorkstation, Device, SessionSpan } from "../types";
import { Card, EmptyState, ErrorState, Mono, PageHeader, SectionLabel, SkeletonGrid, StatusDot } from "../ui/base";
import { Button, TextArea } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { Modal, ModalActions, MoreMenu, SidePanel, useToast, type MenuItem } from "../ui/overlays";
import {
  BigNumber,
  CardTitle,
  Delta,
  EcgTrace,
  FleetDial,
  SegmentGauge,
  Timeline,
  WeekBars,
  type DayBar,
  type TimelineRow,
} from "../ui/viz";
import { durationSince, formatClock, formatDuration, formatSince, splitDeviceName, timeAgo, useTicker, usePolling } from "../util";

/** One enrolled station, after merging the registry with live heartbeats. */
interface Station {
  hostname: string;
  id: string;
  spec: string;
  status: StationStatus;
  live: ActiveWorkstation | null;
  lastSeen: string | null;
  anydeskId: string;
  device: Device;
}

const clock = (t: number) => formatClock(new Date(t).toISOString());

const LEGEND = LAB_STATUSES.map((status) => ({ status, label: LAB_STATUS_LABEL[status] }));

export default function Monitoring() {
  const toast = useToast();
  const breakpoint = useBreakpoint();
  const isPhone = breakpoint === "phone";
  const [devices, setDevices] = useState<Device[] | null>(null);
  const [active, setActive] = useState<ActiveWorkstation[]>([]);
  const [spans, setSpans] = useState<SessionSpan[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);

  // Heartbeats observed per station, as the times we SAW last_seen move.
  // The first reading of a station is not a beat -- we did not see it arrive.
  const beatsRef = useRef(new Map<string, number[]>());
  const lastSeenRef = useRef(new Map<string, string>());
  const [lastBeatAt, setLastBeatAt] = useState<number | null>(null);

  // The station whose detail panel is open (hostname), or null.
  const [detailHost, setDetailHost] = useState<string | null>(null);

  // Modal targets (null = closed).
  const [messageTarget, setMessageTarget] = useState<Station | null>(null);
  const [lockTarget, setLockTarget] = useState<Station | null>(null);
  const [shotTarget, setShotTarget] = useState<Station | null>(null);
  const [powerTarget, setPowerTarget] = useState<Station | null>(null);
  const [isBroadcastOpen, setBroadcastOpen] = useState(false);

  const [messageText, setMessageText] = useState("");
  const [shotReason, setShotReason] = useState("");
  const [broadcast, setBroadcast] = useState("");
  const [isAcknowledged, setAcknowledged] = useState(false);

  // Durations, the now-line and "x dtk lalu" are live: re-render once a second.
  useTicker(1000);

  const refreshRegistry = useCallback(async () => {
    try {
      setDevices(await getJson<Device[]>("/api/devices", "Gagal mengambil daftar perangkat"));
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    }
  }, []);

  const refreshLive = useCallback(async () => {
    try {
      const list = await getJson<ActiveWorkstation[]>("/api/active", "Gagal mengambil data stasiun aktif");
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
      setUpdatedAt(new Date().toISOString());
      if (sawBeat) setLastBeatAt(now);
    } catch (err) {
      setError((err as Error).message);
    }
  }, []);

  const refreshSpans = useCallback(async () => {
    try {
      const page = await getJson<{ sessions: SessionSpan[] }>(
        `/api/sessions/spans?start_date=${ymd(Date.now() - 6 * DAY_MS)}&limit=5000`,
        "Gagal mengambil riwayat sesi",
      );
      setSpans(page.sessions);
    } catch {
      // A role without sessions_read: the usage cards say so instead.
      setSpans((prev) => prev ?? []);
    }
  }, []);

  usePolling(refreshRegistry, 15000);
  usePolling(refreshLive, 3000);
  usePolling(refreshSpans, 60000);

  const refresh = () => {
    refreshRegistry();
    refreshLive();
    refreshSpans();
  };

  const stations = useMemo<Station[]>(() => {
    if (!devices) return [];
    const liveByHost = new Map(active.map((a) => [a.hostname, a]));
    return devices
      .map((d) => {
        const live = liveByHost.get(d.hostname) ?? null;
        const { id, spec } = splitDeviceName(d.display_name || live?.device_name || d.hostname);
        return {
          hostname: d.hostname,
          id,
          // A display_name with no " - <spec>" half leaves spec empty; falling
          // back to the raw category KEY printed "WS-01 - lab_workstation" at
          // a lab admin.
          spec: spec || categoryLabel(d.category),
          status: stationStatus(live),
          live,
          lastSeen: live?.last_seen ?? d.last_seen,
          anydeskId: live?.anydesk_id || "",
          device: d,
        };
      })
      .sort((a, b) => a.id.localeCompare(b.id, "id", { numeric: true }));
  }, [devices, active]);

  const count = (status: StationStatus) => stations.filter((s) => s.status === status).length;
  const inUse = count("active");
  const total = stations.length;
  const onlineCount = stations.filter((s) => s.status !== "offline").length;

  // ---- Usage, from the last 7 days of session spans ----
  const now = Date.now();
  const today0 = startOfDay(now);
  const usage = useMemo(() => {
    if (!spans) return null;
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
    // Yesterday only up to this same time of day: comparing a whole day with
    // a day that is half over would always read as a drop.
    const yesterdaySoFar = hoursIn(today0 - DAY_MS, now - DAY_MS);
    const todaySpans = spans.filter((s) => spanEnd(s, now) > today0);
    const people = new Set(todaySpans.map((s) => s.nim || s.nama || s.username).filter(Boolean));
    return {
      days,
      todayHours,
      delta: yesterdaySoFar > 0 ? ((todayHours - yesterdaySoFar) / yesterdaySoFar) * 100 : null,
      sessionsToday: todaySpans.length,
      peopleToday: people.size,
      todaySpans,
    };
    // `now` moves every second; the week only needs recomputing when data does.
  }, [spans, today0, Math.floor(now / 60000)]);

  // ---- Pita Waktu rows: stations with a session today or one open now ----
  const timeline = useMemo(() => {
    if (!usage) return null;
    const byHost = new Map<string, SessionSpan[]>();
    for (const s of usage.todaySpans) {
      const key = s.hostname.toUpperCase();
      byHost.set(key, [...(byHost.get(key) ?? []), s]);
    }
    const rows: TimelineRow[] = [];
    let earliest = now;
    for (const st of stations) {
      const own = byHost.get(st.hostname.toUpperCase()) ?? [];
      if (own.length === 0) continue;
      rows.push({
        hostname: st.hostname,
        id: st.id,
        spans: own.map((s) => {
          const start = Math.max(spanStart(s), today0);
          const end = spanEnd(s, now);
          earliest = Math.min(earliest, start);
          const who = s.nama || s.username || "Tanpa nama";
          const isLive = s.duration_seconds === null;
          const range = `${clock(start)}–${isLive ? "sekarang" : clock(end)}`;
          return {
            start,
            end,
            isLive,
            label: `${who} · ${s.tujuan || "-"} · ${range} (${formatDuration(Math.round((end - start) / 1000))})`,
          };
        }),
      });
    }
    const from = Math.min(today0 + 7 * HOUR_MS, earliest - (earliest % HOUR_MS));
    const to = Math.min(today0 + DAY_MS, Math.max(today0 + 18 * HOUR_MS, now + 2 * HOUR_MS - (now % HOUR_MS)));
    return { rows, from, to };
  }, [usage, stations, today0]);

  const act = async (fn: Promise<unknown>, success: string, done?: () => void) => {
    try {
      await fn;
      toast(success);
      done?.();
      refresh();
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  };

  const closeMessage = () => {
    setMessageTarget(null);
    setMessageText("");
  };
  const closeShot = () => {
    setShotTarget(null);
    setShotReason("");
  };
  const closeBroadcast = () => {
    setBroadcastOpen(false);
    setBroadcast("");
    setAcknowledged(false);
  };

  const menuFor = (s: Station): MenuItem[] => [
    { label: "Pesan", onClick: () => setMessageTarget(s) },
    { label: "Kunci", onClick: () => setLockTarget(s) },
    { label: "Cuplikan layar", onClick: () => setShotTarget(s) },
    { label: "Daya", onClick: () => setPowerTarget(s), isDanger: true, isDivided: true },
  ];

  /** The card's session line, per status. */
  const sessionLine = (s: Station) => {
    if (s.status === "offline") {
      return (
        <>
          Offline sejak <Mono>{formatSince(s.lastSeen)}</Mono>
        </>
      );
    }
    if (s.status === "locked") {
      return (
        <>
          Dikunci · <Mono>{formatClock(s.live?.status_since ?? s.lastSeen)}</Mono>
        </>
      );
    }
    if (s.status === "idle") {
      return (
        <>
          Bebas · idle <Mono>{durationSince(s.live?.status_since ?? s.lastSeen)}</Mono>
        </>
      );
    }
    const access = ACCESS_LABEL[resolveAccessType(s.live?.access_type)];
    // Only the NAME may be clipped: the duration is the number an admin is
    // scanning this board for, and a right-side ellipsis would eat it.
    return (
      <span style={{ display: "flex", minWidth: 0, alignItems: "baseline", gap: 6 }}>
        <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: "var(--lx-text)", fontWeight: 600 }}>
          {s.live?.username || "-"}
        </span>
        <span style={{ flexShrink: 0, whiteSpace: "nowrap" }}>
          · {access} ·{" "}
          <Mono>{s.live?.session_started_at ? durationSince(s.live.session_started_at) : "-"}</Mono>
        </span>
      </span>
    );
  };

  // A render FUNCTION, deliberately not a component defined during render:
  // as a component, its identity would change on every render (this view
  // re-renders every second) and React would remount every card, MoreMenu
  // included, closing any open action menu within a second.
  const renderStationCard = (s: Station, index: number) => {
    const isOffline = s.status === "offline";
    const purpose = s.status === "active" ? s.live?.purpose : null;
    return (
      <Card
        variant={isOffline ? "dashed" : "solid"}
        isInteractive
        padding={isPhone ? "14px 14px 10px" : "18px 18px 12px"}
        className="lx-rise"
        role="button"
        tabIndex={0}
        aria-label={`Detail ${s.id}`}
        onClick={() => setDetailHost(s.hostname)}
        onKeyDown={(e) => {
          // Only when the card itself has focus: Enter on the ⋯ button inside
          // it must open the menu, not the panel.
          if (e.target !== e.currentTarget) return;
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            setDetailHost(s.hostname);
          }
        }}
        style={{ "--i": index, cursor: "pointer" } as CSSProperties}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <StatusDot status={s.status} label={s.status} />
          <span
            className="lx-mono"
            style={{
              fontSize: 14,
              fontWeight: 700,
              whiteSpace: "nowrap",
              color: isOffline ? "var(--lx-status-offline)" : undefined,
            }}
          >
            {s.id}
          </span>
          {s.spec && !isPhone && (
            <span style={{ fontSize: 12, color: "var(--lx-muted)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", minWidth: 0 }}>
              {s.spec}
            </span>
          )}
          {/* Offline cards carry no actions at all. The wrapper keeps a click
              on the menu (or on an item in it -- React events bubble through
              the phone bottom-sheet portal too) from also opening the panel.
              Clicks only: stopping keydown here would also swallow the
              Escape that the menu listens for on the document. */}
          {!isOffline && (
            <span style={{ marginLeft: "auto", display: "flex" }} onClick={(e) => e.stopPropagation()}>
              <MoreMenu label={`Aksi untuk ${s.id}`} items={menuFor(s)} />
            </span>
          )}
        </div>
        <div
          style={{
            fontSize: 13,
            color: isOffline ? "var(--lx-status-offline)" : "var(--lx-muted)",
            margin: purpose ? "10px 0 2px" : "10px 0 6px",
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
            minWidth: 0,
          }}
        >
          {sessionLine(s)}
        </div>
        {purpose && (
          <div
            style={{
              fontSize: 12,
              color: "var(--lx-muted)",
              marginBottom: 4,
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
          >
            {purpose}
          </div>
        )}
        <EcgTrace beats={beatsRef.current.get(s.hostname) ?? []} isFlat={isOffline} windowMs={BEAT_WINDOW_MS} />
      </Card>
    );
  };

  // ---- Detail panel ----
  const detail = detailHost ? stations.find((s) => s.hostname === detailHost) ?? null : null;
  const detailBeats = detail ? beatsRef.current.get(detail.hostname) ?? [] : [];
  const detailSpans =
    detail && usage
      ? usage.todaySpans
          .filter((s) => s.hostname.toUpperCase() === detail.hostname.toUpperCase())
          .sort((a, b) => spanStart(b) - spanStart(a))
      : [];
  // An action picked from the panel closes it first: the panel dismisses on
  // any click outside it, which would include the modal the action opens.
  const fromDetail = (open: (s: Station) => void) => {
    if (!detail) return;
    setDetailHost(null);
    open(detail);
  };
  const detailRow = (label: string, value: ReactNode) => (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12 }}>
      <span style={{ color: "var(--lx-muted)" }}>{label}</span>
      <span style={{ textAlign: "right" }}>{value}</span>
    </div>
  );

  const bentoColumns = breakpoint === "desktop" ? "repeat(12, 1fr)" : breakpoint === "tablet" ? "1fr 1fr" : "1fr";
  const bentoSpan = (desktop: number, tablet: number) =>
    breakpoint === "desktop" ? `span ${desktop}` : breakpoint === "tablet" ? `span ${tablet}` : undefined;
  const beatAgo = lastBeatAt ? Math.max(0, Math.round((now - lastBeatAt) / 1000)) : null;

  return (
    <>
      <PageHeader
        title="Monitoring"
        summary={
          devices === null ? (
            "Memuat..."
          ) : (
            <>
              <Mono style={{ color: "var(--lx-text)" }}>{inUse}</Mono> dari <Mono>{total}</Mono> stasiun dipakai ·
              diperbarui {timeAgo(updatedAt)}
            </>
          )
        }
        action={
          <Button
            label={isPhone ? "Broadcast" : "Emergency broadcast"}
            variant="danger-outline"
            size="sm"
            onClick={() => setBroadcastOpen(true)}
          />
        }
      />

      {devices === null ? (
        <SkeletonGrid count={8} columns={isPhone ? 1 : 4} />
      ) : error && stations.length === 0 ? (
        <ErrorState description={error} onRetry={refresh} />
      ) : stations.length === 0 ? (
        <EmptyState
          title="Belum ada perangkat terdaftar"
          description="Daftarkan workstation lewat tab Perangkat untuk mulai memantau."
        />
      ) : (
        <div style={{ display: "grid", gap: isPhone ? 10 : 16 }}>
          {/* ---- Bento ---- */}
          <div style={{ display: "grid", gridTemplateColumns: bentoColumns, gap: isPhone ? 10 : 16 }}>
            <Card padding="20px 22px 22px" className="lx-rise" style={{ gridColumn: bentoSpan(4, 1), "--i": 0 } as CSSProperties}>
              <CardTitle>Stasiun dipakai</CardTitle>
              <SegmentGauge segments={stations.map((s) => s.status)}>
                <BigNumber value={inUse} size={50} suffix={`/${total}`} />
                <div style={{ fontSize: 12, color: "var(--lx-muted)", marginTop: 6 }}>stasiun sedang dipakai</div>
              </SegmentGauge>
              <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", gap: "6px 14px", marginTop: 16 }}>
                {LEGEND.map((l) => (
                  <span key={l.status} style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 12, color: "var(--lx-muted)" }}>
                    <StatusDot status={l.status} />
                    {l.label} <Mono style={{ color: "var(--lx-text)" }}>{count(l.status)}</Mono>
                  </span>
                ))}
              </div>
            </Card>

            <Card padding="20px 22px 22px" className="lx-rise" style={{ gridColumn: bentoSpan(5, 2), "--i": 1 } as CSSProperties}>
              <CardTitle>Jam pakai hari ini</CardTitle>
              {usage ? (
                <>
                  <div style={{ display: "flex", alignItems: "flex-end", gap: 14, flexWrap: "wrap", marginBottom: 18 }}>
                    <BigNumber value={usage.todayHours} decimals={1} size={50} suffix="jam" />
                    <Delta percent={usage.delta} caption="vs kemarin di jam yang sama" />
                  </div>
                  <WeekBars days={usage.days} height={isPhone ? 130 : 150} />
                  <div style={{ display: "flex", gap: 18, marginTop: 14, fontSize: 12.5, color: "var(--lx-muted)" }}>
                    <span>
                      <Mono style={{ color: "var(--lx-text)" }}>{usage.sessionsToday}</Mono> sesi
                    </span>
                    <span>
                      <Mono style={{ color: "var(--lx-text)" }}>{usage.peopleToday}</Mono> pengguna
                    </span>
                  </div>
                </>
              ) : (
                <div style={{ fontSize: 13, color: "var(--lx-muted)" }}>Memuat riwayat sesi...</div>
              )}
            </Card>

            <Card
              padding="20px 22px 22px"
              className="lx-rise"
              style={{ gridColumn: bentoSpan(3, 1), "--i": 2, display: "flex", flexDirection: "column" } as CSSProperties}
            >
              <CardTitle>Denyut jaringan</CardTitle>
              <div style={{ flex: 1, display: "flex", alignItems: "center" }}>
                <FleetDial
                  dots={stations.map((s) => {
                    const beats = beatsRef.current.get(s.hostname) ?? [];
                    return {
                      hostname: s.id,
                      isOnline: s.status !== "offline",
                      beatKey: beats.length ? String(beats[beats.length - 1]) : "",
                    };
                  })}
                >
                  <BigNumber value={onlineCount} size={44} />
                  <div style={{ fontSize: 11.5, opacity: 0.7, marginTop: 4 }}>online dari {total}</div>
                </FleetDial>
              </div>
              <div style={{ textAlign: "center", fontSize: 12, color: "var(--lx-muted)", marginTop: 14 }}>
                {beatAgo === null ? "menunggu denyut..." : (
                  <>
                    denyut terakhir <Mono style={{ color: "var(--lx-text)" }}>{beatAgo}</Mono> dtk lalu
                  </>
                )}
              </div>
            </Card>
          </div>

          {/* ---- Pita Waktu ---- */}
          <Card padding={isPhone ? "18px 14px" : "20px 24px 24px"} className="lx-rise" style={{ "--i": 3 } as CSSProperties}>
            <CardTitle
              action={
                <span style={{ display: "inline-flex", gap: 14, fontSize: 12, color: "var(--lx-muted)" }}>
                  <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                    <span style={{ width: 14, height: 8, borderRadius: 99, background: "var(--lx-accent)" }} /> berjalan
                  </span>
                  <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                    <span style={{ width: 14, height: 8, borderRadius: 99, background: "var(--lx-ink)" }} /> selesai
                  </span>
                </span>
              }
            >
              Pita waktu hari ini
            </CardTitle>
            {!timeline ? (
              <div style={{ fontSize: 13, color: "var(--lx-muted)" }}>Memuat...</div>
            ) : timeline.rows.length === 0 ? (
              <div style={{ fontSize: 13, color: "var(--lx-muted)", padding: "10px 0" }}>Belum ada sesi hari ini.</div>
            ) : (
              <div style={{ overflowX: isPhone ? "auto" : "visible" }}>
                <div style={{ minWidth: isPhone ? 560 : undefined, paddingTop: 14 }}>
                  <Timeline rows={timeline.rows} from={timeline.from} to={timeline.to} now={now} />
                </div>
              </div>
            )}
          </Card>

          {/* ---- Stations ---- */}
          <div
            style={{
              display: "grid",
              gap: isPhone ? 10 : 16,
              gridTemplateColumns: isPhone ? "1fr" : "repeat(auto-fill, minmax(clamp(230px, 24%, 320px), 1fr))",
            }}
          >
            {stations.map((s, i) => (
              <Fragment key={s.hostname}>{renderStationCard(s, i + 4)}</Fragment>
            ))}
          </div>
        </div>
      )}

      {/* ---- Station detail ---- */}
      <SidePanel
        isOpen={detail !== null}
        onClose={() => setDetailHost(null)}
        label={`Detail ${detail?.id ?? ""}`}
        header={
          detail && (
            <>
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <StatusDot status={detail.status} label={STATUS_LABEL[detail.status]} />
                <Mono style={{ fontSize: 20, fontWeight: 700 }}>{detail.id}</Mono>
              </div>
              <div style={{ fontSize: 12.5, color: "var(--lx-muted)", marginTop: 4 }}>
                {detail.spec} · <Mono>{detail.hostname}</Mono>
              </div>
            </>
          )
        }
      >
        {detail && (
          <div style={{ display: "grid", gap: 22 }}>
            <section>
              <SectionLabel>Sekarang</SectionLabel>
              <div style={{ marginTop: 8, background: "var(--lx-sunken)", borderRadius: 18, padding: "14px 16px" }}>
                {detail.status === "active" ? (
                  <>
                    <div style={{ fontSize: 17, fontWeight: 650 }}>{detail.live?.username || "-"}</div>
                    <div style={{ fontSize: 13, color: "var(--lx-muted)", marginTop: 2 }}>{detail.live?.purpose || "Tanpa tujuan"}</div>
                    <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginTop: 10, flexWrap: "wrap" }}>
                      <span className="lx-big lx-mono" style={{ fontSize: 30 }}>
                        {detail.live?.session_started_at ? durationSince(detail.live.session_started_at) : "-"}
                      </span>
                      <span style={{ fontSize: 12.5, color: "var(--lx-muted)" }}>
                        {ACCESS_LABEL[resolveAccessType(detail.live?.access_type)]} · mulai{" "}
                        <Mono>{formatClock(detail.live?.session_started_at)}</Mono>
                      </span>
                    </div>
                  </>
                ) : (
                  <div style={{ fontSize: 13.5, color: "var(--lx-muted)" }}>{sessionLine(detail)}</div>
                )}
              </div>
            </section>

            <section>
              <SectionLabel>Denyut</SectionLabel>
              <div style={{ marginTop: 8 }}>
                <EcgTrace beats={detailBeats} isFlat={detail.status === "offline"} windowMs={BEAT_WINDOW_MS} />
              </div>
              <div style={{ fontSize: 12.5, color: "var(--lx-muted)", marginTop: 6 }}>
                <Mono style={{ color: "var(--lx-text)" }}>{detailBeats.length}</Mono> denyut/menit · terakhir terlihat{" "}
                {timeAgo(detail.lastSeen)}
              </div>
            </section>

            <section style={{ display: "grid", gap: 9, fontSize: 13 }}>
              {detailRow(
                "ID AnyDesk",
                detail.anydeskId ? (
                  <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
                    <Mono style={{ userSelect: "all" }}>{detail.anydeskId}</Mono>
                    {typeof navigator !== "undefined" && navigator.clipboard && (
                      <Button
                        label="Salin"
                        variant="ghost"
                        size="sm"
                        style={{ padding: "4px 10px" }}
                        onClick={() =>
                          navigator.clipboard
                            .writeText(detail.anydeskId)
                            .then(() => toast("ID AnyDesk disalin."))
                            .catch(() => toast("Gagal menyalin.", "alert"))
                        }
                      />
                    )}
                  </span>
                ) : (
                  "-"
                ),
              )}
              {detailRow("Versi agent", <Mono>{String(detail.device.agent_version ?? "-")}</Mono>)}
              {detailRow("Kategori", categoryLabel(detail.device.category))}
              {detailRow("Terdaftar", <Mono>{formatSince(String(detail.device.enrolled_at ?? "") || null)}</Mono>)}
              {typeof detail.device.clock_skew_seconds === "number" && Math.abs(detail.device.clock_skew_seconds) > 120 && (
                <div
                  style={{
                    borderLeft: "3px solid var(--lx-status-locked)",
                    background: "var(--lx-sunken)",
                    borderRadius: "0 10px 10px 0",
                    padding: "8px 12px",
                    fontSize: 12.5,
                    lineHeight: 1.5,
                  }}
                >
                  Jam perangkat ini selisih <Mono>{Math.round(Math.abs(detail.device.clock_skew_seconds) / 60)}</Mono> menit dari
                  server, jadi jam sesi yang dicatatnya ikut bergeser.
                </div>
              )}
            </section>

            <section>
              <SectionLabel>Sesi hari ini · {detailSpans.length}</SectionLabel>
              {detailSpans.length === 0 ? (
                <div style={{ fontSize: 13, color: "var(--lx-muted)", marginTop: 8 }}>Belum ada sesi hari ini.</div>
              ) : (
                <div style={{ display: "grid", marginTop: 6 }}>
                  {detailSpans.map((s) => {
                    const start = spanStart(s);
                    const isLive = s.duration_seconds === null;
                    const end = spanEnd(s, now);
                    return (
                      <div
                        key={s.session_id}
                        style={{
                          display: "grid",
                          gridTemplateColumns: "92px 1fr auto",
                          gap: 10,
                          alignItems: "baseline",
                          padding: "8px 0",
                          borderTop: "1px solid var(--lx-hairline)",
                          fontSize: 13,
                        }}
                      >
                        <Mono style={{ color: "var(--lx-muted)", fontSize: 12 }}>
                          {clock(start)}–{isLive ? "..." : clock(end)}
                        </Mono>
                        <span style={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                          <span style={{ fontWeight: 600 }}>{s.nama || s.username || "Tanpa nama"}</span>
                          <span style={{ color: "var(--lx-muted)" }}> · {s.tujuan || "-"}</span>
                        </span>
                        <Mono style={{ fontSize: 12, color: isLive ? "var(--lx-accent-text)" : "var(--lx-muted)" }}>
                          {isLive ? "berjalan" : formatDuration(Math.round((end - start) / 1000))}
                        </Mono>
                      </div>
                    );
                  })}
                </div>
              )}
            </section>

            {detail.status !== "offline" && (
              <section style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
                <Button label="Pesan" variant="primary" onClick={() => fromDetail(setMessageTarget)} />
                <Button label="Kunci" onClick={() => fromDetail(setLockTarget)} />
                <Button label="Cuplikan layar" onClick={() => fromDetail(setShotTarget)} />
                <Button label="Daya" variant="danger-outline" onClick={() => fromDetail(setPowerTarget)} />
              </section>
            )}
          </div>
        )}
      </SidePanel>

      {/* ---- Pesan ---- */}
      <Modal
        isOpen={messageTarget !== null}
        onClose={closeMessage}
        title={`Kirim pesan ke ${messageTarget?.id ?? ""}`}
        description={
          messageTarget?.live?.username
            ? `Pesan muncul di widget timer ${messageTarget.live.username}. Balasannya kembali ke sini.`
            : "Pesan muncul di widget timer pengguna."
        }
        footer={
          <ModalActions
            onCancel={closeMessage}
            confirmLabel="Kirim pesan"
            isConfirmDisabled={messageText.trim().length === 0}
            onConfirm={() =>
              act(
                sendJson(
                  "/api/control/broadcast",
                  "POST",
                  { hostname: messageTarget!.hostname, param: messageText.trim(), reason: "Direction Message" },
                  "Gagal mengirim pesan",
                ),
                `Pesan terkirim ke ${messageTarget!.id}`,
                closeMessage,
              )
            }
          />
        }
      >
        <TextArea
          label="Pesan"
          value={messageText}
          onChange={setMessageText}
          placeholder="Contoh: Lab tutup 17:00. Simpan pekerjaan sebelum pulang ya."
          maxLength={280}
          rows={3}
        />
      </Modal>

      {/* ---- Kunci ---- */}
      <Modal
        isOpen={lockTarget !== null}
        onClose={() => setLockTarget(null)}
        title={`Kunci ${lockTarget?.id ?? ""}?`}
        description={`Sesi ${lockTarget?.live?.username || "pengguna"} akan dijeda. Layar terkunci sampai admin membuka kembali.`}
        footer={
          <ModalActions
            onCancel={() => setLockTarget(null)}
            confirmLabel="Kunci"
            onConfirm={() =>
              act(
                sendJson(
                  "/api/control/lock",
                  "POST",
                  { hostname: lockTarget!.hostname },
                  "Gagal mengirim perintah kunci",
                ),
                `Perintah kunci dikirim ke ${lockTarget!.id}`,
                () => setLockTarget(null),
              )
            }
          />
        }
      />

      {/* ---- Cuplikan layar: privacy notice is visible, never behind a link ---- */}
      <Modal
        isOpen={shotTarget !== null}
        onClose={closeShot}
        title={`Ambil cuplikan layar ${shotTarget?.id ?? ""}?`}
        description={`Satu cuplikan diambil dari sesi ${shotTarget?.live?.username || "pengguna"} dan disimpan ke log audit.`}
        footer={
          <ModalActions
            onCancel={closeShot}
            confirmLabel="Ambil cuplikan"
            onConfirm={() =>
              act(
                sendJson(
                  "/api/control/screenshot",
                  "POST",
                  { hostname: shotTarget!.hostname, reason: shotReason.trim() || "Pemantauan rutin" },
                  "Gagal meminta cuplikan",
                ),
                `Permintaan cuplikan dikirim ke ${shotTarget!.id}. Hasilnya muncul di Perangkat.`,
                closeShot,
              )
            }
          />
        }
      >
        <div style={{ display: "grid", gap: 14 }}>
          <TextArea
            label="Alasan"
            value={shotReason}
            onChange={setShotReason}
            placeholder="Contoh: Verifikasi keluhan lag"
            rows={2}
            maxLength={140}
          />
          <div
            style={{
              borderLeft: "3px solid var(--lx-accent)",
              padding: "8px 14px",
              fontSize: 12.5,
              lineHeight: 1.5,
              background: "var(--lx-sunken)",
              borderRadius: "0 10px 10px 0",
            }}
          >
            Catatan privasi: pengguna <strong>selalu diberi tahu</strong> saat cuplikan diambil. Tidak ada
            pengambilan diam-diam.
          </div>
        </div>
      </Modal>

      {/* ---- Daya ---- */}
      <Modal
        isOpen={powerTarget !== null}
        onClose={() => setPowerTarget(null)}
        title={`Daya ${powerTarget?.id ?? ""}`}
        description="Pengguna menerima peringatan 30 detik sebelum perangkat dimatikan atau dimulai ulang."
        accentEdge="alert"
        footer={<Button label="Batal" variant="secondary" size="sm" onClick={() => setPowerTarget(null)} />}
      >
        <div style={{ display: "grid", gap: 8 }}>
          {(
            [
              ["logoff", "Log off pengguna"],
              ["restart", "Mulai ulang"],
              ["shutdown", "Matikan"],
            ] as const
          ).map(([action, label]) => (
            <Button
              key={action}
              label={label}
              variant="secondary"
              isFullWidth
              onClick={() =>
                act(
                  sendJson(
                    "/api/control/power",
                    "POST",
                    { hostname: powerTarget!.hostname, action, reason: `Aksi daya dari Monitoring: ${action}` },
                    "Gagal mengirim perintah daya",
                  ),
                  `Perintah ${label.toLowerCase()} dikirim ke ${powerTarget!.id}`,
                  () => setPowerTarget(null),
                )
              }
            />
          ))}
        </div>
      </Modal>

      {/* ---- Emergency broadcast ---- */}
      <Modal
        isOpen={isBroadcastOpen}
        onClose={closeBroadcast}
        title={`Emergency broadcast ke ${onlineCount} stasiun`}
        description="Pesan tampil sebagai overlay penuh di semua stasiun online — termasuk yang sedang fullscreen."
        accentEdge="alert"
        footer={
          <ModalActions
            onCancel={closeBroadcast}
            confirmLabel="Kirim broadcast"
            variant="danger"
            isConfirmDisabled={!isAcknowledged || broadcast.trim().length === 0 || onlineCount === 0}
            onConfirm={() =>
              act(
                sendJson(
                  "/api/control/broadcast",
                  "POST",
                  { hostname: "ALL", param: broadcast.trim(), reason: "Emergency Alert" },
                  "Gagal mengirim broadcast",
                ),
                "Siaran darurat dikirim ke semua stasiun online.",
                closeBroadcast,
              )
            }
          />
        }
      >
        <div style={{ display: "grid", gap: 14 }}>
          <TextArea
            label="Pesan broadcast"
            value={broadcast}
            onChange={setBroadcast}
            placeholder="Contoh: Evakuasi: alarm kebakaran gedung C. Simpan pekerjaan sekarang."
            rows={3}
            maxLength={280}
          />
          <label style={{ display: "flex", alignItems: "center", gap: 9, fontSize: 13, cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={isAcknowledged}
              onChange={(e) => setAcknowledged(e.target.checked)}
              style={{ width: 16, height: 16, accentColor: "var(--lx-status-alert)", flexShrink: 0 }}
            />
            Saya paham ini menginterupsi semua sesi aktif
          </label>
        </div>
      </Modal>
    </>
  );
}
