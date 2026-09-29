// Pengaturan -- sectioned LogixConfig editor persisted through GET/PUT
// /api/config. v4 "Denyut".
//
// The whole loaded config is kept verbatim and spread back on save, so fields
// this UI doesn't render (text.*, requiredFields, locale, ...) survive a round
// trip untouched. Beside the working copy we keep the last config the server
// confirmed: the difference between the two is what marks a section as
// unsaved in the section list and raises the save bar, and closing the tab
// with unsaved edits asks first.
import { useCallback, useEffect, useId, useMemo, useState, type CSSProperties, type ReactNode } from "react";

import { getJson, sendJson } from "../api";
import type { LogixConfig } from "../types";
import { Callout, Card, ErrorState, Mono, PageHeader, Skeleton, StatusDot } from "../ui/base";
import { Button, TextArea, TextField, Toggle } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { useToast } from "../ui/overlays";
import { BigNumber, CardTitle } from "../ui/viz";

type SectionKey = "branding" | "akses" | "perangkat" | "laporan" | "privasi";

const SECTIONS: { key: SectionKey; label: string; blurb: string; fields: (keyof LogixConfig)[] }[] = [
  { key: "branding", label: "Branding", blurb: "Judul dan subjudul yang dilihat pengguna.", fields: ["branding"] },
  {
    key: "akses",
    label: "Tipe Akses & Tujuan",
    blurb: "Daftar yang muncul di popup sign-in client.",
    fields: ["accessTypes", "purposes"],
  },
  {
    key: "perangkat",
    label: "Perangkat",
    blurb: "Kategori, penamaan, dan kebijakan sesi per-kategori.",
    fields: ["devices"],
  },
  { key: "laporan", label: "Laporan", blurb: "Isi default berkas ekspor.", fields: ["reports"] },
  {
    key: "privasi",
    label: "Privasi",
    blurb: "Pemberitahuan, mode dinding, dan retensi data pribadi.",
    fields: ["privacy"],
  },
];

/** The three device categories the idle policy is keyed on. */
const IDLE_CATEGORIES = [
  { key: "gpu", label: "GPU", defaultHours: 2 },
  { key: "cpu", label: "CPU", defaultHours: 4 },
  { key: "custom", label: "Umum", defaultHours: 4 },
] as const;

const REPORT_TOGGLES = [
  ["include_branding", "Sertakan kop lab"],
  ["include_purpose_summary", "Sertakan rekap per tujuan"],
  ["include_device_summary", "Sertakan rekap per perangkat"],
] as const;

/** ops/retention.py's fallback when privacy.retention_days is absent. */
const DEFAULT_RETENTION_DAYS = 365;

interface IdlePolicy {
  enabled: boolean;
  hours: number;
}

/**
 * Every category ships DISABLED. Turning idle auto-end on is an explicit
 * decision an admin makes per category -- a default that silently started
 * closing sessions would kill long-running jobs on upgrade.
 */
const readIdlePolicy = (config: LogixConfig | null): Record<string, IdlePolicy> => {
  const stored = ((config?.devices as Record<string, unknown> | undefined)?.idle_auto_end ?? {}) as Record<
    string,
    Partial<IdlePolicy>
  >;
  const out: Record<string, IdlePolicy> = {};
  for (const c of IDLE_CATEGORIES) {
    out[c.key] = {
      enabled: stored[c.key]?.enabled === true,
      hours: Number(stored[c.key]?.hours) > 0 ? Number(stored[c.key]?.hours) : c.defaultHours,
    };
  }
  return out;
};

// A field as this page reads it. Switching on a setting the stored config
// never had (an idle policy, a report flag) and back off again must not count
// as an unsaved change, and neither may key order. Keys the page does not
// render cannot differ, so they are left out.
const normalised = (config: LogixConfig, field: keyof LogixConfig): unknown => {
  if (field === "devices") {
    return [config.devices?.device_types ?? [], config.devices?.naming_pattern ?? "", readIdlePolicy(config)];
  }
  if (field === "reports") return REPORT_TOGGLES.map(([key]) => Boolean(config.reports?.[key]));
  return config[field];
};

