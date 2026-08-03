// Overlay surfaces: the card ⋯ menu (popover on desktop, bottom sheet on
// phone), modals, the device detail drawer, and toasts. Modals are the one
// "elevated" surface in v3 -- everything else stays flat.
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";

import { statusEdge } from "./base";
import { Button } from "./controls";
import { useBreakpoint, useDismiss } from "./hooks";
import type { StationStatus } from "../tokens";

export interface MenuItem {
  label: string;
  onClick: () => void;
  isDanger?: boolean;
  isDisabled?: boolean;
  /** Draws a hairline above this item. */
  isDivided?: boolean;
}

const menuItemStyle = (item: MenuItem, minHeight: number): CSSProperties => ({
  font: "inherit",
  display: "flex",
  alignItems: "center",
  width: "100%",
  textAlign: "left",
  fontSize: minHeight > 40 ? 14 : 13.5,
  padding: minHeight > 40 ? "13px 2px" : "8px 12px",
  minHeight,
  borderRadius: minHeight > 40 ? 0 : 8,
  border: "none",
  background: "transparent",
  color: item.isDanger ? "var(--lx-status-alert)" : "var(--lx-text)",
  opacity: item.isDisabled ? 0.45 : 1,
  cursor: item.isDisabled ? "not-allowed" : "pointer",
});

/**
 * The ⋯ trigger + its menu. Below 768px the menu becomes a bottom sheet with
 * the same four actions and >=46px rows (README §4).
 */
export const MoreMenu = ({ label, items }: { label: string; items: MenuItem[] }) => {
  const [isOpen, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const isPhone = useBreakpoint() === "phone";
  useDismiss(ref, isOpen && !isPhone, () => setOpen(false));

  const run = (item: MenuItem) => {
    if (item.isDisabled) return;
    setOpen(false);
    item.onClick();
  };

  const trigger = (
    <button
      type="button"
      aria-label={label}
      aria-haspopup="menu"
      aria-expanded={isOpen}
      onClick={() => setOpen((v) => !v)}
      style={{
        font: "inherit",
        marginLeft: "auto",
        border: "none",
        background: "transparent",
        color: isOpen ? "var(--lx-text)" : "var(--lx-muted)",
        letterSpacing: 2,
        lineHeight: 1,
        fontSize: 16,
        padding: "0 0 0 4px",
        cursor: "pointer",
        flexShrink: 0,
      }}
    >
      ⋯
    </button>
  );

  return (
    <div ref={ref} style={{ position: "relative", marginLeft: "auto", display: "flex" }}>
      {trigger}
      {isOpen && !isPhone && (
        <div
          role="menu"
          className="lx-anim-menu lx-material"
          style={{
            position: "absolute",
            top: 26,
            right: 0,
            zIndex: 30,
            border: "1px solid var(--lx-border)",
            borderRadius: "var(--lx-radius-menu)",
            width: 168,
            padding: 6,
            boxShadow: "var(--lx-shadow-menu)",
          }}
        >
          {items.map((item) => (
            <div key={item.label}>
              {item.isDivided && (
                <div style={{ borderTop: "1px solid var(--lx-border)", margin: "4px 8px" }} />
              )}
              <button
                type="button"
                role="menuitem"
                className="lx-tap lx-row-hover"
                disabled={item.isDisabled}
                onClick={() => run(item)}
                style={menuItemStyle(item, 0)}
              >
                {item.label}
              </button>
            </div>
          ))}
        </div>
      )}
      {isOpen && isPhone && (
        <BottomSheet onClose={() => setOpen(false)} title={label}>
          {items.map((item, i) => (
            <button
              key={item.label}
              type="button"
              role="menuitem"
              disabled={item.isDisabled}
              onClick={() => run(item)}
              style={{
                ...menuItemStyle(item, 46),
                borderTop: i === 0 ? undefined : "1px solid var(--lx-hairline)",
              }}
            >
              {item.label}
            </button>
          ))}
        </BottomSheet>
      )}
    </div>
  );
};

/** Phone action sheet. Rendered in a portal so card overflow can't clip it. */
export const BottomSheet = ({
  title,
  header,
  onClose,
  children,
}: {
  title: string;
  header?: ReactNode;
  onClose: () => void;
  children: ReactNode;
}) =>
  createPortal(
    <div
      style={{ position: "fixed", inset: 0, zIndex: 60, display: "flex", alignItems: "flex-end" }}
      role="dialog"
      aria-modal="true"
      aria-label={title}
    >
      <div
        className="lx-anim-backdrop"
        style={{ position: "absolute", inset: 0, background: "rgba(16,24,40,.32)" }}
        onClick={onClose}
      />
      <div
        className="lx-anim-sheet lx-material"
        style={{
          position: "relative",
          width: "100%",
          borderRadius: "20px 20px 0 0",
          padding: "10px 18px 22px",
          boxShadow: "0 -12px 40px rgba(16,24,40,.18)",
        }}
      >
        <div
          style={{
            width: 36,
            height: 4,
            borderRadius: 999,
            background: "var(--lx-border)",
            margin: "0 auto 14px",
          }}
        />
        {header}
        <div style={{ borderTop: "1px solid var(--lx-hairline)", display: "grid" }}>{children}</div>
      </div>
    </div>,
    document.body,
  );

/**
 * Confirmation / action modal. `accentEdge` draws the 3px top border the
 * Emergency Broadcast modal uses; `footer` holds the pill actions.
 */
export const Modal = ({
  isOpen,
  onClose,
  title,
  description,
  accentEdge,
  width = 380,
  children,
  footer,
}: {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  description?: ReactNode;
  accentEdge?: StationStatus;
  width?: number;
  children?: ReactNode;
  footer?: ReactNode;
}) => {
  const ref = useRef<HTMLDivElement>(null);
  useDismiss(ref, isOpen, onClose);

  useEffect(() => {
    if (!isOpen) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [isOpen]);

  if (!isOpen) return null;

  return createPortal(
    <div
      className="lx-anim-backdrop"
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 70,
        background: "rgba(16,24,40,.32)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 20,
      }}
    >
      <div
        ref={ref}
        role="dialog"
        className="lx-anim-modal lx-material"
        aria-modal="true"
        aria-label={title}
        style={{
          borderRadius: "var(--lx-radius-card)",
          padding: 24,
          width,
          maxWidth: "100%",
          maxHeight: "90vh",
          overflowY: "auto",
          boxShadow: "var(--lx-shadow-modal)",
          ...(accentEdge ? statusEdge(accentEdge, "top") : {}),
        }}
      >
        <div style={{ fontSize: 17, fontWeight: 600, marginBottom: 8 }}>{title}</div>
        {description && (
          <div
            style={{
              fontSize: 13.5,
              lineHeight: 1.55,
              color: "var(--lx-muted)",
              marginBottom: 14,
            }}
          >
            {description}
          </div>
        )}
        {children}
        {footer && (
          <div style={{ display: "flex", gap: 8, justifyContent: "flex-end", marginTop: 20 }}>
            {footer}
          </div>
        )}
      </div>
    </div>,
    document.body,
  );
};

