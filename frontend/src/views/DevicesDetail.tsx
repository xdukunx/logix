// One device in full: sync state, agent, the last screenshot (and asking for
// a new one), the commands sent to it, and the rebind / delete actions. The
// page shows it in a SidePanel.
import type { CSSProperties, ReactNode } from "react";

import { categoryLabel, type StationStatus } from "../tokens";
import type { CommandStatus, Device, DeviceDetail, DeviceScreenshot } from "../types";
import { Callout, Mono, SectionLabel, Skeleton, StatusDot } from "../ui/base";
import { Button } from "../ui/controls";
import { formatLogTime, timeAgo } from "../util";
import { Swatch, Tag } from "./DevicesBento";
import { SYNC_LABEL, SYNC_STATUS, agentVersion, isOutdated, nameOf, skewMinutes } from "./DevicesModel";

export interface Invite {
  invite_code: string;
  expires_at: string;
  /** Client clock at receipt: the full length of the draining bar. */
  issuedAt: number;
  /** The device this code rebinds; null for a new device (the Tambah modal). */
  deviceId: string | null;
}

export const shotSrc = (s: DeviceScreenshot) => `data:${s.content_type || "image/jpeg"};base64,${s.image_base64}`;

// Same words as Riwayat's audit log, so one command reads the same on both
// screens; unknown action codes fall through as-is rather than being hidden.
const ACTION_LABEL: Record<string, string> = {
  LOCK: "Kunci",
  UNLOCK: "Buka kunci",
  BROADCAST: "Pesan",
  SCREENSHOT: "Cuplikan layar",
  SHUTDOWN: "Matikan",
  RESTART: "Mulai ulang",
  LOGOFF: "Log off pengguna",
  RENAME: "Ganti nama",
  REVOKE_API_KEY: "Cabut kunci API",
  DELETE_DEVICE: "Hapus perangkat",
};

const COMMAND_LABEL: Record<CommandStatus, string> = {
  done: "OK",
  queued: "Antre",
  failed: "Gagal",
  expired: "Kedaluwarsa",
};
const COMMAND_ORDER: CommandStatus[] = ["done", "queued", "failed", "expired"];
const COMMAND_DOT: Record<CommandStatus, StationStatus> = { done: "active", queued: "idle", failed: "alert", expired: "locked" };
// Expired has no fill: it is drawn hatched, like every other "nothing happened".
const COMMAND_FILL: Record<CommandStatus, string | undefined> = {
  done: "var(--lx-ink)",
  queued: "var(--lx-accent)",
  failed: "var(--lx-status-alert)",
  expired: undefined,
};

const note: CSSProperties = { fontSize: 12, lineHeight: 1.5, color: "var(--lx-muted)" };

const Section = ({ i, label, children }: { i: number; label?: string; children: ReactNode }) => (
  <section className="lx-rise" style={{ "--i": i } as CSSProperties}>
    {label && (
      <div style={{ marginBottom: 8 }}>
        <SectionLabel>{label}</SectionLabel>
      </div>
    )}
    {children}
  </section>
);

// ---------------------------------------------------------------------------
// The invite code as a lime ticket, with the 15 minutes it is valid for
// draining out of the bar beneath it -- a live countdown, so it moves.

