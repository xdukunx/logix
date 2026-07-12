// "Daftarkan Perangkat" dialog (design: docs/design/LogiX Devices.dc.html §02).
// Generates a per-device invite code via POST /api/enroll/invite so an admin
// can hand a device its own revocable key at install time, instead of every
// device sharing one ingest key. The one-time code is shown once, with a live
// expiry countdown and a copy button; the device redeems it in its setup window.
import { useEffect, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Dialog } from "@astryxdesign/core/Dialog";
import { Selector } from "@astryxdesign/core/Selector";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";
import { TextInput } from "@astryxdesign/core/TextInput";
import { useToast } from "@astryxdesign/core/Toast";
import {
  CheckIcon,
  ClipboardDocumentIcon,
  ShieldExclamationIcon,
  UserPlusIcon,
} from "@heroicons/react/24/outline";

import { sendJson } from "../api";

// Values must match the server's CATEGORY_PROFILES (main.py).
const CATEGORIES = [
  { value: "lab_workstation", label: "Lab Workstation" },
  { value: "office_workstation", label: "Office Workstation" },
  { value: "loaned_laptop", label: "Laptop Pinjaman" },
  { value: "mobile_device", label: "Perangkat Mobile" },
  { value: "server", label: "Server" },
  { value: "custom", label: "Custom" },
];

interface Invite {
  invite_code: string;
  expires_at: string;
}

const useCountdown = (iso: string | null): string => {
  const [remaining, setRemaining] = useState("");
  useEffect(() => {
    if (!iso) return;
    const tick = () => {
      const ms = new Date(iso).getTime() - Date.now();
      if (ms <= 0) {
        setRemaining("Kedaluwarsa");
        return false;
      }
      const total = Math.floor(ms / 1000);
      setRemaining(`${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`);
      return true;
    };
    tick();
    const id = setInterval(() => {
      if (!tick()) clearInterval(id);
    }, 1000);
    return () => clearInterval(id);
  }, [iso]);
  return remaining;
};

export default function EnrollDialog({ onEnrolled }: { onEnrolled?: () => void }) {
  const toast = useToast();
  const [isOpen, setIsOpen] = useState(false);
  const [category, setCategory] = useState("lab_workstation");
  const [displayName, setDisplayName] = useState("");
  const [note, setNote] = useState("");
  const [invite, setInvite] = useState<Invite | null>(null);
  const [generating, setGenerating] = useState(false);
  const [copied, setCopied] = useState(false);

  const countdown = useCountdown(invite?.expires_at ?? null);

  const reset = () => {
    setInvite(null);
    setDisplayName("");
    setNote("");
    setCategory("lab_workstation");
    setCopied(false);
  };

  const generate = async () => {
    setGenerating(true);
    try {
      const res = await sendJson(
        "/api/enroll/invite",
        "POST",
        { category, display_name: displayName.trim(), note: note.trim() },
        "Gagal membuat kode enrollment",
      );
      setInvite(await res.json());
      onEnrolled?.();
    } catch (err) {
      toast({ body: (err as Error).message, type: "error" });
    } finally {
      setGenerating(false);
    }
  };

  const copyCode = () => {
    if (!invite) return;
    navigator.clipboard?.writeText(invite.invite_code).then(
      () => {
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      },
      () => toast({ body: "Gagal menyalin kode.", type: "error" }),
    );
  };

  const categoryLabel = CATEGORIES.find((c) => c.value === category)?.label ?? category;

  return (
    <>
      <Button
        label="Daftarkan Perangkat"
        size="sm"
        variant="primary"
        icon={<UserPlusIcon style={{ width: 16, height: 16 }} />}
        onClick={() => {
          reset();
          setIsOpen(true);
        }}
      />

      <Dialog isOpen={isOpen} onOpenChange={setIsOpen} width={460}>
        {invite ? (
          <VStack gap={4}>
            <VStack gap={0.5}>
              <Heading level={5}>Kode Undangan Dibuat</Heading>
              <Text type="supporting" color="secondary">
                {categoryLabel}
                {displayName ? ` · ${displayName}` : ""}
              </Text>
            </VStack>

            <VStack
              gap={2}
              align="center"
              padding={4}
              style={{ background: "var(--lx-accent-weak)", borderRadius: 12, border: "1px solid var(--color-border)" }}
            >
              <Text type="supporting" color="secondary">Kode sekali pakai</Text>
              <span style={{ fontSize: 32, fontWeight: 800, letterSpacing: "0.12em", fontFamily: "ui-monospace, Consolas, monospace", color: "var(--color-text-primary)" }}>
                {invite.invite_code}
              </span>
              <Button
                label={copied ? "Kode disalin" : "Salin"}
                size="sm"
                variant={copied ? "secondary" : "primary"}
                icon={copied ? <CheckIcon style={{ width: 15, height: 15 }} /> : <ClipboardDocumentIcon style={{ width: 15, height: 15 }} />}
                onClick={copyCode}
              />
              <Text type="supporting" color="secondary">
                Kedaluwarsa dalam{" "}
                <span style={{ fontFamily: "ui-monospace, Consolas, monospace", fontWeight: 700, color: "var(--lx-status-locked-fg)" }}>
                  {countdown}
                </span>
              </Text>
            </VStack>

            <HStack gap={2} align="start" style={{ background: "var(--lx-status-locked-bg)", borderRadius: 8, padding: "11px 13px" }}>
              <ShieldExclamationIcon style={{ width: 18, height: 18, color: "var(--lx-status-locked)", flexShrink: 0, marginTop: 1 }} />
              <Text type="supporting">
                <span style={{ color: "var(--lx-status-locked-fg)" }}>
                  Kode ini hanya ditampilkan sekali. Sampaikan langsung ke teknisi perangkat (tatap
                  muka / telepon) — jangan lewat chat publik.
                </span>
              </Text>
            </HStack>

            <HStack gap={2} justify="end">
              <Button label="Selesai" variant="primary" onClick={() => setIsOpen(false)} />
            </HStack>
          </VStack>
        ) : (
          <VStack gap={4}>
            <Heading level={5}>Daftarkan Perangkat</Heading>
            <Selector label="Kategori" value={category} onChange={(v) => v && setCategory(v)} options={CATEGORIES} />
            <TextInput
              label="Nama tampilan · opsional"
              value={displayName}
              onChange={setDisplayName}
              placeholder="mis. Lab PC 3 (dekat pintu)"
              isOptional
            />
            <TextInput
              label="Catatan · opsional"
              value={note}
              onChange={setNote}
              placeholder="Untuk catatan admin"
              isOptional
            />
            <HStack gap={2} justify="end">
              <Button label="Batal" variant="secondary" onClick={() => setIsOpen(false)} />
              <Button label="Buat Kode" variant="primary" isLoading={generating} onClick={generate} />
            </HStack>
          </VStack>
        )}
      </Dialog>
    </>
  );
}