const isSame = (a: LogixConfig, b: LogixConfig, field: keyof LogixConfig) =>
  JSON.stringify(normalised(a, field)) === JSON.stringify(normalised(b, field));

const HAIRLINE: CSSProperties = { borderTop: "1px solid var(--lx-hairline)" };
const MUTED_NOTE: CSSProperties = { fontSize: 13, color: "var(--lx-muted)", lineHeight: 1.55 };

/** Small mono tag: "BARU" on a new setting, "DIUBAH" on an unsaved section. */
const Tag = ({ tone, children }: { tone: "accent" | "ink"; children: ReactNode }) => (
  <span
    className="lx-mono lx-anim-tag"
    style={{
      fontSize: 10,
      fontWeight: 700,
      letterSpacing: ".08em",
      lineHeight: 1.5,
      padding: "1px 8px",
      borderRadius: "var(--lx-radius-pill)",
      background: tone === "accent" ? "var(--lx-accent)" : "var(--lx-ink)",
      color: tone === "accent" ? "var(--lx-on-accent)" : "var(--lx-on-ink)",
      whiteSpace: "nowrap",
    }}
  >
    {children}
  </span>
);

// Removable chips + an add field. Empty and duplicate entries are refused;
// a duplicate says so instead of silently doing nothing.
const ChipsEditor = ({
  items,
  onChange,
  addLabel,
}: {
  items: string[];
  onChange: (next: string[]) => void;
  addLabel: string;
}) => {
  const [draft, setDraft] = useState("");
  const errorId = useId();
  const value = draft.trim();
  const isDuplicate = value !== "" && items.includes(value);
  const add = () => {
    if (!value || isDuplicate) return;
    onChange([...items, value]);
    setDraft("");
  };
  return (
    <div>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
        {items.map((item) => (
          <span
            key={item}
            className="lx-anim-tag"
            style={{
              display: "inline-flex",
              alignItems: "center",
              gap: 6,
              background: "var(--lx-sunken)",
              borderRadius: "var(--lx-radius-pill)",
              padding: "5px 6px 5px 14px",
              fontSize: 13,
            }}
          >
            {item}
            <button
              type="button"
              className="lx-round"
              aria-label={`Hapus ${item}`}
              onClick={() => onChange(items.filter((i) => i !== item))}
              style={{
                font: "inherit",
                fontSize: 12,
                lineHeight: 1,
                width: 22,
                height: 22,
                borderRadius: "var(--lx-radius-pill)",
                border: "1px solid transparent",
                background: "transparent",
                color: "var(--lx-muted)",
                cursor: "pointer",
                padding: 0,
              }}
            >
              ✕
            </button>
          </span>
        ))}
        {items.length === 0 && (
          <span
            className="lx-hatch"
            style={{ fontSize: 12.5, color: "var(--lx-muted)", borderRadius: "var(--lx-radius-pill)", padding: "5px 14px" }}
          >
            Belum ada
          </span>
        )}
      </div>
      <div style={{ display: "flex", gap: 8, marginTop: 14 }}>
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              add();
            }
          }}
          aria-label={addLabel}
          aria-invalid={isDuplicate}
          aria-describedby={isDuplicate ? errorId : undefined}
          placeholder="Butir baru"
          style={{
            font: "inherit",
            fontSize: 13,
            padding: "7px 14px",
            borderRadius: "var(--lx-radius-pill)",
            border: `1px solid ${isDuplicate ? "var(--lx-status-alert)" : "var(--lx-border)"}`,
            background: "var(--lx-card)",
            color: "var(--lx-text)",
            flex: 1,
            minWidth: 0,
            maxWidth: 280,
          }}
        />
        <Button label="Tambah" size="sm" disabled={!value || isDuplicate} onClick={add} />
      </div>
      {isDuplicate && (
        <div id={errorId} role="alert" style={{ fontSize: 12, color: "var(--lx-status-alert)", marginTop: 6 }}>
          “{value}” sudah ada di daftar.
        </div>
      )}
    </div>
  );
};