export const InviteTicket = ({ invite, onCopy }: { invite: Invite; onCopy?: () => void }) => {
  const expires = Date.parse(invite.expires_at);
  const left = Math.max(0, expires - Date.now());
  const isExpired = left <= 0;
  const secs = Math.floor(left / 1000);
  const mmss = `${String(Math.floor(secs / 60)).padStart(2, "0")}:${String(secs % 60).padStart(2, "0")}`;
  return (
    <div
      key={invite.invite_code}
      className={isExpired ? "lx-hatch" : "lx-rise"}
      style={{
        borderRadius: 18,
        padding: "14px 16px 12px",
        backgroundColor: isExpired ? "var(--lx-sunken)" : "var(--lx-accent)",
        color: isExpired ? "var(--lx-muted)" : "var(--lx-on-accent)",
        border: `1px ${isExpired ? "dashed var(--lx-border-dashed)" : "solid transparent"}`,
      }}
    >
      <div style={{ fontSize: 10.5, fontWeight: 700, letterSpacing: ".06em", textTransform: "uppercase", opacity: 0.75 }}>
        Kode undangan
      </div>
      <div
        className="lx-mono"
        style={{
          fontSize: "clamp(16px, 5vw, 21px)",
          fontWeight: 650,
          letterSpacing: ".1em",
          margin: "6px 0 12px",
          overflowWrap: "anywhere",
          userSelect: "all",
          textDecoration: isExpired ? "line-through" : undefined,
        }}
      >
        {invite.invite_code}
      </div>
      <div style={{ position: "relative", height: 4, borderRadius: 999, overflow: "hidden" }}>
        <span style={{ position: "absolute", inset: 0, background: "currentColor", opacity: 0.16 }} />
        <span
          style={{
            position: "absolute",
            inset: 0,
            background: "currentColor",
            transformOrigin: "left",
            transform: `scaleX(${Math.min(1, left / Math.max(1, expires - invite.issuedAt))})`,
            transition: "transform 1s linear",
          }}
        />
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 10 }}>
        <Mono style={{ fontSize: 11.5, fontWeight: 650 }}>{isExpired ? "kedaluwarsa" : `kedaluwarsa dalam ${mmss}`}</Mono>
        {onCopy && !isExpired && (
          <button
            type="button"
            className="lx-tap"
            onClick={onCopy}
            style={{
              font: "inherit",
              marginLeft: "auto",
              fontSize: 12,
              fontWeight: 650,
              padding: "5px 12px",
              borderRadius: 999,
              border: "none",
              background: "var(--lx-on-accent)",
              color: "var(--lx-accent)",
              cursor: "pointer",
            }}
          >
            Salin
          </button>
        )}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Commands sent to this device: the done/queued/failed/expired split as one
// bar, then the most recent few.

const CommandHistory = ({ detail }: { detail: DeviceDetail | null }) => {
  if (!detail) return <Skeleton height={64} />;
  const health = detail.sync_health;
  const count = (k: CommandStatus) => health?.[k] ?? 0;
  if (COMMAND_ORDER.every((k) => count(k) === 0)) {
    return <div style={{ fontSize: 13, color: "var(--lx-muted)" }}>Belum ada perintah ke perangkat ini.</div>;
  }
  return (
    <>
      <div style={{ display: "flex", gap: 3, height: 10, borderRadius: 999, overflow: "hidden" }}>
        {COMMAND_ORDER.filter((k) => count(k) > 0).map((k, i) => (
          <span
            key={k}
            className={`lx-grow-x${COMMAND_FILL[k] ? "" : " lx-hatch"}`}
            title={`${COMMAND_LABEL[k]}: ${count(k)}`}
            style={{
              "--i": i,
              flexGrow: count(k),
              flexBasis: 0,
              minWidth: 6,
              backgroundColor: COMMAND_FILL[k],
              boxShadow: COMMAND_FILL[k] ? undefined : "inset 0 0 0 1px var(--lx-hatch)",
            } as CSSProperties}
          />
        ))}
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: "4px 14px", marginTop: 8, fontSize: 12, color: "var(--lx-muted)" }}>
        {COMMAND_ORDER.map((k) => (
          <span key={k}>
            {COMMAND_LABEL[k]} <Mono style={{ color: "var(--lx-text)" }}>{count(k)}</Mono>
          </span>
        ))}
      </div>
      <div style={{ display: "grid", marginTop: 10 }}>
        {detail.recent_actions.slice(0, 5).map((a) => (
          <div
            key={a.action_id}
            title={a.error_message || a.result_summary || undefined}
            style={{
              display: "grid",
              gridTemplateColumns: "88px 1fr auto",
              gap: 10,
              alignItems: "center",
              padding: "7px 0",
              borderTop: "1px solid var(--lx-hairline)",
              fontSize: 13,
            }}
          >
            <Mono style={{ fontSize: 11.5, color: "var(--lx-muted)" }}>{formatLogTime(a.timestamp)}</Mono>
            <span style={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {ACTION_LABEL[a.action_type] ?? a.action_type}
            </span>
            <span style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 12, color: "var(--lx-muted)" }}>
              <StatusDot status={COMMAND_DOT[a.status] ?? "idle"} />
              {COMMAND_LABEL[a.status] ?? a.status}
            </span>
          </div>
        ))}
      </div>
    </>
  );
};

