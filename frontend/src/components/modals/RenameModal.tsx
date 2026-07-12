// Rename device modal (Action Modals §01). Replaces the prompt() rename.
import { useEffect, useState } from "react";
import { TextInput } from "@astryxdesign/core/TextInput";
import { PencilSquareIcon } from "@heroicons/react/24/outline";

import ActionModal from "./ActionModal";

const MAX = 40;

export default function RenameModal({
  isOpen,
  onClose,
  hostname,
  currentName,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  hostname: string;
  currentName: string;
  onSubmit: (name: string) => Promise<void> | void;
}) {
  const [name, setName] = useState(currentName);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (isOpen) setName(currentName);
  }, [isOpen, currentName]);

  const trimmed = name.trim();
  const valid = trimmed.length > 0 && trimmed.length <= MAX;

  const submit = async () => {
    if (!valid) return;
    setBusy(true);
    try {
      await onSubmit(trimmed);
      onClose();
    } finally {
      setBusy(false);
    }
  };

  return (
    <ActionModal
      isOpen={isOpen}
      onClose={onClose}
      width={400}
      icon={<PencilSquareIcon style={{ width: 18, height: 18 }} />}
      iconSize={34}
      title="Ubah Nama Perangkat"
      confirmLabel="Simpan"
      onConfirm={submit}
      isConfirmDisabled={!valid}
      isConfirmLoading={busy}
    >
      <TextInput
        label="Nama tampilan"
        value={name}
        onChange={(v) => setName(v.slice(0, MAX))}
        description={`Nama tidak boleh kosong. Maks. ${MAX} karakter.`}
        placeholder={hostname}
        hasAutoFocus
        onEnter={submit}
      />
    </ActionModal>
  );
}
