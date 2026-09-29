// Active-alert surface, polled every 30s regardless of the visible tab and
// every 10s while the modal is open, so ages and states stay current. The
// chrome control renders nothing at all when there is nothing to report.
//
// v4: the modal leads with the count and the severity mix on an ink block --
// its chips double as filters -- then lists the alerts worst first, each with
// how long it has been going on. Riwayat shows what already resolved:
// condition alerts (offline, stale, clock skew) resolve themselves once the
// station recovers, so without it an outage that ended before the admin
// looked would leave no trace here at all.
import { useCallback, useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";

import { getJson, postEmpty } from "../api";
import type { Alert } from "../types";
import { statusColor, type StationStatus } from "../tokens";
import { Mono, StatusDot } from "../ui/base";
import { Button, PillTabs } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { Modal, useToast } from "../ui/overlays";
import { BigNumber } from "../ui/viz";
import { durationSince, formatClock, formatDuration, formatLogTime, splitDeviceName, usePolling } from "../util";

/** The API row carries more than the shared Alert type names; only these are read. */
type AlertRow = Alert & {
  category?: string;
  device_name?: string | null;
  acknowledged_at?: string | null;
  resolved_at?: string | null;
};

type Severity = Alert["severity"];

const SEVERITY_STATUS: Record<Severity, StationStatus> = {
  info: "idle",
  warning: "locked",
  critical: "alert",
};

const SEVERITY_LABEL: Record<Severity, string> = {
  critical: "Kritis",
  warning: "Peringatan",
  info: "Info",
};

const SEVERITY_ORDER: Severity[] = ["critical", "warning", "info"];
const rank = (s: Severity) => SEVERITY_ORDER.indexOf(s);

// Condition alerts mirror live state: the server resolves them itself when
// the station recovers, and raises a fresh one if an admin resolves it while
// the condition still holds. Events (a failed or expired command) only ever
// close by hand. The admin needs to know which kind they are looking at.
const CATEGORY: Record<string, { label: string; isCondition: boolean }> = {
  device_offline: { label: "Offline", isCondition: true },
  device_stale: { label: "Heartbeat terlambat", isCondition: true },
  clock_skew: { label: "Jam tidak sinkron", isCondition: true },
  action_failed: { label: "Perintah gagal", isCondition: false },
  command_expired: { label: "Perintah kedaluwarsa", isCondition: false },
};

const HISTORY_LIMIT = 30;
// Far above what a lab keeps open, so the severity and "belum ditandai" counts
// are read from the whole active set rather than one page of it.
const ACTIVE_LIMIT = 500;

// ---------------------------------------------------------------------------
// The chrome control. Exported for RepliesInbox, so the two controls in the
// frame stay one set: a full-width row in the desktop sidebar, a pill in the
// tablet top bar, icon and count only in the cramped phone header.

type TriggerTone = "alert" | "accent" | "quiet";

const TONE: Record<TriggerTone, CSSProperties> = {
  // Dark text on the red tag: the frame colour, since this only ever sits in
  // the frame, and it holds its contrast in both themes where white does not.
  alert: { background: "var(--lx-status-alert)", color: "var(--lx-frame)" },
  accent: { background: "var(--lx-accent)", color: "var(--lx-on-accent)" },
  quiet: { background: "transparent", color: "var(--lx-muted)" },
};

export const FrameTrigger = ({
  icon,
  label,
  count,
  tone,
  ariaLabel,
  onClick,
}: {
  icon: ReactNode;
  label: string;
  count: number;
  tone: TriggerTone;
  ariaLabel: string;
  onClick: () => void;
}) => {
  const breakpoint = useBreakpoint();
  const isRow = breakpoint === "desktop";
  const isIconOnly = breakpoint === "phone";
  return (
    <button
      type="button"
      className="lx-tap"
      aria-label={ariaLabel}
      title={isIconOnly ? ariaLabel : undefined}
      onClick={onClick}
      style={{
        font: "inherit",
        display: "inline-flex",
        alignItems: "center",
        gap: 9,
        width: isRow ? "100%" : undefined,
        padding: isRow ? "7px 7px 7px 12px" : isIconOnly ? "4px 4px 4px 9px" : "4px 4px 4px 11px",
        borderRadius: isRow ? 14 : "var(--lx-radius-pill)",
        border: "none",
        background: "var(--lx-card)",
        color: "var(--lx-text)",
        fontSize: isRow ? 13 : 12.5,
        fontWeight: 550,
        cursor: "pointer",
      }}
    >
      <svg
        width="16"
        height="16"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        style={{ color: "var(--lx-muted)", flexShrink: 0 }}
      >
        {icon}
      </svg>
      {!isIconOnly && <span style={{ whiteSpace: "nowrap" }}>{label}</span>}
      {/* Keyed on the count so a new alert or message pops the tag once. */}
      <span
        key={count}
        className="lx-mono lx-anim-dot"
        style={{
          marginLeft: isRow ? "auto" : undefined,
          minWidth: 22,
          height: 22,
          padding: "0 7px",
          borderRadius: "var(--lx-radius-pill)",
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: 11.5,
          fontWeight: 700,
          ...TONE[tone],
        }}
      >
        {count}
      </span>
    </button>
  );
};

const BELL = (
  <>
    <path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z" />
    <path d="M10 20.5a2.1 2.1 0 0 0 4 0" />
  </>
);

// ---------------------------------------------------------------------------

const SeverityTag = ({ severity }: { severity: Severity }) => (
  <span
    style={{
      display: "inline-flex",
      alignItems: "center",
      gap: 6,
      padding: "3px 10px 3px 8px",
      borderRadius: "var(--lx-radius-pill)",
      background: "var(--lx-ink)",
      color: "var(--lx-on-ink)",
      fontSize: 11,
      fontWeight: 650,
      whiteSpace: "nowrap",
    }}
  >
    <StatusDot status={SEVERITY_STATUS[severity] ?? "idle"} />
    {SEVERITY_LABEL[severity] ?? severity}
  </span>
);

/** The station an alert is about, from the device name the server stored with it. */
const stationOf = (a: AlertRow) => (a.device_name ? splitDeviceName(a.device_name).id : null);

const AlertItem = ({
  alert: a,
  index,
  busy,
  rowRef,
  onAcknowledge,
  onResolve,
}: {
  alert: AlertRow;
  index: number;
  busy?: "ack" | "resolve";
  rowRef: (el: HTMLDivElement | null) => void;
  onAcknowledge: () => void;
  onResolve: () => void;
}) => {
  const isAcknowledged = a.status === "acknowledged";
  const category = a.category ? CATEGORY[a.category] : undefined;
  const station = stationOf(a);
  return (
    <div
      ref={rowRef}
      className="lx-rise"
      style={
        {
          "--i": index,
          display: "grid",
          gap: 6,
          padding: "14px 16px",
          borderRadius: 18,
          // Acknowledged alerts step back from a solid card to a dashed outline,
          // as an offline station does on Monitoring: still open, but no longer
          // asking for the admin's attention.
          background: isAcknowledged ? "transparent" : "var(--lx-card)",
          border: isAcknowledged ? "1px dashed var(--lx-border-dashed)" : "1px solid var(--lx-border)",
        } as CSSProperties
      }
    >
      <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
        <SeverityTag severity={a.severity} />
        {station && <Mono style={{ fontSize: 12.5, fontWeight: 700, whiteSpace: "nowrap" }}>{station}</Mono>}
        {category && (
          <span style={{ fontSize: 12, color: "var(--lx-muted)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            {category.label}
          </span>
        )}
        <span style={{ marginLeft: "auto", flexShrink: 0, textAlign: "right", lineHeight: 1.2 }}>
          <Mono style={{ fontSize: 13, fontWeight: 650 }}>{durationSince(a.created_at)}</Mono>
          <span style={{ display: "block", fontSize: 10.5, color: "var(--lx-muted)" }}>
            {category?.isCondition ? "berlangsung" : "lalu"}
          </span>
        </span>
      </div>
      <div style={{ fontSize: 14, fontWeight: 600, lineHeight: 1.4 }}>{a.title}</div>
      <div style={{ fontSize: 12.5, color: "var(--lx-muted)", lineHeight: 1.5 }}>{a.message}</div>
      <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", marginTop: 4 }}>
        <div style={{ display: "grid", gap: 2, minWidth: 0 }}>
          <Mono style={{ fontSize: 11, color: "var(--lx-muted)" }}>
            {formatLogTime(a.created_at)}
            {isAcknowledged ? ` · diketahui${a.acknowledged_at ? ` ${formatClock(a.acknowledged_at)}` : ""}` : ""}
          </Mono>
          {category?.isCondition && (
            <span style={{ fontSize: 11.5, color: "var(--lx-muted)" }}>Selesai otomatis saat stasiun pulih.</span>
          )}
        </div>
        <div style={{ display: "flex", gap: 6, marginLeft: "auto" }}>
          {!isAcknowledged && (
            <Button
              label={busy === "ack" ? "Menandai..." : "Tandai"}
              variant="secondary"
              size="sm"
              disabled={busy !== undefined}
              onClick={onAcknowledge}
            />
          )}
          <Button
            label={busy === "resolve" ? "Menyelesaikan..." : "Selesaikan"}
            variant="ghost"
            size="sm"
            disabled={busy !== undefined}
            onClick={onResolve}
          />
        </div>
      </div>
    </div>
  );
};

const HistoryItem = ({ alert: a, isFirst }: { alert: AlertRow; isFirst: boolean }) => {
  const category = a.category ? CATEGORY[a.category] : undefined;
  const start = Date.parse(a.created_at);
  const end = a.resolved_at ? Date.parse(a.resolved_at) : NaN;
  const hasEnd = Number.isFinite(end);
  const isSameDay = hasEnd && new Date(start).toDateString() === new Date(end).toDateString();
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "auto 1fr auto",
        gap: 12,
        alignItems: "baseline",
        padding: "11px 2px",
        borderTop: isFirst ? undefined : "1px solid var(--lx-hairline)",
      }}
    >
      <span style={{ alignSelf: "center" }}>
        <StatusDot status={SEVERITY_STATUS[a.severity] ?? "idle"} label={SEVERITY_LABEL[a.severity] ?? a.severity} />
      </span>
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 13.5, fontWeight: 600, lineHeight: 1.4 }}>{a.title}</div>
        <div style={{ fontSize: 12, color: "var(--lx-muted)", marginTop: 2 }}>
          {category ? `${category.label} · ` : ""}
          <Mono>
            {formatLogTime(a.created_at)}
            {hasEnd ? ` → ${isSameDay ? formatClock(a.resolved_at) : formatLogTime(a.resolved_at)}` : ""}
          </Mono>
        </div>
      </div>
      <span style={{ textAlign: "right", lineHeight: 1.2 }}>
        <Mono style={{ fontSize: 13, fontWeight: 650 }}>{hasEnd ? formatDuration((end - start) / 1000) : "-"}</Mono>
        <span style={{ display: "block", fontSize: 10.5, color: "var(--lx-muted)" }}>durasi</span>
      </span>
    </div>
  );
};

