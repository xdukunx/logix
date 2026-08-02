// Active-alert surface, polled every 30s regardless of the visible tab.
// The v3 canvases don't draw an alerts control, so this deliberately borrows
// the existing vocabulary -- an 8px dot plus a mono count -- rather than
// inventing a filled badge, which the guard rails forbid. It renders nothing
// at all when there is nothing to report.
import { useCallback, useState } from "react";

import { getJson, postEmpty } from "../api";
import type { Alert } from "../types";
import type { StationStatus } from "../tokens";
import { StatusDot } from "../ui/base";
import { Button } from "../ui/controls";
import { Modal, useToast } from "../ui/overlays";
import { formatLogTime, usePolling } from "../util";

const SEVERITY_STATUS: Record<Alert["severity"], StationStatus> = {
  info: "idle",
  warning: "locked",
  critical: "alert",
};

export default function AlertsBell() {
  const toast = useToast();
  const [alerts, setAlerts] = useState<Alert[]>([]);
  const [isOpen, setOpen] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const data = await getJson<{ alerts: Alert[] }>("/api/alerts?active=true", "Gagal memuat peringatan");
      setAlerts(data.alerts || []);
    } catch {
      // Roles without alert access get a 403; keep the last known list rather
      // than flashing an error into the app chrome.
    }
  }, []);

  usePolling(refresh, 30000);

  const act = async (fn: Promise<unknown>, message: string) => {
    try {
      await fn;
      toast(message);
      refresh();
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  };

  const unacknowledged = alerts.filter((a) => a.status === "active").length;
  if (alerts.length === 0) return null;

  return (
    <>
      <button
        type="button"
        onClick={() => {
          setOpen(true);
          refresh();
        }}
        style={{
          font: "inherit",
          display: "inline-flex",
          alignItems: "center",
          gap: 7,
          fontSize: 12,
          color: "var(--lx-muted)",
          background: "transparent",
          border: "none",
          padding: "4px 0",
          cursor: "pointer",
        }}
      >
        <StatusDot status={unacknowledged > 0 ? "alert" : "idle"} />
        <span className="lx-mono">{unacknowledged || alerts.length}</span> peringatan
      </button>

      <Modal
        isOpen={isOpen}
        onClose={() => setOpen(false)}
        title="Peringatan sistem"
        description="Kejadian yang perlu ditinjau admin."
        width={460}
        footer={<Button label="Tutup" variant="secondary" size="sm" onClick={() => setOpen(false)} />}
      >
        <div style={{ display: "grid" }}>
          {alerts.map((a, i) => {
            const isAcknowledged = a.status === "acknowledged";
            return (
              <div
                key={a.id}
                style={{
                  display: "flex",
                  alignItems: "flex-start",
                  gap: 10,
                  padding: "12px 0",
                  borderTop: i === 0 ? undefined : "1px solid var(--lx-hairline)",
                }}
              >
                <span style={{ marginTop: 5 }}>
                  <StatusDot status={SEVERITY_STATUS[a.severity] ?? "idle"} label={a.severity} />
                </span>
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div style={{ fontSize: 13.5, fontWeight: 600 }}>{a.title}</div>
                  <div style={{ fontSize: 12.5, color: "var(--lx-muted)", lineHeight: 1.5 }}>{a.message}</div>
                  <div className="lx-mono" style={{ fontSize: 11, color: "var(--lx-muted)", marginTop: 4 }}>
                    {formatLogTime(a.created_at)}
                    {isAcknowledged ? " · diketahui" : ""}
                  </div>
                </div>
                <div style={{ display: "flex", gap: 6, flexShrink: 0 }}>
                  {!isAcknowledged && (
                    <Button
                      label="Tandai"
                      variant="secondary"
                      size="sm"
                      onClick={() =>
                        act(
                          postEmpty(`/api/alerts/${a.id}/acknowledge`, "Gagal menandai peringatan"),
                          "Peringatan ditandai.",
                        )
                      }
                    />
                  )}
                  <Button
                    label="Selesaikan"
                    variant="ghost"
                    size="sm"
                    onClick={() =>
                      act(
                        postEmpty(`/api/alerts/${a.id}/resolve`, "Gagal menyelesaikan peringatan"),
                        "Peringatan diselesaikan.",
                      )
                    }
                  />
                </div>
              </div>
            );
          })}
        </div>
      </Modal>
    </>
  );
}
