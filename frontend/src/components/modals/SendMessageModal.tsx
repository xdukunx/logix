// Send-message modal (Action Modals §02). Replaces the prompt() message.
import { useEffect, useState } from "react";
import { HStack } from "@astryxdesign/core/Stack";
import { Text } from "@astryxdesign/core/Text";
import { TextArea } from "@astryxdesign/core/TextArea";
import { ChatBubbleLeftRightIcon, PaperAirplaneIcon } from "@heroicons/react/24/outline";

import ActionModal from "./ActionModal";

const MAX = 280;

export default function SendMessageModal({
  isOpen,
  onClose,
  deviceLabel,
  username,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  deviceLabel: string;
  username?: string | null;
  onSubmit: (message: string) => Promise<void> | void;
}) {
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (isOpen) setMessage("");
  }, [isOpen]);

  const trimmed = message.trim();
  const valid = trimmed.length > 0;

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
      width={420}
      icon={<ChatBubbleLeftRightIcon style={{ width: 18, height: 18 }} />}
      iconSize={34}
      title="Kirim Pesan"
      subtitle={
        <>
          Ke <strong>{deviceLabel}</strong>
          {username ? ` · ${username}` : ""}
        </>
      }
      confirmLabel="Kirim"
      confirmIcon={<PaperAirplaneIcon style={{ width: 15, height: 15 }} />}
      onConfirm={submit}
      isConfirmDisabled={!valid}
      isConfirmLoading={busy}
    >
      <TextArea
        label="Pesan"
        isLabelHidden
        value={message}
        onChange={(v) => setMessage(v.slice(0, MAX))}
        placeholder="Tulis pesan singkat untuk pengguna…"
        rows={4}
      />
      <HStack justify="between" align="center">
        <Text type="supporting" color="secondary">
          Pesan muncul sebagai notifikasi di layar pengguna.
        </Text>
        <Text type="supporting" color="secondary">
          <span style={{ fontFamily: "ui-monospace, Menlo, Consolas, monospace" }}>
            {message.length} / {MAX}
          </span>
        </Text>
      </HStack>
    </ActionModal>
  );
}
