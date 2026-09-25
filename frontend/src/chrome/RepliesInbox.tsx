// Pesan -- the admin <-> workstation conversation, both sides of it.
//
// Reads GET /api/conversations, which pairs what the admin sent (BROADCAST
// rows) with what came back (device_replies), one thread per device. The inbox
// this replaced listed only the answers, and only once there was one: the
// admin never saw their own side, so a back-and-forth read as a pile of
// disconnected "OK"s. Messages still travel down the existing BROADCAST
// channel and appear in the workstation's timer widget.
//
// Polls every 20s for the count in the app chrome, every 4s while open. A
// reply lands on the server the moment the user sends it, so the poll is the
// only thing between an answer and the admin seeing it.
import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";

import { getJson, postEmpty, sendJson } from "../api";
import type { ConversationMessage, ConversationsPage, ConversationThread } from "../types";
import { Mono, SectionLabel, StatusDot } from "../ui/base";
import { Button, TextArea } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { Modal, useToast } from "../ui/overlays";
import { formatClock, formatLogTime, splitDeviceName, usePolling } from "../util";

const POLL_CLOSED_MS = 20000;
const POLL_OPEN_MS = 4000;

// What the device side has confirmed, in the admin's words. "done" means the
// message reached the workstation's inbox -- not that someone has read it.
const DELIVERY_LABEL: Record<string, string> = {
  queued: "menunggu perangkat",
  done: "terkirim ke perangkat",
  failed: "gagal terkirim",
  expired: "tidak terkirim · perangkat tidak online",
};

const deliveryLabel = (m: ConversationMessage): string =>
  m.to_all ? "broadcast ke semua stasiun" : DELIVERY_LABEL[m.status ?? ""] ?? "";

const isUndelivered = (m: ConversationMessage) => m.status === "failed" || m.status === "expired";

/** "14:02" today, "02/08 · 14:02" otherwise. */
const stamp = (iso: string) =>
  new Date(iso).toDateString() === new Date().toDateString() ? formatClock(iso) : formatLogTime(iso);

const Bubble = ({ m }: { m: ConversationMessage }) => {
  const isOut = m.direction === "out";
  const label = isOut ? deliveryLabel(m) : "";
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: isOut ? "flex-end" : "flex-start" }}>
      <div
        style={{
          maxWidth: "82%",
          padding: "8px 12px",
          borderRadius: 14,
          borderBottomRightRadius: isOut ? 4 : 14,
          borderBottomLeftRadius: isOut ? 14 : 4,
          fontSize: 13.5,
          lineHeight: 1.5,
          whiteSpace: "pre-wrap",
          overflowWrap: "anywhere",
          background: isOut ? "var(--lx-accent)" : "var(--lx-sunken)",
          color: isOut ? "var(--lx-on-accent)" : "var(--lx-text)",
          border: isOut ? "1px solid transparent" : "1px solid var(--lx-border)",
        }}
      >
        {m.text}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 3 }}>
        {isUndelivered(m) && <StatusDot status="alert" label="Tidak terkirim" />}
        <Mono style={{ fontSize: 11, color: "var(--lx-muted)" }}>
          {stamp(m.at)}
          {label ? ` · ${label}` : ""}
        </Mono>
      </div>
    </div>
  );
};

