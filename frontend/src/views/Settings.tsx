// Pengaturan -- sectioned LogixConfig editor persisted through GET/PUT
// /api/config. Design: docs/design_handoff_logix_v3/LogiX Devices & Settings
// v2.dc.html (D-05) + README section 3.
//
// Five sections; Perangkat is the one with new content -- the Idle auto-end
// policy. The whole loaded config is kept verbatim and spread back on save, so
// fields this UI doesn't render (text.*, requiredFields, locale, ...) survive
// a round trip untouched.
import { useCallback, useEffect, useMemo, useState } from "react";

import { getJson, sendJson } from "../api";
import type { LogixConfig } from "../types";
import { Callout, Card, ErrorState, Mono, PageHeader, SectionLabel } from "../ui/base";
import { Button, TextArea, TextField, Toggle } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { useToast } from "../ui/overlays";

type SectionKey = "branding" | "akses" | "perangkat" | "laporan" | "privasi";

const SECTIONS: { key: SectionKey; label: string; blurb: string }[] = [
  { key: "branding", label: "Branding", blurb: "Nama lab, subjudul, dan warna aksen." },
  { key: "akses", label: "Tipe Akses & Tujuan", blurb: "Daftar yang muncul di popup sign-in client." },
  { key: "perangkat", label: "Perangkat", blurb: "Kategori, penamaan, dan kebijakan sesi per-kategori." },
  { key: "laporan", label: "Laporan", blurb: "Isi default berkas ekspor." },
  { key: "privasi", label: "Privasi", blurb: "Apa yang dicatat, dan apa yang tidak." },
];

/** The three device categories the idle policy is keyed on. */
const IDLE_CATEGORIES = [
  { key: "gpu", label: "GPU", defaultHours: 2 },
  { key: "cpu", label: "CPU", defaultHours: 4 },
  { key: "custom", label: "Umum", defaultHours: 4 },
] as const;

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

// Removable chip + inline "Tambah" input -- the design's list editor.
const ChipsEditor = ({
  items,
  onChange,
  placeholder,
}: {
  items: string[];
  onChange: (next: string[]) => void;
  placeholder: string;
}) => {
  const [draft, setDraft] = useState("");
  const add = () => {
    const value = draft.trim();
    if (!value || items.includes(value)) return;
    onChange([...items, value]);
    setDraft("");
  };
  return (
    <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
      {items.map((item) => (
        <span
          key={item}
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 8,
            border: "1px solid var(--lx-border)",
            borderRadius: "var(--lx-radius-pill)",
            padding: "6px 14px",
            fontSize: 12.5,
          }}
        >
          {item}
          <button
            type="button"
            aria-label={`Hapus ${item}`}
            onClick={() => onChange(items.filter((i) => i !== item))}
            style={{
              font: "inherit",
              border: "none",
              background: "transparent",
              color: "var(--lx-muted)",
              cursor: "pointer",
              padding: 0,
              lineHeight: 1,
            }}
          >
            ✕
          </button>
        </span>
      ))}
      <input
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            add();
          }
        }}
        placeholder={placeholder}
        style={{
          font: "inherit",
          fontSize: 12.5,
          padding: "6px 14px",
          borderRadius: "var(--lx-radius-pill)",
          border: "1px dashed var(--lx-border-dashed)",
          background: "transparent",
          color: "var(--lx-text)",
          width: 160,
        }}
      />
    </div>
  );
};

const Group = ({
  title,
  blurb,
  isHighlighted,
  children,
}: {
  title: string;
  blurb?: string;
  isHighlighted?: boolean;
  children: React.ReactNode;
}) => (
  <Card padding="20px 24px" isSelected={isHighlighted} style={{ marginBottom: 16 }}>
    <div style={{ fontSize: 14.5, fontWeight: 600, marginBottom: 2 }}>{title}</div>
    {blurb && (
      <div style={{ fontSize: 13, color: "var(--lx-muted)", marginBottom: 14, lineHeight: 1.55 }}>{blurb}</div>
    )}
    {children}
  </Card>
);

