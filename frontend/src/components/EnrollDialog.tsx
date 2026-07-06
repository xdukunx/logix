// "Enroll device" dialog: generates a per-device invite code via
// POST /api/enroll/invite (main.py) so an admin can hand a device its own
// revocable key at install time, instead of every device sharing one ingest
// key. The device redeems the code in its installer/setup window.
import { useState } from "react";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Dialog } from "@astryxdesign/core/Dialog";
import { Selector } from "@astryxdesign/core/Selector";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";
import { TextInput } from "@astryxdesign/core/TextInput";
import { useToast } from "@astryxdesign/core/Toast";
import { UserPlusIcon } from "@heroicons/react/24/outline";

import { sendJson } from "../api";
import { formatDateTime } from "../util";

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

export default function EnrollDialog({ onEnrolled }: { onEnrolled?: () => void }) {
  const toast = useToast();
  const [isOpen, setIsOpen] = useState(false);
  const [category, setCategory] = useState("lab_workstation");
  const [displayName, setDisplayName] = useState("");
  const [note, setNote] = useState("");
  const [invite, setInvite] = useState<Invite | null>(null);
  const [generating, setGenerating] = useState(false);

  const reset = () => {
    setInvite(null);
    setDisplayName("");
    setNote("");
    setCategory("lab_workstation");
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
      () => toast({ body: "Kode disalin." }),
      () => toast({ body: "Gagal menyalin kode.", type: "error" }),
    );
  };

  return (
    <>
      <Button
        label="Enroll Device"
        size="sm"
        icon={<UserPlusIcon style={{ width: 16, height: 16 }} />}
        onClick={() => {
          reset();
          setIsOpen(true);
        }}
      />

      <Dialog isOpen={isOpen} onOpenChange={setIsOpen} width={460}>
        <VStack gap={4}>
          <Heading level={5}>Enroll device baru</Heading>

          {invite ? (
            <VStack gap={3}>
              <Text type="body" color="secondary">
                Berikan kode ini ke installer device (kolom "Kode Enrollment"). Device akan menukarnya jadi API key sendiri yang bisa dicabut.
              </Text>
              <Card padding={4} variant="blue">
                <VStack gap={2} align="center">
                  <Text type="supporting" color="secondary">Kode Enrollment</Text>
                  <Heading level={4}>{invite.invite_code}</Heading>
                  <Badge variant="warning" label={`Kedaluwarsa ${formatDateTime(invite.expires_at)}`} />
                </VStack>
              </Card>
              <HStack gap={2} justify="end">
                <Button label="Salin Kode" variant="primary" onClick={copyCode} />
                <Button label="Buat Lagi" onClick={reset} />
              </HStack>
            </VStack>
          ) : (
            <VStack gap={3}>
              <Selector
                label="Kategori Device"
                value={category}
                onChange={(v) => v && setCategory(v)}
                options={CATEGORIES}
              />
              <TextInput
                label="Nama Device"
                value={displayName}
                onChange={setDisplayName}
                placeholder="mis. Lab PC 3 (dekat pintu)"
                isOptional
              />
              <TextInput
                label="Catatan"
                value={note}
                onChange={setNote}
                placeholder="Opsional — untuk catatan admin"
                isOptional
              />
              <HStack gap={2} justify="end">
                <Button label="Batal" onClick={() => setIsOpen(false)} />
                <Button label="Buat Kode" variant="primary" isLoading={generating} onClick={generate} />
              </HStack>
            </VStack>
          )}
        </VStack>
      </Dialog>
    </>
  );
}