const ThreadRow = ({
  thread,
  isActive,
  onSelect,
}: {
  thread: ConversationThread;
  isActive: boolean;
  onSelect: () => void;
}) => {
  const last = thread.messages[thread.messages.length - 1];
  return (
    <button
      type="button"
      className="lx-tap"
      aria-current={isActive ? "true" : undefined}
      onClick={onSelect}
      style={{
        font: "inherit",
        textAlign: "left",
        width: "100%",
        display: "grid",
        gap: 3,
        padding: "9px 10px",
        borderRadius: "var(--lx-radius-control)",
        border: "none",
        background: isActive ? "var(--lx-sunken)" : "transparent",
        color: "var(--lx-text)",
        cursor: "pointer",
      }}
    >
      <span style={{ display: "flex", alignItems: "center", gap: 7 }}>
        <StatusDot status={thread.unread > 0 ? "active" : "idle"} />
        <Mono style={{ fontSize: 12.5, fontWeight: 600 }}>{splitDeviceName(thread.device_name).id}</Mono>
        <span style={{ flex: 1 }} />
        {last && <Mono style={{ fontSize: 10.5, color: "var(--lx-muted)" }}>{stamp(last.at)}</Mono>}
      </span>
      {last && (
        <span
          style={{
            fontSize: 12,
            color: "var(--lx-muted)",
            paddingLeft: 15,
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {last.direction === "out" ? "Anda: " : ""}
          {last.text}
        </span>
      )}
    </button>
  );
};

export default function RepliesInbox() {
  const toast = useToast();
  const isPhone = useBreakpoint() === "phone";
  const [page, setPage] = useState<ConversationsPage | null>(null);
  const [isOpen, setOpen] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [isSending, setSending] = useState(false);
  // Reply ids already sent to /read, so the 4s poll does not re-post them
  // (or retry forever for a role without replies_write).
  const markedRef = useRef(new Set<number>());
  const scrollRef = useRef<HTMLDivElement>(null);

  const refresh = useCallback(async () => {
    try {
      setPage(await getJson<ConversationsPage>("/api/conversations", "Gagal memuat pesan"));
    } catch {
      // Roles without replies_read get a 403; keep the last known state rather
      // than flashing an error into the app chrome. Same call as AlertsBell.
    }
  }, []);

  usePolling(refresh, isOpen ? POLL_OPEN_MS : POLL_CLOSED_MS);

  const threads = page?.threads ?? [];
  // Always an explicit pick, never "whichever thread is on top": the list is
  // sorted unread-first, so reading the top thread re-sorts it, and a default
  // of threads[0] would slide onto the next unread thread and mark THAT read
  // too -- one open silently cleared every thread's unread.
  const active = threads.find((t) => t.hostname === selected);

  // Reading a thread is what marks its replies read -- the same rule the
  // widget follows for the admin's messages.
  useEffect(() => {
    if (!isOpen || !active) return;
    const pending = active.messages.filter(
      (m) => m.direction === "in" && !m.read_at && m.reply_id && !markedRef.current.has(m.reply_id),
    );
    if (pending.length === 0) return;
    pending.forEach((m) => markedRef.current.add(m.reply_id!));
    Promise.all(
      pending.map((m) => postEmpty(`/api/replies/${m.reply_id}/read`, "Gagal menandai pesan").catch(() => {})),
    ).then(refresh);
  }, [isOpen, active, refresh]);

  const lastId = active?.messages[active.messages.length - 1]?.id;
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [lastId, active?.hostname, isOpen]);

  const close = () => {
    setOpen(false);
    setSelected(null);
    setDraft("");
  };

  const send = async () => {
    const text = draft.trim();
    if (!text || !active || isSending) return;
    setSending(true);
    try {
      await sendJson(
        "/api/control/broadcast",
        "POST",
        { hostname: active.hostname, param: text, reason: "Direction Message" },
        "Gagal mengirim pesan",
      );
      setDraft("");
      await refresh();
    } catch (err) {
      toast((err as Error).message, "alert");
    } finally {
      setSending(false);
    }
  };

  const onComposerKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      send();
    }
  };

  if (!page || threads.length === 0) return null;
  const unread = page.unread;

  const list = (
    <div style={{ display: "grid", gap: 2, alignContent: "start", overflowY: "auto", minHeight: 0 }}>
      {threads.map((t) => (
        <ThreadRow
          key={t.hostname}
          thread={t}
          isActive={t.hostname === active?.hostname}
          onSelect={() => {
            setSelected(t.hostname);
            setDraft("");
          }}
        />
      ))}
    </div>
  );

  const chat = active && (
    <div style={{ display: "flex", flexDirection: "column", minHeight: 0, minWidth: 0 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, paddingBottom: 10 }}>
        {isPhone && <Button label="Kembali" variant="ghost" size="sm" onClick={() => setSelected(null)} />}
        <Mono style={{ fontSize: 13, fontWeight: 600 }}>{active.device_name}</Mono>
      </div>
      <div
        ref={scrollRef}
        style={{
          flex: 1,
          minHeight: 0,
          overflowY: "auto",
          display: "grid",
          gap: 10,
          alignContent: "start",
          padding: "12px 4px",
          borderTop: "1px solid var(--lx-hairline)",
          borderBottom: "1px solid var(--lx-hairline)",
        }}
      >
        {active.messages.map((m) => (
          <Bubble key={m.id} m={m} />
        ))}
      </div>
      <div style={{ display: "grid", gap: 8, paddingTop: 12 }}>
        <TextArea
          label={`Balas ke ${splitDeviceName(active.device_name).id}`}
          value={draft}
          onChange={setDraft}
          onKeyDown={onComposerKey}
          placeholder="Muncul di widget timer pengguna. Enter kirim, Shift+Enter baris baru."
          rows={2}
          maxLength={280}
        />
        <div style={{ display: "flex", justifyContent: "flex-end" }}>
          <Button
            label={isSending ? "Mengirim..." : "Kirim"}
            variant="primary"
            size="sm"
            disabled={isSending || draft.trim().length === 0}
            onClick={send}
          />
        </div>
      </div>
    </div>
  );

  return (
    <>
      <button
        type="button"
        onClick={() => {
          setOpen(true);
          // Desktop opens straight onto the most urgent thread; a phone shows
          // the list first, since there is no room for both.
          if (!isPhone) setSelected(threads[0]?.hostname ?? null);
          refresh();
        }}
        style={{
          font: "inherit",
          display: "inline-flex",
          alignItems: "center",
          gap: 7,
          fontSize: 12,
          color: "var(--lx-muted)",
          background: "transparent",
          border: "none",
          padding: "4px 0",
          cursor: "pointer",
        }}
      >
        <StatusDot status={unread > 0 ? "active" : "idle"} />
        <span className="lx-mono">{unread || threads.length}</span>
        {unread > 0 ? "pesan baru" : "percakapan"}
      </button>

      <Modal
        isOpen={isOpen}
        onClose={close}
        title="Pesan"
        description="Percakapan dengan pengguna di tiap stasiun. Pesan muncul di widget timer mereka; balasannya kembali ke sini."
        width={isPhone ? 420 : 780}
        footer={<Button label="Tutup" variant="secondary" size="sm" onClick={close} />}
      >
        {isPhone ? (
          <div style={{ height: "60vh", display: "flex", flexDirection: "column" }}>{active ? chat : list}</div>
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: "230px 1fr", gap: 18, height: 480 }}>
            <div style={{ display: "flex", flexDirection: "column", minHeight: 0 }}>
              <SectionLabel>Stasiun</SectionLabel>
              {list}
            </div>
            {chat || <SectionLabel>Pilih stasiun untuk melihat percakapan</SectionLabel>}
          </div>
        )}
      </Modal>
    </>
  );
}
