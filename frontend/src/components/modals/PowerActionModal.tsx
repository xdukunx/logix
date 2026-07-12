// Power action modal (Action Modals §04, destructive template). Replaces the
// confirm()+prompt() pair for shutdown/restart/logoff. Reason is required.
import { useEffect, useState } from "react";
import { TextInput } from "@astryxdesign/core/TextInput";
import { PowerIcon } from "@heroicons/react/24/outline";

import ActionModal, { WarningNote } from "./ActionModal";

export type PowerAction = "shutdown" | "restart" | "logoff";

const COPY: Record<PowerAction, { verb: string; confirm: string }> = {
  shutdown: { verb: "Matikan", confirm: "Matikan Sekarang" },
  restart: { verb: "Mulai Ulang", confirm: "Mulai Ulang" },
  logoff: { verb: "Keluarkan Pengguna dari", confirm: "Keluarkan Pengguna" },
};

const SUBLABEL: Record<PowerAction, string> = {
  shutdown: "Shut Down",
  restart: "Restart",
  logoff: "Log Off",
};

export default function PowerActionModal({
  isOpen,
  onClose,
  hostname,
  deviceName,
  action,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  hostname: string;
  deviceName: string;
  action: PowerAction | null;
  onSubmit: (action: PowerAction, reason: string) => Promise<void> | void;
}) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (isOpen) setReason("");
  }, [isOpen]);

  if (!action) return null;
  const copy = COPY[action];
  const valid = reason.trim().length > 0;

  const submit = async () => {
    if (!valid) return;
    setBusy(true);
    try {
      await onSubmit(action, reason.trim());
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
      icon={<PowerIcon style={{ width: 20, height: 20 }} />}
      title={`${copy.verb} ${hostname}?`}
      subtitle={`${SUBLABEL[action]} · ${deviceName}`}
      confirmLabel={copy.confirm}
      onConfirm={submit}
      isConfirmDisabled={!valid}
      isConfirmLoading={busy}
    >
      <WarningNote>
        Pengguna <strong>diberi peringatan 30 detik</strong> untuk menyimpan pekerjaan sebelum
        perintah dijalankan. Sesi berjalan akan berakhir.
      </WarningNote>
      <TextInput
        label="Alasan · wajib"
        isRequired
        value={reason}
        onChange={setReason}
        placeholder="mis. Pemeliharaan terjadwal malam ini"
        hasAutoFocus
        onEnter={submit}
      />
    </ActionModal>
  );
}
