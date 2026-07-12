// Emergency broadcast confirmation (Action Modals §05). The message is
// composed in the Monitoring emergency card; this modal is the deliberate
// "send to ALL active devices" confirmation step, with a live count + preview.
import { useState } from "react";
import { VStack } from "@astryxdesign/core/Stack";
import { Text } from "@astryxdesign/core/Text";
import { PaperAirplaneIcon } from "@heroicons/react/24/outline";

import ActionModal from "./ActionModal";

export default function EmergencyBroadcastModal({
  isOpen,
  onClose,
  activeCount,
  message,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  activeCount: number;
  message: string;
  onSubmit: () => Promise<void> | void;
}) {
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    setBusy(true);
    try {
      await onSubmit();
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
      tone="danger"
      icon={<PaperAirplaneIcon style={{ width: 20, height: 20 }} />}
      title="Kirim ke SEMUA perangkat aktif?"
      subtitle="Siaran darurat"
      confirmLabel={`Kirim ke ${activeCount} Perangkat`}
      confirmIcon={<PaperAirplaneIcon style={{ width: 15, height: 15 }} />}
      onConfirm={submit}
      isConfirmLoading={busy}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          background: "var(--lx-status-alert-bg)",
          border: "1px solid var(--lx-status-alert)",
          borderRadius: 8,
          padding: "10px 13px",
        }}
      >
        <span
          style={{
            fontSize: 22,
            fontWeight: 800,
            color: "var(--lx-status-alert)",
            letterSpacing: "-0.02em",
          }}
        >
          {activeCount}
        </span>
        <Text type="supporting">
          <span style={{ color: "var(--lx-status-alert-fg)", fontWeight: 600 }}>
            perangkat aktif akan menampilkan pesan ini secara langsung.
          </span>
        </Text>
      </div>
      <VStack gap={1}>
        <Text type="supporting" color="secondary">
          Pratinjau pesan
        </Text>
        <div
          style={{
            background: "var(--color-background-body)",
            border: "1px solid var(--color-border)",
            borderLeft: "3px solid var(--lx-status-alert)",
            borderRadius: 6,
            padding: "12px 14px",
          }}
        >
          <Text type="body">{message}</Text>
        </div>
      </VStack>
    </ActionModal>
  );
}
