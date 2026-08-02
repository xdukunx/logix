// The one data table. CSS-grid rows with hairline dividers and no zebra
// striping, wrapped in a card. Below 768px each row collapses to the two-line
// list form described in README §4 ("tabel jadi list dua baris per sesi").
import type { ReactNode } from "react";

import { useBreakpoint } from "./hooks";

export interface Column<T> {
  key: string;
  header: string;
  /** A CSS grid track, e.g. "150px" or "1.3fr". */
  width: string;
  align?: "left" | "right";
  render: (row: T) => ReactNode;
  /**
   * Where this column goes in the phone list form. `primary` is the bold first
   * line, `secondary` joins the muted second line. Omit to hide on phone.
   */
  phone?: "primary" | "secondary";
}

export function Table<T>({
  columns,
  rows,
  getRowKey,
  onRowClick,
  selectedKey,
  emptyLabel = "Tidak ada data untuk periode ini.",
}: {
  columns: Column<T>[];
  rows: T[];
  getRowKey: (row: T) => string;
  onRowClick?: (row: T) => void;
  selectedKey?: string | null;
  emptyLabel?: string;
}) {
  const isPhone = useBreakpoint() === "phone";
  const template = columns.map((c) => c.width).join(" ");

  if (rows.length === 0) {
    return (
      <div
        style={{
          background: "var(--lx-card)",
          borderRadius: "var(--lx-radius-card)",
          boxShadow: "var(--lx-shadow-card)",
          padding: "36px 20px",
          textAlign: "center",
          fontSize: 13.5,
          color: "var(--lx-muted)",
        }}
      >
        {emptyLabel}
      </div>
    );
  }

  if (isPhone) {
    const primary = columns.filter((c) => c.phone === "primary");
    const secondary = columns.filter((c) => c.phone === "secondary");
    return (
      <div style={{ display: "grid", gap: 8 }}>
        {rows.map((row) => (
          <div
            key={getRowKey(row)}
            className={onRowClick ? "lx-interactive" : undefined}
            onClick={onRowClick ? () => onRowClick(row) : undefined}
            style={{
              background: "var(--lx-card)",
              borderRadius: 14,
              boxShadow: "var(--lx-shadow-card)",
              padding: "13px 14px",
              minHeight: 52,
              cursor: onRowClick ? "pointer" : undefined,
            }}
          >
            <div style={{ display: "flex", gap: 8, fontSize: 13, fontWeight: 600, flexWrap: "wrap" }}>
              {primary.map((c) => (
                <span key={c.key}>{c.render(row)}</span>
              ))}
            </div>
            <div
              style={{
                display: "flex",
                gap: 6,
                fontSize: 12,
                color: "var(--lx-muted)",
                marginTop: 3,
                flexWrap: "wrap",
              }}
            >
              {secondary.map((c, i) => (
                <span key={c.key}>
                  {i > 0 && <span style={{ marginRight: 6 }}>·</span>}
                  {c.render(row)}
                </span>
              ))}
            </div>
          </div>
        ))}
      </div>
    );
  }

  return (
    <div
      role="table"
      style={{
        background: "var(--lx-card)",
        borderRadius: "var(--lx-radius-card)",
        boxShadow: "var(--lx-shadow-card)",
        overflow: "hidden",
      }}
    >
      <div
        role="row"
        style={{
          display: "grid",
          gridTemplateColumns: template,
          gap: 12,
          padding: "12px 20px",
          fontSize: 11,
          fontWeight: 600,
          letterSpacing: ".05em",
          textTransform: "uppercase",
          color: "var(--lx-muted)",
        }}
      >
        {columns.map((c) => (
          <span key={c.key} role="columnheader" style={{ textAlign: c.align ?? "left" }}>
            {c.header}
          </span>
        ))}
      </div>
      {rows.map((row) => {
        const key = getRowKey(row);
        const isSelected = selectedKey === key;
        return (
          <div
            key={key}
            role="row"
            className={onRowClick ? "lx-row-hover" : undefined}
            tabIndex={onRowClick ? 0 : undefined}
            onClick={onRowClick ? () => onRowClick(row) : undefined}
            onKeyDown={
              onRowClick
                ? (e) => {
                    if (e.key === "Enter" || e.key === " ") {
                      e.preventDefault();
                      onRowClick(row);
                    }
                  }
                : undefined
            }
            style={{
              display: "grid",
              gridTemplateColumns: template,
              gap: 12,
              padding: "13px 20px",
              borderTop: "1px solid var(--lx-hairline)",
              fontSize: 13.5,
              alignItems: "center",
              cursor: onRowClick ? "pointer" : undefined,
              background: isSelected ? "var(--lx-sunken)" : undefined,
              boxShadow: isSelected ? "inset 3px 0 0 var(--lx-accent)" : undefined,
            }}
          >
            {columns.map((c) => (
              <span
                key={c.key}
                role="cell"
                style={{
                  textAlign: c.align ?? "left",
                  minWidth: 0,
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                  whiteSpace: "nowrap",
                }}
              >
                {c.render(row)}
              </span>
            ))}
          </div>
        );
      })}
    </div>
  );
}