/** A switch with its visible label; the whole row is the click target. */
const ToggleRow = ({ label, isOn, onChange }: { label: string; isOn: boolean; onChange: (v: boolean) => void }) => (
  <label style={{ display: "flex", alignItems: "center", gap: 12, fontSize: 14, padding: "12px 0", cursor: "pointer", ...HAIRLINE }}>
    <Toggle isOn={isOn} onChange={onChange} label={label} />
    {label}
  </label>
);

export default function Settings() {
  const toast = useToast();
  const breakpoint = useBreakpoint();
  const isDesktop = breakpoint === "desktop";
  const isPhone = breakpoint === "phone";
  const [config, setConfig] = useState<LogixConfig | null>(null);
  // What the server last confirmed (on load or on a successful save).
  const [saved, setSaved] = useState<LogixConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [section, setSection] = useState<SectionKey>("perangkat");
  const [isSaving, setSaving] = useState(false);

  const load = useCallback(async () => {
    try {
      const next = await getJson<LogixConfig>("/api/config", "Gagal memuat konfigurasi");
      setConfig(next);
      setSaved(next);
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const idle = useMemo(() => readIdlePolicy(config), [config]);

  const dirty = useMemo(
    () =>
      config && saved
        ? SECTIONS.filter((s) => s.fields.some((f) => !isSame(config, saved, f)))
        : [],
    [config, saved],
  );
  const isDirty = dirty.length > 0;

  // Closing the tab with unsaved edits asks first.
  useEffect(() => {
    if (!isDirty) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [isDirty]);

  const patch = (next: Partial<LogixConfig>) => setConfig((c) => ({ ...(c ?? {}), ...next }));

  const setIdle = (key: string, next: Partial<IdlePolicy>) => {
    const merged = { ...idle, [key]: { ...idle[key], ...next } };
    patch({ devices: { ...(config?.devices ?? {}), idle_auto_end: merged } as LogixConfig["devices"] });
  };

  const save = async () => {
    if (!config) return;
    setSaving(true);
    try {
      await sendJson("/api/config", "PUT", config, "Gagal menyimpan konfigurasi");
      setSaved(config);
      toast("Pengaturan tersimpan.");
    } catch (err) {
      toast((err as Error).message, "alert");
    } finally {
      setSaving(false);
    }
  };

  const active = SECTIONS.find((s) => s.key === section)!;

  const header = (
    <PageHeader
      title="Pengaturan"
      summary={config ? active.blurb : error ? undefined : "Memuat konfigurasi..."}
      action={
        <Button
          label={isSaving ? "Menyimpan..." : "Simpan"}
          variant={isDirty ? "primary" : "secondary"}
          size="sm"
          disabled={isSaving || !config}
          onClick={save}
        />
      }
    />
  );

  if (error) {
    return (
      <>
        {header}
        <ErrorState description={error} onRetry={load} />
      </>
    );
  }
  if (!config) {
    return (
      <>
        {header}
        <div style={{ display: "grid", gap: 16 }}>
          <Skeleton height={220} />
          <Skeleton height={140} />
        </div>
      </>
    );
  }

  const accessTypes = config.accessTypes ?? [];
  const purposes = config.purposes ?? [];
  const idleOn = IDLE_CATEGORIES.filter((c) => idle[c.key].enabled).length;
  const reportsOn = REPORT_TOGGLES.filter(([key]) => config.reports?.[key]).length;
  const hideNames = Boolean(config.privacy?.hide_names_on_wall);
  const retentionDays = Number(config.privacy?.retention_days ?? DEFAULT_RETENTION_DAYS);

  // One line of current state per section, so the list doubles as an overview.
  const sectionState: Record<SectionKey, ReactNode> = {
    branding: config.branding?.title || "Tanpa judul",
    akses: (
      <>
        <Mono>{accessTypes.length}</Mono> akses · <Mono>{purposes.length}</Mono> tujuan
      </>
    ),
    perangkat: (
      <>
        idle auto-end <Mono>{idleOn}/{IDLE_CATEGORIES.length}</Mono> aktif
      </>
    ),
    laporan: (
      <>
        <Mono>{reportsOn}/{REPORT_TOGGLES.length}</Mono> bagian disertakan
      </>
    ),
    privasi: hideNames ? "nama disembunyikan di dinding" : "nama tampil di dinding",
  };

  // Desktop: a column of cards, each with a line of current state. Narrower
  // screens: a wrapping pill row, where an unsaved section gets a dot.
  const nav = (
    <nav
      aria-label="Bagian pengaturan"
      style={
        isDesktop
          ? { display: "grid", gap: 8, position: "sticky", top: 24 }
          : { display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 14 }
      }
    >
      {SECTIONS.map((s, i) => {
        const isActive = s.key === section;
        const isChanged = dirty.includes(s);
        return (
          <button
            key={s.key}
            type="button"
            aria-current={isActive ? "true" : undefined}
            className={isDesktop ? "lx-interactive lx-rise" : "lx-tap"}
            onClick={() => setSection(s.key)}
            style={
              {
                "--i": i,
                font: "inherit",
                textAlign: "left",
                padding: isDesktop ? "12px 16px" : "8px 16px",
                borderRadius: isDesktop ? 18 : "var(--lx-radius-pill)",
                border: "none",
                background: isActive ? "var(--lx-pill-active-bg)" : "var(--lx-card)",
                color: isActive ? "var(--lx-pill-active-fg)" : isDesktop ? "var(--lx-text)" : "var(--lx-muted)",
                cursor: "pointer",
              } as CSSProperties
            }
          >
            <span style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13.5, fontWeight: 600, whiteSpace: "nowrap" }}>
              {s.label}
              {isChanged &&
                (isDesktop ? (
                  <span style={{ marginLeft: "auto" }}>
                    <Tag tone={isActive ? "accent" : "ink"}>DIUBAH</Tag>
                  </span>
                ) : (
                  <span
                    role="img"
                    aria-label="belum disimpan"
                    className="lx-anim-dot"
                    style={{
                      width: 7,
                      height: 7,
                      borderRadius: "var(--lx-radius-pill)",
                      background: isActive ? "var(--lx-pill-active-fg)" : "var(--lx-ink)",
                    }}
                  />
                ))}
            </span>
            {isDesktop && (
              <span
                style={{
                  display: "block",
                  fontSize: 12,
                  marginTop: 2,
                  opacity: isActive ? 0.7 : 1,
                  color: isActive ? undefined : "var(--lx-muted)",
                  whiteSpace: "nowrap",
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                }}
              >
                {sectionState[s.key]}
              </span>
            )}
          </button>
        );
      })}
    </nav>
  );

  const span = (desktop: number, tablet: 1 | 2) =>
    isDesktop ? `span ${desktop}` : breakpoint === "tablet" ? `span ${tablet}` : undefined;

  // A bento card: title row, optional one-line explanation, content.
  const panel = (
    index: number,
    column: string | undefined,
    title: ReactNode,
    blurb: ReactNode,
    children: ReactNode,
    action?: ReactNode,
  ) => (
    <Card
      padding={isPhone ? "18px 16px" : "20px 22px 22px"}
      className="lx-rise"
      style={{ gridColumn: column, "--i": index + 1 } as CSSProperties}
    >
      <CardTitle action={action}>{title}</CardTitle>
      {blurb && <div style={{ ...MUTED_NOTE, margin: "-8px 0 14px" }}>{blurb}</div>}
      {children}
    </Card>
  );
  // Card-corner tally, e.g. "6 kategori" or "0/3 aktif".
  const count = (n: number, noun: string, total?: number) => (
    <span style={{ fontSize: 12.5, color: "var(--lx-muted)" }}>
      <Mono style={{ color: "var(--lx-text)" }}>{n}</Mono>
      {total !== undefined && <Mono>/{total}</Mono>} {noun}
    </span>
  );

  const content: Record<SectionKey, ReactNode> = {
    branding: panel(
      0,
      span(12, 2),
      "Identitas lab",
      "Judul dan subjudul tampil di popup sign-in client; subjudul juga menjadi nama lab di mode dinding.",
      <div style={{ display: "grid", gridTemplateColumns: isPhone ? "1fr" : "repeat(2, minmax(0, 1fr))", gap: 14 }}>
        <TextField
          label="Judul"
          value={String(config.branding?.title ?? "")}
          onChange={(v) => patch({ branding: { ...(config.branding ?? {}), title: v } })}
        />
        <TextField
          label="Subjudul"
          value={String(config.branding?.subtitle ?? "")}
          onChange={(v) => patch({ branding: { ...(config.branding ?? {}), subtitle: v } })}
        />
      </div>,
    ),

    akses: (
      <>
        {panel(
          0,
          span(6, 1),
          "Tipe akses",
          "Terdeteksi otomatis di client; daftar ini hanya untuk pelaporan.",
          <ChipsEditor items={accessTypes} onChange={(next) => patch({ accessTypes: next })} addLabel="Tambah tipe akses" />,
          count(accessTypes.length, "tipe"),
        )}
        {panel(
          1,
          span(6, 1),
          "Tujuan",
          "Isi dropdown Tujuan di popup sign-in. Pengguna selalu bisa menulis sendiri lewat 'Lainnya'.",
          <ChipsEditor items={purposes} onChange={(next) => patch({ purposes: next })} addLabel="Tambah tujuan" />,
          count(purposes.length, "tujuan"),
        )}
      </>
    ),

    perangkat: (
      <>
        {panel(
          0,
          span(12, 2),
          <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
            Idle auto-end <Tag tone="accent">BARU</Tag>
          </span>,
          "Tutup sesi otomatis setelah tidak ada aktivitas. Pengguna menerima notifikasi 5 menit sebelum sesi ditutup — countdown darurat di client.",
          <>
            {IDLE_CATEGORIES.map((c) => {
              const policy = idle[c.key];
              return (
                <div
                  key={c.key}
                  style={{ display: "flex", alignItems: "center", gap: "10px 16px", flexWrap: "wrap", padding: "12px 0", ...HAIRLINE }}
                >
                  <label
                    style={{
                      display: "inline-flex",
                      alignItems: "center",
                      gap: 12,
                      width: 110,
                      fontSize: 14,
                      fontWeight: 600,
                      cursor: "pointer",
                      color: policy.enabled ? undefined : "var(--lx-muted)",
                    }}
                  >
                    <Toggle
                      isOn={policy.enabled}
                      onChange={(enabled) => setIdle(c.key, { enabled })}
                      label={`Idle auto-end untuk ${c.label}`}
                    />
                    {c.label}
                  </label>
                  {policy.enabled ? (
                    <>
                      <label
                        className="lx-mono lx-anim-tag"
                        style={{
                          display: "inline-flex",
                          alignItems: "center",
                          gap: 6,
                          width: 96,
                          fontSize: 14,
                          border: "1px solid var(--lx-border)",
                          borderRadius: "var(--lx-radius-pill)",
                          padding: "5px 14px",
                        }}
                      >
                        <input
                          type="number"
                          min={1}
                          max={24}
                          value={policy.hours}
                          aria-label={`Ambang idle ${c.label} dalam jam`}
                          onChange={(e) => setIdle(c.key, { hours: Number(e.target.value) })}
                          style={{
                            font: "inherit",
                            width: 40,
                            border: "none",
                            background: "transparent",
                            color: "var(--lx-text)",
                            outline: "none",
                          }}
                        />
                        jam
                      </label>
                      <span style={{ fontSize: 12.5, color: "var(--lx-muted)" }}>
                        ditutup setelah <Mono style={{ color: "var(--lx-text)" }}>{policy.hours}</Mono> jam tanpa
                        aktivitas · notifikasi <Mono>5</Mono> mnt sebelum
                      </span>
                    </>
                  ) : (
                    <>
                      {/* Hatched: the slot a threshold would fill, not in use. */}
                      <span
                        className="lx-hatch"
                        aria-hidden="true"
                        style={{ width: 96, height: 32, borderRadius: "var(--lx-radius-pill)" }}
                      />
                      <span style={{ fontSize: 12.5, color: "var(--lx-muted)" }}>
                        nonaktif — sesi berjalan sampai SELESAI ditekan
                      </span>
                    </>
                  )}
                </div>
              );
            })}
            <div style={{ marginTop: 6 }}>
              <Callout tone="warning">
                Job komputasi panjang (training, DFT) tetap terhitung <strong>aktif</strong> — idle diukur dari
                input + beban proses, bukan input saja.
              </Callout>
            </div>
          </>,
          count(idleOn, "aktif", IDLE_CATEGORIES.length),
        )}
        {panel(
          1,
          span(7, 1),
          "Kategori perangkat",
          "Jenis perangkat di lab ini.",
          <ChipsEditor
            items={config.devices?.device_types ?? []}
            onChange={(device_types) => patch({ devices: { ...(config.devices ?? {}), device_types } })}
            addLabel="Tambah kategori"
          />,
          count(config.devices?.device_types?.length ?? 0, "kategori"),
        )}
        {panel(
          2,
          span(5, 1),
          "Penamaan stasiun",
          null,
          <TextField
            label="Pola"
            value={String(config.devices?.naming_pattern ?? "")}
            onChange={(v) => patch({ devices: { ...(config.devices ?? {}), naming_pattern: v } })}
            isMono
            placeholder="WS-{nomor}"
          />,
        )}
      </>
    ),

    laporan: panel(
      0,
      span(12, 2),
      "Isi laporan",
      "Berlaku untuk ekspor Excel dari tab Riwayat.",
      <div>
        {REPORT_TOGGLES.map(([key, label]) => (
          <ToggleRow
            key={key}
            label={label}
            isOn={Boolean(config.reports?.[key])}
            onChange={(v) => patch({ reports: { ...(config.reports ?? {}), [key]: v } })}
          />
        ))}
      </div>,
      count(reportsOn, "disertakan", REPORT_TOGGLES.length),
    ),

    privasi: (
      <>
        {panel(
          0,
          span(6, 1),
          "Pemberitahuan privasi",
          "Tampil di popup sign-in client, selalu terlihat.",
          <TextArea
            label="Teks"
            value={String(config.privacy?.notice ?? "")}
            onChange={(v) => patch({ privacy: { ...(config.privacy ?? {}), notice: v } })}
            rows={3}
          />,
        )}
        {panel(
          1,
          span(6, 1),
          "Mode dinding (/wall)",
          "Layar TV read-only di lab.",
          <>
            <ToggleRow
              label="Sembunyikan nama pengguna di mode dinding"
              isOn={hideNames}
              onChange={(v) => patch({ privacy: { ...(config.privacy ?? {}), hide_names_on_wall: v } })}
            />
            <div
              aria-hidden="true"
              style={{
                display: "flex",
                alignItems: "center",
                gap: 10,
                background: "var(--lx-sunken)",
                borderRadius: 16,
                padding: "10px 14px",
                marginTop: 4,
                fontSize: 13,
              }}
            >
              <StatusDot status="active" />
              <Mono style={{ fontWeight: 700 }}>WS-01</Mono>
              <span key={String(hideNames)} className="lx-anim-tag" style={{ fontWeight: hideNames ? 500 : 650 }}>
                {hideNames ? "Sesi berjalan" : "Nama pengguna"}
              </span>
            </div>
            <div style={{ fontSize: 12, color: "var(--lx-muted)", marginTop: 8 }}>
              Stasiun tetap tampil dengan ID <Mono>WS-xx</Mono> dan status.
            </div>
          </>,
        )}
        {/* Read-only on purpose: 0 turns purging of student names and NIMs
            off entirely, a choice the runbook wants made deliberately in
            server_config.json rather than by a stray keystroke here. */}
        {panel(
          2,
          span(12, 2),
          "Retensi data pribadi",
          null,
          <>
            {retentionDays > 0 ? (
              <BigNumber value={retentionDays} size={46} suffix="hari" />
            ) : (
              <span className="lx-big" style={{ fontSize: 34 }}>
                Tanpa batas
              </span>
            )}
            <div style={{ ...MUTED_NOTE, marginTop: 10 }}>
              {retentionDays > 0
                ? "Setelahnya nama, NIM, username Windows, dan keterangan disamarkan. Waktu, stasiun, tujuan, dan durasi sesi tetap untuk laporan."
                : "Penyamaran otomatis nonaktif: data pribadi tidak pernah disamarkan."}
            </div>
            <div style={{ fontSize: 12, color: "var(--lx-muted)", marginTop: 10 }}>
              Diatur lewat <Mono>privacy.retention_days</Mono>, dijalankan oleh <Mono>ops/retention.py</Mono>.
            </div>
          </>,
        )}
      </>
    ),
  };

  return (
    <>
      {header}

      <div style={{ display: isDesktop ? "flex" : "block", gap: 20, alignItems: "flex-start" }}>
        <div style={isDesktop ? { width: 236, flexShrink: 0, alignSelf: "stretch" } : undefined}>{nav}</div>

        <div style={{ flex: 1, minWidth: 0 }}>
          <div
            key={section}
            style={{
              display: "grid",
              gridTemplateColumns: isDesktop ? "repeat(12, 1fr)" : breakpoint === "tablet" ? "1fr 1fr" : "1fr",
              gap: isPhone ? 10 : 16,
            }}
          >
            {content[section]}
          </div>

          {isDirty && (
            // Sticky, so the save is reachable from the bottom of a long
            // section. On phones it clears the app's bottom tab bar.
            <div
              className="lx-rise"
              style={{
                position: "sticky",
                bottom: isPhone ? 76 : 16,
                zIndex: 10,
                marginTop: 16,
                display: "flex",
                alignItems: "center",
                gap: "8px 12px",
                flexWrap: "wrap",
                background: "var(--lx-ink)",
                color: "var(--lx-on-ink)",
                borderRadius: 22,
                padding: "10px 10px 10px 20px",
                boxShadow: "var(--lx-shadow-menu)",
                fontSize: 13,
              }}
            >
              <span role="status" style={{ display: "inline-flex", alignItems: "center", gap: 10, minWidth: 0, flex: 1 }}>
                <span
                  aria-hidden="true"
                  style={{
                    width: 8,
                    height: 8,
                    borderRadius: "var(--lx-radius-pill)",
                    background: "currentColor",
                    flexShrink: 0,
                  }}
                />
                <span>
                  <strong>Belum disimpan</strong>
                  <span style={{ opacity: 0.7 }}> · {dirty.map((s) => s.label).join(", ")}</span>
                </span>
              </span>
              <span style={{ display: "inline-flex", gap: 6, marginLeft: "auto" }}>
                <Button
                  label="Urungkan"
                  variant="ghost"
                  size="sm"
                  disabled={isSaving}
                  onClick={() => setConfig(saved)}
                  style={{ color: "var(--lx-on-ink)" }}
                />
                <Button
                  label={isSaving ? "Menyimpan..." : "Simpan"}
                  variant="primary"
                  size="sm"
                  disabled={isSaving}
                  onClick={save}
                />
              </span>
            </div>
          )}
        </div>
      </div>
    </>
  );
}
