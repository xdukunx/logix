// Settings tab (design: docs/design/LogiX Settings.dc.html). Sectioned
// LogixConfig editor — Branding (with a live preview), Access Types & Purposes,
// Devices, Reports, and Privacy — persisted through GET/PUT /api/config. The
// whole loaded config is kept verbatim and spread back on save, so fields this
// UI doesn't render (text.*, requiredFields, locale, …) are preserved.
import { useCallback, useEffect, useMemo, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { CheckboxInput } from "@astryxdesign/core/CheckboxInput";
import { SegmentedControl, SegmentedControlItem } from "@astryxdesign/core/SegmentedControl";
import { Selector } from "@astryxdesign/core/Selector";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";
import { TextArea } from "@astryxdesign/core/TextArea";
import { TextInput } from "@astryxdesign/core/TextInput";
import { useToast } from "@astryxdesign/core/Toast";
import { PlusIcon, XMarkIcon } from "@heroicons/react/24/outline";

import { sendJson } from "../api";
import ErrorState from "../components/states/ErrorState";
import type { LogixConfig } from "../types";

// Removable chip + inline "Tambah" input — the design's list editor.
const ChipsEditor = ({
  items,
  onChange,
  placeholder,
}: {
  items: string[];
  onChange: (items: string[]) => void;
  placeholder?: string;
}) => {
  const [draft, setDraft] = useState("");
  const add = () => {
    const v = draft.trim();
    if (!v) return;
    onChange([...items, v]);
    setDraft("");
  };
  return (
    <VStack gap={2}>
      {items.length > 0 && (
        <HStack gap={2} wrap="wrap">
          {items.map((it, i) => (
            <span
              key={i}
              style={{
                display: "inline-flex",
                alignItems: "center",
                gap: 6,
                padding: "5px 8px 5px 12px",
                borderRadius: 999,
                background: "var(--color-background-muted, var(--lx-skeleton-base))",
                border: "1px solid var(--color-border)",
                fontSize: 13,
                fontWeight: 600,
                color: "var(--color-text-primary)",
              }}
            >
              {it}
              <button
                onClick={() => onChange(items.filter((_, j) => j !== i))}
                aria-label={`Hapus ${it}`}
                style={{ border: "none", background: "transparent", cursor: "pointer", color: "var(--lx-text-muted)", display: "inline-flex", padding: 0 }}
              >
                <XMarkIcon style={{ width: 14, height: 14 }} />
              </button>
            </span>
          ))}
        </HStack>
      )}
      <HStack gap={2} align="center">
        <TextInput label="Tambah item" isLabelHidden value={draft} onChange={setDraft} onEnter={add} placeholder={placeholder} size="sm" />
        <Button label="Tambah" size="sm" variant="secondary" icon={<PlusIcon style={{ width: 14, height: 14 }} />} onClick={add} />
      </HStack>
    </VStack>
  );
};

type Section = "branding" | "access" | "devices" | "reports" | "privacy";

export default function Settings() {
  const toast = useToast();
  const [loadedConfig, setLoadedConfig] = useState<LogixConfig>({});
  const [savedJson, setSavedJson] = useState<string>("");
  const [section, setSection] = useState<Section>("branding");
  const [saving, setSaving] = useState(false);

  const [logoText, setLogoText] = useState("");
  const [title, setTitle] = useState("");
  const [subtitle, setSubtitle] = useState("");
  const [colorPrimary, setColorPrimary] = useState("#2563EB");
  const [colorAccent, setColorAccent] = useState("#16A34A");
  const [accessTypes, setAccessTypes] = useState<string[]>([]);
  const [purposes, setPurposes] = useState<string[]>([]);
  const [deviceTypes, setDeviceTypes] = useState<string[]>([]);
  const [namingPattern, setNamingPattern] = useState("{type} - {room} - {number}");
  const [reportScope, setReportScope] = useState("today");
  const [reportBranding, setReportBranding] = useState(true);
  const [reportPurpose, setReportPurpose] = useState(true);
  const [reportDevice, setReportDevice] = useState(true);
  const [privacyNotice, setPrivacyNotice] = useState("");
  const [privacyCollected, setPrivacyCollected] = useState<string[]>([]);
  const [privacyNotCollected, setPrivacyNotCollected] = useState<string[]>([]);
  const [loadError, setLoadError] = useState<string | null>(null);

  const applyConfig = useCallback((cfg: LogixConfig) => {
    setLoadedConfig(cfg);
    setLogoText(cfg.branding?.logoText || "");
    setTitle(cfg.branding?.title || "");
    setSubtitle(cfg.branding?.subtitle || "");
    setColorPrimary((cfg.branding?.colors?.primary || "#2563EB").toUpperCase());
    setColorAccent((cfg.branding?.colors?.accent || "#16A34A").toUpperCase());
    setAccessTypes(cfg.accessTypes || []);
    setPurposes(cfg.purposes || []);
    setDeviceTypes(cfg.devices?.device_types || []);
    setNamingPattern(cfg.devices?.naming_pattern || "{type} - {room} - {number}");
    setReportScope(cfg.reports?.default_scope || "today");
    setReportBranding(cfg.reports?.include_branding !== false);
    setReportPurpose(cfg.reports?.include_purpose_summary !== false);
    setReportDevice(cfg.reports?.include_device_summary !== false);
    setPrivacyNotice(cfg.privacy?.notice || "");
    setPrivacyCollected(cfg.privacy?.collected || []);
    setPrivacyNotCollected(cfg.privacy?.not_collected || []);
  }, []);

  const load = useCallback(async () => {
    try {
      // GET /api/config is unauthenticated by design (the agent popup reads it).
      const res = await fetch("/api/config");
      if (!res.ok) throw new Error("Gagal memuat konfigurasi");
      const cfg: LogixConfig = await res.json();
      applyConfig(cfg);
      setLoadError(null);
    } catch (err) {
      setLoadError((err as Error).message);
    }
  }, [applyConfig]);

  useEffect(() => { load(); }, [load]);

  // The config we'd PUT — built from form state, preserving unknown keys.
  const currentConfig = useMemo<LogixConfig>(() => {
    const clean = (items: string[]) => items.map((s) => s.trim()).filter(Boolean);
    return {
      ...loadedConfig,
      branding: {
        ...(loadedConfig.branding || {}),
        logoText: logoText.trim(),
        title: title.trim(),
        subtitle: subtitle.trim(),
        colors: { ...(loadedConfig.branding?.colors || {}), primary: colorPrimary, accent: colorAccent },
      },
      accessTypes: clean(accessTypes),
      purposes: clean(purposes),
      devices: { device_types: clean(deviceTypes), naming_pattern: namingPattern.trim() || "{type} - {room} - {number}" },
      reports: {
        default_scope: reportScope,
        include_branding: reportBranding,
        include_purpose_summary: reportPurpose,
        include_device_summary: reportDevice,
      },
      privacy: { notice: privacyNotice.trim(), collected: clean(privacyCollected), not_collected: clean(privacyNotCollected) },
    };
  }, [
    loadedConfig, logoText, title, subtitle, colorPrimary, colorAccent, accessTypes, purposes,
    deviceTypes, namingPattern, reportScope, reportBranding, reportPurpose, reportDevice,
    privacyNotice, privacyCollected, privacyNotCollected,
  ]);

  // Set the saved baseline once the loaded config has flowed into the form.
  useEffect(() => {
    if (Object.keys(loadedConfig).length > 0 && !savedJson) setSavedJson(JSON.stringify(currentConfig));
  }, [loadedConfig, currentConfig, savedJson]);

  const currentJson = JSON.stringify(currentConfig);
  const isDirty = savedJson !== "" && currentJson !== savedJson;

  const save = async () => {
    setSaving(true);
    try {
      await sendJson("/api/config", "PUT", currentConfig, "Gagal menyimpan konfigurasi ke server");
      setLoadedConfig(currentConfig);
      setSavedJson(JSON.stringify(currentConfig));
      toast({ body: "Perubahan disimpan." });
    } catch (err) {
      toast({ body: (err as Error).message, type: "error" });
    } finally {
      setSaving(false);
    }
  };

  const reset = () => applyConfig(loadedConfig);

  const namingExample = namingPattern
    .replace("{type}", "WS")
    .replace("{room}", "07")
    .replace("{number}", "GPU-A100");

  if (loadError) return <ErrorState title="Gagal memuat pengaturan" description={loadError} onRetry={load} />;

  return (
    <VStack gap={5}>
      {/* Header */}
      <HStack gap={3} align="center" justify="between" wrap="wrap">
        <VStack gap={1}>
          <Heading level={3}>Pengaturan</Heading>
          <Text type="supporting" color="secondary">
            Konfigurasi LogiX ·{" "}
            <span style={{ fontFamily: "ui-monospace, Consolas, monospace" }}>LogixConfig</span>
          </Text>
        </VStack>
        <HStack gap={2} align="center">
          {isDirty && (
            <span style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 12, fontWeight: 700, color: "var(--lx-status-locked-fg)", background: "var(--lx-status-locked-bg)", padding: "5px 11px", borderRadius: 999 }}>
              Perubahan belum disimpan
            </span>
          )}
          <Button label="Atur Ulang" variant="secondary" isDisabled={!isDirty} onClick={reset} />
          <Button label="Simpan Perubahan" variant="primary" isDisabled={!isDirty} isLoading={saving} onClick={save} />
        </HStack>
      </HStack>

      {/* Section nav */}
      <SegmentedControl label="Bagian pengaturan" value={section} onChange={(v) => setSection(v as Section)} size="sm">
        <SegmentedControlItem value="branding" label="Branding" />
        <SegmentedControlItem value="access" label="Tipe Akses & Tujuan" />
        <SegmentedControlItem value="devices" label="Perangkat" />
        <SegmentedControlItem value="reports" label="Laporan" />
        <SegmentedControlItem value="privacy" label="Privasi" />
      </SegmentedControl>

      {section === "branding" && (
        <div style={{ display: "grid", gridTemplateColumns: "minmax(280px, 1fr) minmax(240px, 320px)", gap: 16, alignItems: "start" }}>
          <Card padding={4}>
            <VStack gap={3}>
              <VStack gap={0.5}>
                <Heading level={6}>Branding</Heading>
                <Text type="supporting" color="secondary">Tampilan logo, judul, dan warna pada halaman masuk &amp; header.</Text>
              </VStack>
              <TextInput label="Teks Logo" value={logoText} onChange={setLogoText} placeholder="LOGIX" />
              <TextInput label="Judul" value={title} onChange={setTitle} />
              <TextInput label="Subjudul" value={subtitle} onChange={setSubtitle} />
              <HStack gap={3}>
                <TextInput label="Warna Primer" value={colorPrimary} onChange={(v) => setColorPrimary(v.toUpperCase())} startIcon={<span style={{ width: 16, height: 16, borderRadius: 4, background: colorPrimary, display: "inline-block", border: "1px solid var(--color-border)" }} />} />
                <TextInput label="Warna Aksen" value={colorAccent} onChange={(v) => setColorAccent(v.toUpperCase())} startIcon={<span style={{ width: 16, height: 16, borderRadius: 4, background: colorAccent, display: "inline-block", border: "1px solid var(--color-border)" }} />} />
              </HStack>
            </VStack>
          </Card>
          {/* Live preview */}
          <Card padding={4} variant="muted">
            <VStack gap={3} align="center">
              <Text type="supporting" color="secondary">Pratinjau Langsung</Text>
              <VStack gap={2} align="center" padding={4} style={{ background: "var(--color-background-surface)", border: "1px solid var(--color-border)", borderRadius: 12, width: "100%" }}>
                <span style={{ fontSize: 26, fontWeight: 800, letterSpacing: "0.2em", color: "var(--color-text-primary)" }}>
                  {(logoText || "LOGIX").slice(0, -1)}
                  <span style={{ color: colorPrimary }}>{(logoText || "LOGIX").slice(-1)}</span>
                </span>
                <Text type="supporting" color="secondary">{subtitle || "Lab Access Logbook"}</Text>
                <span style={{ marginTop: 4, display: "inline-flex", alignItems: "center", justifyContent: "center", padding: "9px 16px", borderRadius: 6, background: colorPrimary, color: "#fff", fontSize: 13, fontWeight: 600 }}>
                  Masuk
                </span>
                <span style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 12, color: "var(--lx-text-muted)" }}>
                  <span style={{ width: 10, height: 10, borderRadius: 3, background: colorAccent, display: "inline-block" }} />
                  Aksen
                </span>
              </VStack>
            </VStack>
          </Card>
        </div>
      )}

      {section === "access" && (
        <Card padding={4}>
          <VStack gap={4}>
            <VStack gap={0.5}>
              <Heading level={6}>Tipe Akses &amp; Tujuan</Heading>
              <Text type="supporting" color="secondary">
                Kelola opsi <span style={{ fontFamily: "ui-monospace, monospace" }}>accessTypes</span> dan dropdown{" "}
                <span style={{ fontFamily: "ui-monospace, monospace" }}>purposes</span>.
              </Text>
            </VStack>
            <VStack gap={2}>
              <Text type="label">Tipe Akses</Text>
              <ChipsEditor items={accessTypes} onChange={setAccessTypes} placeholder="mis. SSH" />
            </VStack>
            <VStack gap={2}>
              <Text type="label">Tujuan (dropdown)</Text>
              <ChipsEditor items={purposes} onChange={setPurposes} placeholder="mis. Simulasi DFT" />
            </VStack>
          </VStack>
        </Card>
      )}

      {section === "devices" && (
        <Card padding={4}>
          <VStack gap={4}>
            <VStack gap={0.5}>
              <Heading level={6}>Perangkat</Heading>
              <Text type="supporting" color="secondary">Kategori perangkat &amp; pola penamaan otomatis.</Text>
            </VStack>
            <VStack gap={2}>
              <Text type="label">Kategori Perangkat (device_types)</Text>
              <ChipsEditor items={deviceTypes} onChange={setDeviceTypes} placeholder="mis. lab_workstation" />
            </VStack>
            <TextInput label="Pola Penamaan" value={namingPattern} onChange={setNamingPattern} description="Placeholder: {type}, {room}, {number}" />
            <Text type="supporting" color="secondary">
              Contoh hasil: <strong>{namingExample}</strong>
            </Text>
          </VStack>
        </Card>
      )}

      {section === "reports" && (
        <Card padding={4}>
          <VStack gap={4}>
            <VStack gap={0.5}>
              <Heading level={6}>Laporan</Heading>
              <Text type="supporting" color="secondary">Isi default file ekspor.</Text>
            </VStack>
            <CheckboxInput label="Sertakan branding — logo & judul di kop laporan" value={reportBranding} onChange={setReportBranding} />
            <CheckboxInput label="Ringkasan tujuan — rekap sesi per tujuan" value={reportPurpose} onChange={setReportPurpose} />
            <CheckboxInput label="Ringkasan perangkat — jam per workstation" value={reportDevice} onChange={setReportDevice} />
            <Selector
              label="Cakupan default"
              value={reportScope}
              onChange={(v) => v && setReportScope(v)}
              options={[
                { value: "today", label: "Hari Ini" },
                { value: "all", label: "Semua Data" },
                { value: "range", label: "Rentang Tanggal" },
              ]}
            />
          </VStack>
        </Card>
      )}

      {section === "privacy" && (
        <Card padding={4}>
          <VStack gap={4}>
            <VStack gap={0.5}>
              <Heading level={6}>Privasi</Heading>
              <Text type="supporting" color="secondary">Teks pemberitahuan yang dilihat pengguna, dan apa yang dicatat — transparan.</Text>
            </VStack>
            <TextArea label="Teks Pemberitahuan Privasi" value={privacyNotice} onChange={setPrivacyNotice} rows={4} />
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 16 }}>
              <VStack gap={2}>
                <Text type="label">Yang dicatat</Text>
                <ChipsEditor items={privacyCollected} onChange={setPrivacyCollected} placeholder="mis. Identitas pengguna" />
              </VStack>
              <VStack gap={2}>
                <Text type="label">Yang TIDAK dicatat</Text>
                <ChipsEditor items={privacyNotCollected} onChange={setPrivacyNotCollected} placeholder="mis. Ketikan / keystroke" />
              </VStack>
            </div>
          </VStack>
        </Card>
      )}
    </VStack>
  );
}