const cssVar = (name: string) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

export default function AlertsBell() {
  const toast = useToast();
  const [alerts, setAlerts] = useState<AlertRow[]>([]);
  // The server's count of active alerts, which can run past the loaded page.
  const [total, setTotal] = useState(0);
  const [isOpen, setOpen] = useState(false);
  const [view, setView] = useState<"active" | "history">("active");
  const [filter, setFilter] = useState<Severity | null>(null);
  const [busy, setBusy] = useState<Record<number, "ack" | "resolve">>({});
  const [history, setHistory] = useState<AlertRow[] | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const rowRefs = useRef(new Map<number, HTMLDivElement>());

  // Resolves to the fresh list, or null when the fetch failed.
  const refresh = useCallback(async (): Promise<AlertRow[] | null> => {
    try {
      // The server pages at 100 by default; event alerts only close by hand,
      // so a lab that leaves them open would otherwise count a flat 100.
      const data = await getJson<{ total: number; alerts: AlertRow[] }>(
        `/api/alerts?active=true&limit=${ACTIVE_LIMIT}`,
        "Gagal memuat peringatan",
      );
      const list = data.alerts || [];
      setAlerts(list);
      setTotal(data.total ?? list.length);
      return list;
    } catch {
      // Roles without alert access get a 403; keep the last known list rather
      // than flashing an error into the app chrome.
      return null;
    }
  }, []);

  usePolling(refresh, isOpen ? 10000 : 30000);

  const loadHistory = useCallback(async () => {
    setHistoryError(null);
    try {
      const data = await getJson<{ alerts: AlertRow[] }>(
        `/api/alerts?active=false&limit=${HISTORY_LIMIT}`,
        "Gagal memuat riwayat peringatan",
      );
      setHistory(data.alerts || []);
    } catch (err) {
      setHistoryError((err as Error).message);
    }
  }, []);

  // Fetched each time the tab is opened: an alert resolved a moment ago
  // (by the admin or by the station recovering) belongs in it.
  useEffect(() => {
    if (isOpen && view === "history") loadHistory();
  }, [isOpen, view, loadHistory]);

  const act = async (id: number, kind: "ack" | "resolve") => {
    if (busy[id]) return;
    setBusy((b) => ({ ...b, [id]: kind }));
    try {
      await postEmpty(
        `/api/alerts/${id}/${kind === "ack" ? "acknowledge" : "resolve"}`,
        kind === "ack" ? "Gagal menandai peringatan" : "Gagal menyelesaikan peringatan",
      );
      toast(kind === "ack" ? "Peringatan ditandai." : "Peringatan diselesaikan.");
      // A resolved row slides out before the refresh drops it, so the admin
      // sees which one went instead of the list silently closing up. Durations
      // come from the tokens, so reduced motion makes this instant.
      const row = rowRefs.current.get(id);
      const exit =
        kind === "resolve" && row && typeof row.animate === "function"
          ? row.animate([{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateX(24px)" }], {
              duration: parseFloat(cssVar("--lx-motion-enter")) || 0,
              easing: cssVar("--lx-ease-out") || "ease-out",
              fill: "forwards",
            })
          : null;
      await exit?.finished.catch(() => {});
      const list = await refresh();
      // Only a row that survived the refresh (or a failed one) comes back;
      // cancelling otherwise would flash it for a frame before React drops it.
      if (!list || list.some((a) => a.id === id)) exit?.cancel();
    } catch (err) {
      toast((err as Error).message, "alert");
    } finally {
      setBusy((b) => {
        const next = { ...b };
        delete next[id];
        return next;
      });
    }
  };

  const close = () => {
    setOpen(false);
    setFilter(null);
    setView("active");
  };

  const unacknowledged = alerts.filter((a) => a.status === "active").length;
  if (alerts.length === 0 && !isOpen) return null;

  const countOf = (s: Severity) => alerts.filter((a) => a.severity === s).length;
  // A filter whose last alert just resolved would otherwise strand the admin
  // on an empty list with no chip left to clear it.
  const activeFilter = filter && countOf(filter) > 0 ? filter : null;
  const sorted = [...alerts].sort(
    (a, b) => rank(a.severity) - rank(b.severity) || b.created_at.localeCompare(a.created_at),
  );
  const visible = activeFilter ? sorted.filter((a) => a.severity === activeFilter) : sorted;

  const summary = (
    <div
      className="lx-rise"
      style={
        {
          "--i": 0,
          background: "var(--lx-ink)",
          color: "var(--lx-on-ink)",
          borderRadius: 20,
          padding: "18px 20px 18px",
        } as CSSProperties
      }
    >
      <div style={{ display: "flex", alignItems: "flex-end", gap: "12px 16px", flexWrap: "wrap" }}>
        <div>
          <BigNumber value={total} size={46} />
          <div style={{ fontSize: 12.5, opacity: 0.7, marginTop: 6 }}>
            peringatan aktif ·{" "}
            {unacknowledged > 0 ? (
              <>
                <Mono>{unacknowledged}</Mono> belum ditandai
              </>
            ) : (
              "semua sudah ditandai"
            )}
          </div>
        </div>
        <div style={{ marginLeft: "auto", display: "flex", gap: 6, flexWrap: "wrap" }}>
          {SEVERITY_ORDER.filter((s) => countOf(s) > 0).map((s) => {
            const isOn = activeFilter === s;
            return (
              <button
                key={s}
                type="button"
                className="lx-tap"
                aria-pressed={isOn}
                onClick={() => setFilter(isOn ? null : s)}
                style={{
                  font: "inherit",
                  display: "inline-flex",
                  alignItems: "center",
                  gap: 7,
                  fontSize: 12.5,
                  fontWeight: 600,
                  padding: "6px 12px 6px 10px",
                  borderRadius: "var(--lx-radius-pill)",
                  border: `1px solid ${isOn ? "transparent" : "color-mix(in srgb, var(--lx-on-ink) 22%, transparent)"}`,
                  background: isOn ? "var(--lx-accent)" : "transparent",
                  color: isOn ? "var(--lx-on-accent)" : "var(--lx-on-ink)",
                  cursor: "pointer",
                }}
              >
                <StatusDot status={SEVERITY_STATUS[s]} />
                {SEVERITY_LABEL[s]}
                <Mono>{countOf(s)}</Mono>
              </button>
            );
          })}
        </div>
      </div>
      {/* One segment per alert, worst first; acknowledged ones fade back. */}
      <div aria-hidden="true" style={{ display: "flex", gap: 4, marginTop: 16 }}>
        {sorted.map((a, i) => (
          <span
            key={a.id}
            title={a.title}
            className="lx-grow-x"
            style={
              {
                "--i": i,
                flex: 1,
                minWidth: 0,
                height: 8,
                borderRadius: "var(--lx-radius-pill)",
                background: statusColor(SEVERITY_STATUS[a.severity] ?? "idle"),
                opacity: activeFilter && a.severity !== activeFilter ? 0.18 : a.status === "acknowledged" ? 0.45 : 1,
                transition: "opacity var(--lx-motion) var(--lx-ease)",
              } as CSSProperties
            }
          />
        ))}
      </div>
    </div>
  );

  const allClear = (
    <div className="lx-rise" style={{ textAlign: "center", padding: "26px 12px 18px" }}>
      <span
        style={{
          width: 60,
          height: 60,
          borderRadius: "var(--lx-radius-pill)",
          background: "var(--lx-accent)",
          color: "var(--lx-on-accent)",
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M5 12.5l4.5 4.5L19 7.5" />
        </svg>
      </span>
      <div style={{ fontSize: 15, fontWeight: 600, marginTop: 14 }}>Semua beres</div>
      <div style={{ fontSize: 13, color: "var(--lx-muted)", marginTop: 4, lineHeight: 1.5 }}>
        Tidak ada peringatan aktif. Yang sudah selesai tercatat di Riwayat.
      </div>
    </div>
  );

  const activeView =
    alerts.length === 0 ? (
      allClear
    ) : (
      <div style={{ display: "grid", gap: 10 }}>
        {summary}
        <div style={{ display: "grid", gap: 8 }}>
          {visible.map((a, i) => (
            <AlertItem
              key={a.id}
              alert={a}
              index={i + 1}
              busy={busy[a.id]}
              rowRef={(el) => {
                if (el) rowRefs.current.set(a.id, el);
                else rowRefs.current.delete(a.id);
              }}
              onAcknowledge={() => act(a.id, "ack")}
              onResolve={() => act(a.id, "resolve")}
            />
          ))}
        </div>
      </div>
    );

  // A failed reload shows the error even over an earlier list: stale history
  // passed off as current is worse than none.
  const historyView = historyError ? (
    <div style={{ fontSize: 13, lineHeight: 1.5, padding: "8px 0", display: "grid", gap: 10, justifyItems: "start" }}>
      <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
        <StatusDot status="alert" />
        {historyError}
      </span>
      <Button label="Coba lagi" variant="secondary" size="sm" onClick={loadHistory} />
    </div>
  ) : history === null || history.length === 0 ? (
    <div style={{ fontSize: 13, color: "var(--lx-muted)", padding: "8px 0" }}>
      {history === null ? "Memuat riwayat..." : "Belum ada peringatan yang selesai."}
    </div>
  ) : (
    <div className="lx-rise">
      <div style={{ fontSize: 12.5, color: "var(--lx-muted)", marginBottom: 4 }}>
        <Mono style={{ color: "var(--lx-text)" }}>{history.length}</Mono> peringatan terakhir yang selesai, terbaru di atas.
      </div>
      {history.map((a, i) => (
        <HistoryItem key={a.id} alert={a} isFirst={i === 0} />
      ))}
    </div>
  );

  return (
    <>
      {alerts.length > 0 && (
        <FrameTrigger
          icon={BELL}
          label="Peringatan"
          count={unacknowledged || total}
          tone={unacknowledged > 0 ? "alert" : "quiet"}
          ariaLabel={unacknowledged > 0 ? `${unacknowledged} peringatan belum ditandai` : `${total} peringatan aktif`}
          // Opening shortens the poll interval, and that restart fetches at once.
          onClick={() => setOpen(true)}
        />
      )}

      <Modal
        isOpen={isOpen}
        onClose={close}
        title="Peringatan sistem"
        description="Kejadian yang perlu ditinjau admin."
        width={560}
        footer={<Button label="Tutup" variant="secondary" size="sm" onClick={close} />}
      >
        <div style={{ display: "grid", gap: 14 }}>
          <PillTabs
            ariaLabel="Tampilan peringatan"
            value={view}
            onChange={setView}
            options={[
              { value: "active", label: "Aktif" },
              { value: "history", label: "Riwayat" },
            ]}
          />
          {view === "active" ? activeView : historyView}
        </div>
      </Modal>
    </>
  );
}