export default function Settings() {
  const toast = useToast();
  const isDesktop = useBreakpoint() === "desktop";
  const [config, setConfig] = useState<LogixConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [section, setSection] = useState<SectionKey>("perangkat");
  const [isSaving, setSaving] = useState(false);

  const load = useCallback(async () => {
    try {
      setConfig(await getJson<LogixConfig>("/api/config", "Gagal memuat konfigurasi"));
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const idle = useMemo(() => readIdlePolicy(config), [config]);

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
      toast("Pengaturan tersimpan.");
    } catch (err) {
      toast((err as Error).message, "alert");
    } finally {
      setSaving(false);
    }
  };

  if (error) return <ErrorState description={error} onRetry={load} />;
  if (!config) return <Card padding="40px 24px">Memuat konfigurasi...</Card>;

  const active = SECTIONS.find((s) => s.key === section)!;

  const nav = (
    <nav aria-label="Bagian pengaturan" style={{ display: "grid", gap: 4 }}>
      {SECTIONS.map((s) => {
        const isActive = s.key === section;
        return (
          <button
            key={s.key}
            type="button"
            aria-current={isActive ? "true" : undefined}
            onClick={() => setSection(s.key)}
            style={{
              font: "inherit",
              textAlign: "left",
              fontSize: 13.5,
              fontWeight: isActive ? 600 : 400,
              padding: "9px 14px",
              borderRadius: "var(--lx-radius-control)",
              border: "none",
              background: isActive ? "var(--lx-pill-active-bg)" : "transparent",
              color: isActive ? "var(--lx-pill-active-fg)" : "var(--lx-muted)",
              cursor: "pointer",
              whiteSpace: "nowrap",
            }}
          >
            {s.label}
          </button>
        );
      })}
    </nav>
  );

  return (
    <>
      <PageHeader
        title="Pengaturan"
        summary={active.blurb}
        action={
          <Button
            label={isSaving ? "Menyimpan..." : "Simpan"}
            variant="primary"
            size="sm"
            disabled={isSaving}
            onClick={save}
          />
        }
      />

      <div style={{ display: "flex", gap: 20, alignItems: "flex-start" }}>
        <div
          style={
            isDesktop
              ? { width: 200, flexShrink: 0 }
              : { width: "100%", overflowX: "auto", marginBottom: 16 }
          }
        >
          {isDesktop ? nav : <div style={{ display: "flex", gap: 4 }}>{nav.props.children}</div>}
        </div>

        <div style={{ flex: 1, minWidth: 0, maxWidth: 780 }}>
          {section === "branding" && (
            <Group title="Identitas lab" blurb="Muncul di sidebar dasbor dan di kop laporan.">
              <div style={{ display: "grid", gap: 14 }}>
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
              </div>
            </Group>
          )}

          {section === "akses" && (
            <>
              <Group title="Tipe akses" blurb="Terdeteksi otomatis di client; daftar ini hanya untuk pelaporan.">
                <ChipsEditor
                  items={config.accessTypes ?? []}
                  onChange={(accessTypes) => patch({ accessTypes })}
                  placeholder="+ Tambah"
                />
              </Group>
              <Group title="Tujuan" blurb="Isi dropdown Tujuan di popup sign-in. Pengguna selalu bisa menulis sendiri lewat 'Lainnya'.">
                <ChipsEditor
                  items={config.purposes ?? []}
                  onChange={(purposes) => patch({ purposes })}
                  placeholder="+ Tambah"
                />
              </Group>
            </>
          )}

          {section === "perangkat" && (
            <>
              <Group title="Kategori perangkat" blurb="GPU · CPU · Umum — dipakai untuk filter dan kebijakan.">
                <ChipsEditor
                  items={config.devices?.device_types ?? []}
                  onChange={(device_types) =>
                    patch({ devices: { ...(config.devices ?? {}), device_types } })
                  }
                  placeholder="+ Tambah"
                />
              </Group>

              <Card padding="20px 24px" isSelected style={{ marginBottom: 16 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 2 }}>
                  <span style={{ fontSize: 14.5, fontWeight: 600 }}>Idle auto-end</span>
                  <span
                    className="lx-mono"
                    style={{
                      fontSize: 10.5,
                      fontWeight: 700,
                      letterSpacing: ".08em",
                      color: "var(--lx-accent)",
                      border: "1px solid var(--lx-accent)",
                      borderRadius: "var(--lx-radius-pill)",
                      padding: "2px 9px",
                    }}
                  >
                    BARU
                  </span>
                </div>
                <div style={{ fontSize: 13, color: "var(--lx-muted)", marginBottom: 16, lineHeight: 1.55 }}>
                  Tutup sesi otomatis setelah tidak ada aktivitas. Pengguna menerima notifikasi 5 menit sebelum
                  sesi ditutup — countdown darurat di client.
                </div>

                <div style={{ display: "grid" }}>
                  {IDLE_CATEGORIES.map((c) => {
                    const policy = idle[c.key];
                    return (
                      <div
                        key={c.key}
                        style={{
                          display: "flex",
                          alignItems: "center",
                          gap: 14,
                          padding: "13px 0",
                          borderTop: "1px solid var(--lx-hairline)",
                          flexWrap: "wrap",
                        }}
                      >
                        <Toggle
                          isOn={policy.enabled}
                          onChange={(enabled) => setIdle(c.key, { enabled })}
                          label={`Idle auto-end untuk ${c.label}`}
                        />
                        <span
                          style={{
                            fontSize: 13.5,
                            fontWeight: 600,
                            width: 64,
                            color: policy.enabled ? undefined : "var(--lx-muted)",
                          }}
                        >
                          {c.label}
                        </span>
                        {policy.enabled ? (
                          <>
                            <label
                              className="lx-mono"
                              style={{
                                display: "inline-flex",
                                alignItems: "center",
                                gap: 6,
                                fontSize: 13,
                                border: "1px solid var(--lx-border)",
                                borderRadius: "var(--lx-radius-control)",
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
                                  width: 34,
                                  border: "none",
                                  background: "transparent",
                                  color: "var(--lx-text)",
                                  outline: "none",
                                }}
                              />
                              jam
                            </label>
                            <span style={{ marginLeft: "auto", fontSize: 12, color: "var(--lx-muted)" }}>
                              notifikasi 5 mnt sebelum
                            </span>
                          </>
                        ) : (
                          <span style={{ fontSize: 13, color: "var(--lx-status-offline)" }}>
                            nonaktif — sesi berjalan sampai SELESAI ditekan
                          </span>
                        )}
                      </div>
                    );
                  })}
                </div>

                <div style={{ marginTop: 14 }}>
                  <Callout tone="warning">
                    Job komputasi panjang (training, DFT) tetap terhitung <strong>aktif</strong> — idle diukur
                    dari input + beban proses, bukan input saja.
                  </Callout>
                </div>
              </Card>

              <Group title="Penamaan stasiun">
                <TextField
                  label="Pola"
                  value={String(config.devices?.naming_pattern ?? "")}
                  onChange={(v) => patch({ devices: { ...(config.devices ?? {}), naming_pattern: v } })}
                  isMono
                  placeholder="WS-{nomor}"
                />
              </Group>
            </>
          )}

          {section === "laporan" && (
            <Group title="Isi laporan" blurb="Berlaku untuk ekspor Excel dari tab Riwayat.">
              <div style={{ display: "grid", gap: 12 }}>
                {(
                  [
                    ["include_branding", "Sertakan kop lab"],
                    ["include_purpose_summary", "Sertakan rekap per tujuan"],
                    ["include_device_summary", "Sertakan rekap per perangkat"],
                  ] as const
                ).map(([key, label]) => (
                  <label key={key} style={{ display: "flex", alignItems: "center", gap: 12, fontSize: 13.5 }}>
                    <Toggle
                      isOn={Boolean(config.reports?.[key])}
                      onChange={(v) => patch({ reports: { ...(config.reports ?? {}), [key]: v } })}
                      label={label}
                    />
                    {label}
                  </label>
                ))}
              </div>
            </Group>
          )}

          {section === "privasi" && (
            <>
              <Group title="Pemberitahuan privasi" blurb="Tampil di popup sign-in client, selalu terlihat.">
                <TextArea
                  label="Teks"
                  value={String(config.privacy?.notice ?? "")}
                  onChange={(v) => patch({ privacy: { ...(config.privacy ?? {}), notice: v } })}
                  rows={3}
                />
              </Group>
              <Group title="Mode dinding (/wall)" blurb="Layar TV read-only di lab.">
                <label style={{ display: "flex", alignItems: "center", gap: 12, fontSize: 13.5 }}>
                  <Toggle
                    isOn={Boolean((config.privacy as Record<string, unknown>)?.hide_names_on_wall)}
                    onChange={(v) =>
                      patch({ privacy: { ...(config.privacy ?? {}), hide_names_on_wall: v } })
                    }
                    label="Sembunyikan nama pengguna di mode dinding"
                  />
                  Sembunyikan nama pengguna di mode dinding
                </label>
                <div style={{ marginTop: 10 }}>
                  <SectionLabel>
                    Stasiun tetap tampil dengan ID <Mono>WS-xx</Mono> dan status.
                  </SectionLabel>
                </div>
              </Group>
            </>
          )}
        </div>
      </div>
    </>
  );
}
