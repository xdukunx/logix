// v3 controls. Everything is a pill (radius 999) per the Style Tile; accent is
// used only on the primary variant and focus rings.
import {
  useId,
  useRef,
  useState,
  type ButtonHTMLAttributes,
  type CSSProperties,
  type ReactNode,
} from "react";

import { useDismiss } from "./hooks";

export type ButtonVariant = "primary" | "secondary" | "ghost" | "danger" | "danger-outline";

const VARIANT: Record<ButtonVariant, CSSProperties> = {
  primary: { background: "var(--lx-accent)", color: "var(--lx-on-accent)", border: "1px solid transparent" },
  secondary: { background: "var(--lx-card)", color: "var(--lx-text)", border: "1px solid var(--lx-border)" },
  ghost: { background: "transparent", color: "var(--lx-muted)", border: "1px solid transparent" },
  danger: { background: "var(--lx-status-alert)", color: "#fff", border: "1px solid transparent" },
  "danger-outline": {
    background: "var(--lx-card)",
    color: "var(--lx-status-alert)",
    border: "1px solid var(--lx-border)",
  },
};

export const Button = ({
  label,
  variant = "secondary",
  size = "md",
  isFullWidth = false,
  style,
  ...rest
}: {
  label: ReactNode;
  variant?: ButtonVariant;
  size?: "md" | "sm";
  isFullWidth?: boolean;
} & ButtonHTMLAttributes<HTMLButtonElement>) => (
  <button
    type="button"
    className="lx-tap"
    {...rest}
    style={{
      font: "inherit",
      fontSize: size === "sm" ? 13 : 13.5,
      fontWeight: 600,
      lineHeight: 1,
      padding: size === "sm" ? "8px 18px" : "9px 20px",
      borderRadius: "var(--lx-radius-pill)",
      cursor: rest.disabled ? "not-allowed" : "pointer",
      opacity: rest.disabled ? 0.5 : 1,
      width: isFullWidth ? "100%" : undefined,
      whiteSpace: "nowrap",
      // No inline `transition` here: an inline style beats the .lx-tap class,
      // which would silently kill the press feedback.
      ...VARIANT[variant],
      ...style,
    }}
  >
    {label}
  </button>
);

const CHEVRON = (
  <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true" style={{ flexShrink: 0 }}>
    <path
      d="M2 3.5 L5 6.5 L8 3.5"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
    />
  </svg>
);

/**
 * Pill dropdown — the period preset, Unduh, and the Riwayat filter chips all
 * use this. `isAccent` renders the filled primary form (Unduh).
 */
