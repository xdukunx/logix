// Settings tab: Branding, Popup Builder, Device Naming, Report Settings,
// and Privacy Notice -- persisted through GET/PUT /api/config. Fields this
// UI doesn't expose (text.*, requiredFields, ...) are preserved on save.
// Ported from server/static/js/settings.js.
import { useCallback, useEffect, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { CheckboxInput } from "@astryxdesign/core/CheckboxInput";
import { Grid } from "@astryxdesign/core/Grid";
import { IconButton } from "@astryxdesign/core/IconButton";
import { Selector } from "@astryxdesign/core/Selector";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";
import { TextArea } from "@astryxdesign/core/TextArea";
import { TextInput } from "@astryxdesign/core/TextInput";
import { useToast } from "@astryxdesign/core/Toast";
import { PlusIcon, TrashIcon } from "@heroicons/react/24/outline";

import { getJson, sendJson } from "../api";
import type { LogixConfig } from "../types";

const EditableList = ({
  title,
  items,
  onChange,
}: {
  title: string;
  items: string[];
  onChange: (items: string[]) => void;
}) => (
  <VStack gap={2}>
    <HStack gap={2} align="center" justify="between">
      <Text type="body"><strong>{title}</strong></Text>
      <Button
        label="Tambah"
        size="sm"
        variant="ghost"
        icon={<PlusIcon style={{ width: 14, height: 14 }} />}
        onClick={() => onChange([...items, ""])}
      />
    </HStack>
    {items.map((item, i) => (
      <HStack key={i} gap={2} align="center">
        <TextInput
          label={`${title} ${i + 1}`}
          isLabelHidden
          value={item}
          size="sm"
          onChange={(value) => onChange(items.map((it, j) => (j === i ? value : it)))}
        />
        <IconButton
          label="Hapus"
          size="sm"
          variant="ghost"
          icon={<TrashIcon style={{ width: 14, height: 14 }} />}
          onClick={() => onChange(items.filter((_, j) => j !== i))}
        />
      </HStack>
    ))}
  </VStack>
);

export default function Settings() {
  const toast = useToast();
  // Whole loaded config kept verbatim so saving never clobbers fields this
  // UI doesn't render.
  const [loadedConfig, setLoadedConfig] = useState<LogixConfig>({});

  const [logoText, setLogoText] = useState("");
  const [title, setTitle] = useState("");
  const [subtitle, setSubtitle] = useState("");
  const [colorPrimary, setColorPrimary] = useState("#073763");
  const [colorAccent, setColorAccent] = useState("#741B47");
  const [accessTypes, setAccessTypes] = useState("");
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

  const load = useCallback(async () => {
    try {
      // GET /api/config is unauthenticated by design (the agent popup reads it).
      const res = await fetch("/api/config");
      if (!res.ok) throw new Error("Gagal memuat konfigurasi");
      const cfg: LogixConfig = await res.json();
      setLoadedConfig(cfg);

      setLogoText(cfg.branding?.logoText || "");
      setTitle(cfg.branding?.title || "");
      setSubtitle(cfg.branding?.subtitle || "");
      setColorPrimary((cfg.branding?.colors?.primary || "#073763").toUpperCase());
      setColorAccent((cfg.branding?.colors?.accent || "#741B47").toUpperCase());
      setAccessTypes((cfg.accessTypes || []).join(", "));
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
      setLoadError(null);
    } catch (err) {
      setLoadError((err as Error).message);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const save = async () => {
    const clean = (items: string[]) => items.map((s) => s.trim()).filter(Boolean);
    const newConfig: LogixConfig = {
      ...loadedConfig,
      branding: {
        ...(loadedConfig.branding || {}),
        logoText: logoText.trim(),
        title: title.trim(),
        subtitle: subtitle.trim(),
        colors: {
          ...(loadedConfig.branding?.colors || {}),
          primary: colorPrimary,
          accent: colorAccent,
        },
      },
      accessTypes: accessTypes.split(",").map((s) => s.trim()).filter(Boolean),
      purposes: clean(purposes),
      devices: {
        device_types: clean(deviceTypes),
        naming_pattern: namingPattern.trim() || "{type} - {room} - {number}",
      },
      reports: {
        default_scope: reportScope,
        include_branding: reportBranding,
        include_purpose_summary: reportPurpose,
        include_device_summary: reportDevice,
      },
      privacy: {
        notice: privacyNotice.trim(),
        collected: clean(privacyCollected),
        not_collected: clean(privacyNotCollected),
      },
    };

    try {
      await sendJson("/api/config", "PUT", newConfig, "Gagal menyimpan konfigurasi ke server");
      setLoadedConfig(newConfig);
      toast({ body: "Pengaturan berhasil disimpan!" });
    } catch (err) {
      toast({ body: (err as Error).message, type: "error" });
    }
  };

  const firstPurpose = purposes.map((p) => p.trim()).filter(Boolean)[0];

  return (
    <VStack gap={6}>
      <HStack gap={3} align="center" justify="between">
        <Heading level={3}>Settings</Heading>
        <Button label="Simpan Pengaturan" variant="primary" onClick={save} />
      </HStack>

      {loadError && <Text type="body" color="secondary">{loadError}</Text>}

      <Grid columns={{ minWidth: 340, repeat: "fit" }} gap={4}>
        <Card padding={4}>
          <VStack gap={3}>
            <Heading level={5}>Branding</Heading>
            <TextInput label="Logo Text" value={logoText} onChange={setLogoText} />
            <TextInput label="Judul" value={title} onChange={setTitle} />
            <TextInput label="Subjudul" value={subtitle} onChange={setSubtitle} />
            <HStack gap={3}>
              <TextInput label="Warna Primer" value={colorPrimary} onChange={(v) => setColorPrimary(v.toUpperCase())} />
              <TextInput label="Warna Aksen" value={colorAccent} onChange={(v) => setColorAccent(v.toUpperCase())} />
            </HStack>
          </VStack>
        </Card>

        <Card padding={4}>
          <VStack gap={3}>
            <Heading level={5}>Popup Builder</Heading>
            <TextInput
              label="Tipe Akses (pisahkan dengan koma)"
              value={accessTypes}
              onChange={setAccessTypes}
              description="Contoh: SSH, AnyDesk, Physical"
            />
            <EditableList title="Tujuan Penggunaan" items={purposes} onChange={setPurposes} />
            <Card padding={3} variant="muted">
              <VStack gap={1}>
                <Text type="supporting" color="secondary">Pratinjau Popup</Text>
                <Text type="label">{title || "Report Logbook"}</Text>
                <Text type="supporting">Isi data penggunaan workstation sebelum memulai sesi.</Text>
                <Text type="supporting" color="secondary">
                  {firstPurpose ? `Tujuan Penggunaan (mis. ${firstPurpose})` : "Tujuan Penggunaan"}
                </Text>
              </VStack>
            </Card>
          </VStack>
        </Card>

        <Card padding={4}>
          <VStack gap={3}>
            <Heading level={5}>Device Naming</Heading>
            <EditableList title="Tipe Device" items={deviceTypes} onChange={setDeviceTypes} />
            <TextInput
              label="Pola Penamaan"
              value={namingPattern}
              onChange={setNamingPattern}
              description="Placeholder: {type}, {room}, {number}"
            />
          </VStack>
        </Card>

        <Card padding={4}>
          <VStack gap={3}>
            <Heading level={5}>Report Settings</Heading>
            <Selector
              label="Cakupan Default"
              value={reportScope}
              onChange={(v) => v && setReportScope(v)}
              options={[
                { value: "today", label: "Hari Ini" },
                { value: "all", label: "Semua Data" },
                { value: "range", label: "Rentang Tanggal" },
              ]}
            />
            <CheckboxInput label="Sertakan branding" value={reportBranding} onChange={setReportBranding} />
            <CheckboxInput label="Sertakan ringkasan tujuan" value={reportPurpose} onChange={setReportPurpose} />
            <CheckboxInput label="Sertakan ringkasan device" value={reportDevice} onChange={setReportDevice} />
          </VStack>
        </Card>

        <Card padding={4}>
          <VStack gap={3}>
            <Heading level={5}>Privacy Notice</Heading>
            <TextArea label="Pemberitahuan" value={privacyNotice} onChange={setPrivacyNotice} rows={4} />
            <EditableList title="Data yang Dikumpulkan" items={privacyCollected} onChange={setPrivacyCollected} />
            <EditableList title="Data yang TIDAK Dikumpulkan" items={privacyNotCollected} onChange={setPrivacyNotCollected} />
          </VStack>
        </Card>
      </Grid>
    </VStack>
  );
}
