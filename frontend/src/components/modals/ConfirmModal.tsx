// Generic confirmation modal — replaces confirm() for destructive/simple
// yes-no actions that need no free-text input. Built on the ActionModal shell.
import { useState, type ReactNode } from "react";
import { Text } from "@astryxdesign/core/Text";
import { ExclamationTriangleIcon, QuestionMarkCircleIcon } from "@heroicons/react/24/outline";

import ActionModal, { type ModalTone } from "./ActionModal";

export default function ConfirmModal({
  isOpen,
  onClose,
  title,
  subtitle,
  body,
  confirmLabel,
  tone = "danger",
  onConfirm,
}: {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  subtitle?: ReactNode;
  body?: ReactNode;
  confirmLabel: string;
  tone?: ModalTone;
  onConfirm: () => Promise<void> | void;
}) {
  const [busy, setBusy] = useState(false);
  const Icon = tone === "danger" ? ExclamationTriangleIcon : QuestionMarkCircleIcon;

  const submit = async () => {
    setBusy(true);
    try {
      await onConfirm();
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
      tone={tone}
      icon={<Icon style={{ width: 20, height: 20 }} />}
      title={title}
      subtitle={subtitle}
      confirmLabel={confirmLabel}
      onConfirm={submit}
      isConfirmLoading={busy}
    >
      {typeof body === "string" ? <Text type="body" color="secondary">{body}</Text> : body}
    </ActionModal>
  );
}