// ---------------------------------------------------------------------------

export const DetailHeader = ({ device }: { device: Device }) => {
  const { id, spec } = nameOf(device);
  return (
    <div key={device.device_id} className="lx-rise">
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <StatusDot status={SYNC_STATUS[device.sync_status] ?? "idle"} label={SYNC_LABEL[device.sync_status]} />
        <Mono style={{ fontSize: 20, fontWeight: 700 }}>{id}</Mono>
      </div>
      <div style={{ fontSize: 12.5, color: "var(--lx-muted)", marginTop: 4 }}>
        {spec || categoryLabel(device.category)} · <Mono>{device.hostname}</Mono>
      </div>
    </div>
  );
};

const detailRow = (label: string, value: ReactNode) => (
  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 12 }}>
    <span style={{ color: "var(--lx-muted)", flexShrink: 0 }}>{label}</span>
    <span style={{ textAlign: "right", minWidth: 0 }}>{value}</span>
  </div>
);

export const DetailBody = ({
  device: d,
  detail,
  newest,
  shot,
  isWaitingShot,
  isRequestingShot,
  invite,
  onRequestShot,
  onReloadShot,
  onOpenShot,
  onCreateInvite,
  onCopyInvite,
  onDelete,
}: {
  device: Device;
  detail: DeviceDetail | null;
  newest: string | null;
  /** `undefined` = still loading; `null` = the server has none (a 404, a normal state). */
  shot: DeviceScreenshot | null | undefined;
  isWaitingShot: boolean;
  isRequestingShot: boolean;
  /** Only a code made for THIS device. */
  invite: Invite | null;
  onRequestShot: () => void;
  onReloadShot: () => void;
  onOpenShot: () => void;
  onCreateInvite: () => void;
  onCopyInvite?: () => void;
  onDelete: () => void;
}) => {
  const { id } = nameOf(d);
  const version = agentVersion(d);
  const skew = skewMinutes(d);
  const isBehind = isOutdated(d, newest);
  return (
    <div key={d.device_id} style={{ display: "grid", gap: 22 }}>
      <Section i={1} label="Sinkronisasi">
        <div style={{ background: "var(--lx-sunken)", borderRadius: 18, padding: "14px 16px" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12.5, color: "var(--lx-muted)" }}>
            <Swatch status={d.sync_status} />
            <span style={{ color: "var(--lx-text)", fontWeight: 600 }}>{SYNC_LABEL[d.sync_status]}</span>· terakhir
            terlihat
          </div>
          <div className="lx-big lx-mono" style={{ fontSize: 30, marginTop: 10 }}>
            {timeAgo(d.last_seen)}
          </div>
          <Mono style={{ display: "block", fontSize: 12, color: "var(--lx-muted)", marginTop: 6 }}>
            {formatLogTime(d.last_seen)}
          </Mono>
        </div>
      </Section>

      <Section i={2}>
        <div style={{ display: "grid", gap: 9, fontSize: 13 }}>
          {detailRow(
            "Versi agent",
            <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
              <Mono>{version ?? "-"}</Mono>
              {version && newest && (
                <Tag tone={isBehind ? "ink" : "accent"} style={{ fontSize: 10.5 }}>
                  {isBehind ? `terbaru ${newest}` : "terbaru"}
                </Tag>
              )}
            </span>,
          )}
          {detailRow("Kategori", categoryLabel(d.category))}
          {detailRow("Kebijakan", detail?.policy?.description ?? "-")}
          {detailRow("Sistem operasi", typeof d.agent_os === "string" && d.agent_os ? d.agent_os : "-")}
          {detailRow(
            "Terdaftar",
            typeof d.enrolled_at === "string" && d.enrolled_at ? <Mono>{formatLogTime(d.enrolled_at)}</Mono> : "Tanpa kode undangan",
          )}
          {skew !== null && (
            <Callout tone="warning">
              Jam perangkat ini selisih <Mono>{skew}</Mono> menit dari server, jadi jam sesi yang dicatatnya ikut
              bergeser.
            </Callout>
          )}
        </div>
      </Section>

      <Section i={3} label="Cuplikan layar terakhir">
        {shot === undefined ? (
          <Skeleton height={124} />
        ) : shot === null ? (
          <div
            className="lx-hatch"
            style={{ border: "1px dashed var(--lx-border-dashed)", borderRadius: 16, padding: "26px 14px", textAlign: "center" }}
          >
            <span style={{ ...note, background: "var(--lx-card)", padding: "5px 12px", borderRadius: 999 }}>
              Belum ada cuplikan untuk perangkat ini.
            </span>
          </div>
        ) : (
          <button
            key={shot.captured_at}
            type="button"
            onClick={onOpenShot}
            title="Perbesar cuplikan"
            className="lx-interactive lx-rise"
            style={{
              display: "block",
              width: "100%",
              padding: 0,
              border: "1px solid var(--lx-border)",
              borderRadius: 16,
              overflow: "hidden",
              background: "var(--lx-sunken)",
              cursor: "zoom-in",
            }}
          >
            <img src={shotSrc(shot)} alt={`Cuplikan layar ${id}`} style={{ display: "block", width: "100%", height: "auto" }} />
          </button>
        )}
        <p style={{ ...note, margin: "8px 0 10px" }}>
          {shot ? (
            <>
              Diambil <Mono>{formatLogTime(shot.captured_at)}</Mono>. Pengguna selalu diberi tahu saat cuplikan diambil.
            </>
          ) : (
            "Pengguna selalu diberi tahu saat cuplikan diambil. Tidak ada pengambilan diam-diam."
          )}
        </p>
        {isWaitingShot && (
          <div role="status" style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12.5, marginBottom: 10 }}>
            <span
              className="lx-breathe"
              style={{ width: 8, height: 8, borderRadius: 999, background: "var(--lx-accent-text)", flexShrink: 0 }}
            />
            Menunggu cuplikan dari <Mono>{id}</Mono>...
          </div>
        )}
        <div style={{ display: "flex", gap: 8 }}>
          <Button
            label={isRequestingShot ? "Meminta..." : "Minta cuplikan"}
            size="sm"
            style={{ flex: 1 }}
            // Held until the current capture has loaded: its timestamp is what
            // tells the wait loop that a newer one has arrived.
            disabled={isRequestingShot || !d.currently_online || shot === undefined}
            title={d.currently_online ? undefined : "Perangkat sedang tidak online"}
            onClick={onRequestShot}
          />
          <Button label="Muat ulang" variant="ghost" size="sm" style={{ flex: 1 }} onClick={onReloadShot} />
        </div>
      </Section>

      <Section i={4} label="Riwayat perintah">
        <CommandHistory detail={detail} />
      </Section>

      <Section i={5} label="Ikat ulang · kode sekali pakai">
        {invite && <InviteTicket invite={invite} onCopy={onCopyInvite} />}
        <p style={{ ...note, margin: "8px 0 14px" }}>
          {invite ? (
            <>
              Masukkan kode ini di client Windows <Mono>{d.hostname}</Mono>. Berlaku 15 menit, sekali pakai, dan hanya
              di mesin ini.
            </>
          ) : (
            "Buat kode sekali pakai untuk mengikat ulang perangkat ini ke server. Nama dan kategorinya tetap."
          )}
        </p>
        <div style={{ display: "flex", gap: 8 }}>
          <Button label="Buat kode baru" size="sm" style={{ flex: 1 }} onClick={onCreateInvite} />
          <Button label="Hapus" variant="danger-outline" size="sm" style={{ flex: 1 }} onClick={onDelete} />
        </div>
      </Section>
    </div>
  );
};