/** Right-hand detail drawer (Devices). 330px on desktop, full-width below. */
export const Drawer = ({
  isOpen,
  onClose,
  title,
  subtitle,
  children,
}: {
  isOpen: boolean;
  onClose: () => void;
  title: ReactNode;
  subtitle?: ReactNode;
  children: ReactNode;
}) => {
  if (!isOpen) return null;
  return (
    <aside
      aria-label="Detail perangkat"
      style={{
        width: 330,
        flexShrink: 0,
        background: "var(--lx-card)",
        border: "1px solid var(--lx-border)",
        borderRadius: "var(--lx-radius-card)",
        padding: "26px 24px",
        alignSelf: "flex-start",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 4 }}>
        {title}
        <button
          type="button"
          aria-label="Tutup detail"
          onClick={onClose}
          style={{
            font: "inherit",
            marginLeft: "auto",
            border: "none",
            background: "transparent",
            color: "var(--lx-muted)",
            fontSize: 15,
            cursor: "pointer",
          }}
        >
          ✕
        </button>
      </div>
      {subtitle && (
        <div style={{ fontSize: 12.5, color: "var(--lx-muted)", marginBottom: 20 }}>{subtitle}</div>
      )}
      {children}
    </aside>
  );
};

// ---- Toasts -------------------------------------------------------------

interface Toast {
  id: number;
  body: string;
  status: StationStatus;
}

const ToastContext = createContext<((body: string, status?: StationStatus) => void) | null>(null);

export const useToast = () => {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error("useToast must be used within ToastProvider");
  return ctx;
};

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const seq = useRef(0);

  const push = useCallback((body: string, status: StationStatus = "active") => {
    const id = ++seq.current;
    setToasts((t) => [...t, { id, body, status }]);
    window.setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 5000);
  }, []);

  const dismiss = (id: number) => setToasts((t) => t.filter((x) => x.id !== id));
  const value = useMemo(() => push, [push]);

  return (
    <ToastContext.Provider value={value}>
      {children}
      <div
        aria-live="polite"
        style={{
          position: "fixed",
          right: 20,
          bottom: 20,
          zIndex: 80,
          display: "grid",
          gap: 8,
          maxWidth: "calc(100vw - 40px)",
        }}
      >
        {toasts.map((t) => (
          <div
            key={t.id}
            className="lx-anim-toast lx-material"
            style={{
              border: "1px solid var(--lx-border)",
              ...statusEdge(t.status),
              borderRadius: "var(--lx-radius-menu)",
              padding: "11px 16px",
              display: "flex",
              alignItems: "center",
              gap: 10,
              boxShadow: "var(--lx-shadow-card)",
            }}
          >
            <span style={{ fontSize: 13.5 }}>{t.body}</span>
            <button
              type="button"
              onClick={() => dismiss(t.id)}
              style={{
                font: "inherit",
                marginLeft: "auto",
                border: "none",
                background: "transparent",
                fontSize: 12,
                color: "var(--lx-muted)",
                cursor: "pointer",
              }}
            >
              Tutup
            </button>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

/** Cancel + confirm pair used by every modal footer. */
export const ModalActions = ({
  onCancel,
  confirmLabel,
  onConfirm,
  variant = "primary",
  isConfirmDisabled = false,
}: {
  onCancel: () => void;
  confirmLabel: string;
  onConfirm: () => void;
  variant?: "primary" | "danger";
  isConfirmDisabled?: boolean;
}) => (
  <>
    <Button label="Batal" variant="secondary" size="sm" onClick={onCancel} />
    <Button
      label={confirmLabel}
      variant={variant}
      size="sm"
      disabled={isConfirmDisabled}
      onClick={onConfirm}
    />
  </>
);
