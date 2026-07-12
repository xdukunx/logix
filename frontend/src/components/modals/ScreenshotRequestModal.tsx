// Screenshot request modal (Action Modals §03, sensitive template). Replaces
// the prompt() reason. Privacy invariant: the note states the user is ALWAYS
// notified — no silent capture.
import { useEffect, useState } from "react";
import { TextInput } from "@astryxdesign/core/TextInput";
import { CameraIcon } from "@heroicons/react/24/outline";

import ActionModal, { PrivacyNote } from "./ActionModal";

export default function ScreenshotRequestModal({
  isOpen,
  onClose,
  deviceLabel,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  deviceLabel: string;
  onSubmit: (reason: string) => Promise<void> | void;
}) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (isOpen) setReason("");
  }, [isOpen]);

  const submit = async () => {
    setBusy(true);
    try {
      await onSubmit(reason.trim());
      onClose();
    } finally {
      setBusy(false);
    }
  };

  return (
    <ActionModal
      isOpen={isOpen}
      onClose={onClose}
      width={440}
      icon={<CameraIcon style={{ width: 20, height: 20 }} />}
      title="Minta Screenshot"
      subtitle={
        <>
          Perangkat: <strong>{deviceLabel}</strong>
        </>
      }
      confirmLabel="Minta Screenshot"
      onConfirm={submit}
      isConfirmLoading={busy}
    >
      <TextInput
        label="Alasan · kebijakan device dapat mewajibkan ini"
        value={reason}
        onChange={setReason}
        placeholder="mis. Verifikasi penggunaan lisensi software"
        hasAutoFocus
        onEnter={submit}
      />
      <PrivacyNote>
        <strong>Catatan privasi:</strong> Pengguna di perangkat SELALU diberi tahu — tidak pernah
        diam-diam. Permintaan dicatat di log audit.
      </PrivacyNote>
    </ActionModal>
  );
}