export const PillSelect = <T extends string>({
  label,
  value,
  options,
  onChange,
  isAccent = false,
  width,
}: {
  label?: string;
  value?: T;
  options: { value: T; label: string; isDivided?: boolean }[];
  onChange: (value: T) => void;
  isAccent?: boolean;
  width?: number;
}) => {
  const [isOpen, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useDismiss(ref, isOpen, () => setOpen(false));

  const current = options.find((o) => o.value === value);
  const text = label ? `${label}: ${current?.label ?? ""}` : (current?.label ?? label ?? "");

  return (
    <div ref={ref} style={{ position: "relative", display: "inline-block" }}>
      <button
        type="button"
        aria-haspopup="listbox"
        aria-expanded={isOpen}
        className="lx-tap"
        onClick={() => setOpen((v) => !v)}
        style={{
          font: "inherit",
          display: "inline-flex",
          alignItems: "center",
          gap: 8,
          fontSize: 13.5,
          fontWeight: isAccent ? 600 : 400,
          padding: isAccent ? "9px 18px" : "8px 18px",
          borderRadius: "var(--lx-radius-pill)",
          background: isAccent ? "var(--lx-accent)" : "var(--lx-card)",
          color: isAccent ? "var(--lx-on-accent)" : "var(--lx-text)",
          border: isAccent ? "1px solid transparent" : "1px solid var(--lx-border)",
          cursor: "pointer",
          whiteSpace: "nowrap",
        }}
      >
        {text}
        <span style={{ color: isAccent ? "var(--lx-on-accent)" : "var(--lx-muted)", display: "inline-flex" }}>
          {CHEVRON}
        </span>
      </button>
      {isOpen && (
        <div
          role="listbox"
          className="lx-anim-menu"
          style={{
            position: "absolute",
            top: "calc(100% + 8px)",
            right: 0,
            zIndex: 30,
            background: "var(--lx-card)",
            border: "1px solid var(--lx-border)",
            borderRadius: "var(--lx-radius-menu)",
            width: width ?? 204,
            padding: 6,
            boxShadow: "var(--lx-shadow-menu)",
          }}
        >
          {options.map((o) => (
            <div key={o.value}>
              {o.isDivided && (
                <div style={{ borderTop: "1px solid var(--lx-border)", margin: "4px 8px" }} />
              )}
              <button
                type="button"
                role="option"
                className="lx-tap lx-row-hover"
                aria-selected={o.value === value}
                onClick={() => {
                  onChange(o.value);
                  setOpen(false);
                }}
                style={{
                  font: "inherit",
                  display: "flex",
                  alignItems: "center",
                  width: "100%",
                  textAlign: "left",
                  fontSize: 13.5,
                  fontWeight: o.value === value ? 600 : 400,
                  padding: "8px 12px",
                  borderRadius: 8,
                  border: "none",
                  background: o.value === value ? "var(--lx-sunken)" : "transparent",
                  color: "var(--lx-text)",
                  cursor: "pointer",
                }}
              >
                {o.label}
                {o.value === value && (
                  <svg
                    style={{ marginLeft: "auto" }}
                    width="11"
                    height="11"
                    viewBox="0 0 10 10"
                    aria-hidden="true"
                  >
                    <path
                      d="M1.5 5.5 L4 8 L8.5 2.5"
                      fill="none"
                      stroke="var(--lx-accent)"
                      strokeWidth="1.6"
                      strokeLinecap="round"
                    />
                  </svg>
                )}
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

/** Pill toggle group — nav-style sub-tabs (Log Sesi / Log Audit). */
export const PillTabs = <T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange: (value: T) => void;
  ariaLabel: string;
}) => (
  <div role="tablist" aria-label={ariaLabel} style={{ display: "flex", gap: 4 }}>
    {options.map((o) => {
      const isActive = o.value === value;
      return (
        <button
          key={o.value}
          type="button"
          role="tab"
          className="lx-tap"
          aria-selected={isActive}
          onClick={() => onChange(o.value)}
          style={{
            font: "inherit",
            fontSize: 13,
            fontWeight: 600,
            padding: "7px 16px",
            borderRadius: "var(--lx-radius-pill)",
            border: "none",
            background: isActive ? "var(--lx-pill-active-bg)" : "transparent",
            color: isActive ? "var(--lx-pill-active-fg)" : "var(--lx-muted)",
            cursor: "pointer",
          }}
        >
          {o.label}
        </button>
      );
    })}
  </div>
);

/** Pill switch: 36x21, accent when on. */
export const Toggle = ({
  isOn,
  onChange,
  label,
  isDisabled = false,
}: {
  isOn: boolean;
  onChange: (next: boolean) => void;
  label: string;
  isDisabled?: boolean;
}) => (
  <button
    type="button"
    role="switch"
    aria-checked={isOn}
    aria-label={label}
    disabled={isDisabled}
    onClick={() => onChange(!isOn)}
    style={{
      width: 36,
      height: 21,
      borderRadius: "var(--lx-radius-pill)",
      background: isOn ? "var(--lx-accent)" : "var(--lx-border)",
      border: "none",
      position: "relative",
      flexShrink: 0,
      padding: 0,
      cursor: isDisabled ? "not-allowed" : "pointer",
      opacity: isDisabled ? 0.5 : 1,
      transition: `background var(--lx-motion) var(--lx-ease)`,
    }}
  >
    <span
      style={{
        position: "absolute",
        top: 2,
        left: isOn ? 17 : 2,
        width: 17,
        height: 17,
        borderRadius: 999,
        background: "#fff",
        boxShadow: isOn ? undefined : "0 1px 2px rgba(16,24,40,.15)",
        transition: `left var(--lx-motion) var(--lx-ease)`,
      }}
    />
  </button>
);

const FIELD_STYLE: CSSProperties = {
  font: "inherit",
  width: "100%",
  fontSize: 13.5,
  padding: "9px 14px",
  borderRadius: "var(--lx-radius-control)",
  border: "1px solid var(--lx-border)",
  background: "var(--lx-card)",
  color: "var(--lx-text)",
};

/** Labelled text input. `error` renders the inline dot + fix sentence pattern. */
export const TextField = ({
  label,
  value,
  onChange,
  placeholder,
  error,
  isMono = false,
  autoFocus,
  maxLength,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  error?: string;
  isMono?: boolean;
  autoFocus?: boolean;
  maxLength?: number;
}) => {
  const id = useId();
  return (
    <div>
      <label
        htmlFor={id}
        style={{
          display: "block",
          fontSize: 11,
          fontWeight: 600,
          letterSpacing: ".06em",
          textTransform: "uppercase",
          color: "var(--lx-muted)",
          marginBottom: 6,
        }}
      >
        {label}
      </label>
      <input
        id={id}
        className={isMono ? "lx-mono" : undefined}
        value={value}
        autoFocus={autoFocus}
        maxLength={maxLength}
        placeholder={placeholder}
        aria-invalid={Boolean(error)}
        aria-describedby={error ? `${id}-err` : undefined}
        onChange={(e) => onChange(e.target.value)}
        style={{ ...FIELD_STYLE, borderColor: error ? "var(--lx-status-alert)" : undefined }}
      />
      {error && (
        <div
          id={`${id}-err`}
          style={{ display: "flex", alignItems: "center", gap: 7, margin: "8px 0 0" }}
        >
          <span
            style={{
              width: 8,
              height: 8,
              borderRadius: 999,
              background: "var(--lx-status-alert)",
              flexShrink: 0,
            }}
          />
          <span style={{ fontSize: 12 }}>{error}</span>
        </div>
      )}
    </div>
  );
};

export const TextArea = ({
  label,
  value,
  onChange,
  placeholder,
  rows = 3,
  maxLength,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  rows?: number;
  maxLength?: number;
}) => {
  const id = useId();
  return (
    <div>
      <label
        htmlFor={id}
        style={{
          display: "block",
          fontSize: 11,
          fontWeight: 600,
          letterSpacing: ".06em",
          textTransform: "uppercase",
          color: "var(--lx-muted)",
          marginBottom: 6,
        }}
      >
        {label}
      </label>
      <textarea
        id={id}
        value={value}
        rows={rows}
        maxLength={maxLength}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        style={{ ...FIELD_STYLE, resize: "vertical", lineHeight: 1.5 }}
      />
    </div>
  );
};

/** Search chip — a pill-shaped input with a leading magnifier. */
export const SearchChip = ({
  value,
  onChange,
  placeholder,
  width = 250,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder: string;
  width?: number;
}) => (
  <span
    style={{
      display: "inline-flex",
      alignItems: "center",
      gap: 8,
      background: "var(--lx-card)",
      border: "1px solid var(--lx-border)",
      borderRadius: "var(--lx-radius-pill)",
      padding: "7px 14px",
      width,
      maxWidth: "100%",
    }}
  >
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="var(--lx-muted)"
      strokeWidth="2"
      strokeLinecap="round"
      aria-hidden="true"
      style={{ flexShrink: 0 }}
    >
      <circle cx="11" cy="11" r="7" />
      <line x1="21" y1="21" x2="16.5" y2="16.5" />
    </svg>
    <input
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      aria-label={placeholder}
      style={{
        font: "inherit",
        fontSize: 13,
        border: "none",
        outline: "none",
        background: "transparent",
        color: "var(--lx-text)",
        width: "100%",
        minWidth: 0,
      }}
    />
  </span>
);

/** Pill pagination. Active page is the dark pill; ends are labelled controls. */
export const Pagination = ({
  page,
  pageCount,
  onChange,
}: {
  page: number;
  pageCount: number;
  onChange: (page: number) => void;
}) => {
  if (pageCount <= 1) return null;
  // Window of at most 5 page numbers centered on the current page.
  const start = Math.max(1, Math.min(page - 2, pageCount - 4));
  const pages = Array.from({ length: Math.min(5, pageCount) }, (_, i) => start + i);

  const pill: CSSProperties = {
    font: "inherit",
    fontSize: 13,
    borderRadius: "var(--lx-radius-pill)",
    border: "1px solid var(--lx-border)",
    background: "var(--lx-card)",
    color: "var(--lx-text)",
    cursor: "pointer",
  };

  return (
    <nav aria-label="Paginasi" style={{ display: "flex", gap: 6, alignItems: "center" }}>
      <button
        type="button"
        style={{ ...pill, padding: "6px 14px", color: "var(--lx-muted)" }}
        disabled={page <= 1}
        onClick={() => onChange(page - 1)}
      >
        Sebelumnya
      </button>
      {pages.map((p) => (
        <button
          key={p}
          type="button"
          className="lx-mono"
          aria-current={p === page ? "page" : undefined}
          onClick={() => onChange(p)}
          style={{
            ...pill,
            padding: "6px 12px",
            ...(p === page
              ? {
                  background: "var(--lx-pill-active-bg)",
                  color: "var(--lx-pill-active-fg)",
                  border: "1px solid transparent",
                }
              : {}),
          }}
        >
          {p}
        </button>
      ))}
      <button
        type="button"
        style={{ ...pill, padding: "6px 14px" }}
        disabled={page >= pageCount}
        onClick={() => onChange(page + 1)}
      >
        Berikutnya
      </button>
    </nav>
  );
};
