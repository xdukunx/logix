// Balasan pengguna -- the other half of the admin<->workstation conversation.
//
// The server has had /api/replies since Logix Control shipped, and the agent
// has been posting to it (windows/logbook_common.ps1, Send-LogbookReply). The
// v3 dashboard rebuild simply never carried the surface over from the legacy
// UI (server/static/js/monitoring.js), so a user could answer a broadcast and
// nobody would ever see it -- which reads, from the workstation, exactly like
// "balasannya ga kekirim ke server".
//
// Modelled on AlertsBell deliberately: same chrome affordance (8px dot + mono
// count), same modal, same vocabulary. This is a thread list, not a chat app:
// grouped per device, newest first, with a reply box that sends the answer
// back down the existing BROADCAST channel.
import { useCallback, useMemo, useState } from "react";

import { getJson, postEmpty, sendJson } from "../api";
import type { Reply, RepliesPage } from "../types";
import { Mono, SectionLabel, StatusDot } from "../ui/base";
import { Button, TextArea } from "../ui/controls";
import { Modal, useToast } from "../ui/overlays";
import { formatLogTime, usePolling } from "../util";

interface Thread {
  hostname: string;
  deviceName: string;
  replies: Reply[];
  unread: number;
}

export default function RepliesInbox() {
  const toast = useToast();
  const [page, setPage] = useState<RepliesPage | null>(null);
  const [isOpen, setOpen] = useState(false);
  // Which thread has its compose box open, and what is in it.
  const [composeFor, setComposeFor] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [isSending, setSending] = useState(false);

  const refresh = useCallback(async () => {
    try {
      setPage(await getJson<RepliesPage>("/api/replies?limit=100", "Gagal memuat balasan"));
    } catch {
      // Roles without replies_read get a 403; keep the last known list rather
      // than flashing an error into the app chrome. Same call as AlertsBell.
    }
  }, []);

  usePolling(refresh, 20000);

  const threads = useMemo<Thread[]>(() => {
    const byHost = new Map<string, Thread>();
    for (const r of page?.replies ?? []) {
      const t = byHost.get(r.hostname) ?? {
        hostname: r.hostname,
        deviceName: r.device_name || r.hostname,
        replies: [],
        unread: 0,
      };
      t.replies.push(r);
      if (!r.read_at) t.unread += 1;
      byHost.set(r.hostname, t);
    }
    // Unread first, then most recent activity -- the order an admin triages in.
    return [...byHost.values()].sort(
      (a, b) =>
        b.unread - a.unread ||
        (b.replies[0]?.created_at ?? "").localeCompare(a.replies[0]?.created_at ?? ""),
    );
  }, [page]);

  const unread = page?.unread ?? 0;
  if (!page || page.replies.length === 0) return null;

  const markThreadRead = async (thread: Thread) => {
    const pending = thread.replies.filter((r) => !r.read_at);
    if (pending.length === 0) return;
    await Promise.all(
      pending.map((r) => postEmpty(`/api/replies/${r.id}/read`, "Gagal menandai balasan").catch(() => {})),
    );
    refresh();
  };

  const sendReply = async (thread: Thread) => {
    const text = draft.trim();
    if (!text) return;
    setSending(true);
    try {
      await sendJson(
        "/api/control/broadcast",
        "POST",
        { hostname: thread.hostname, param: text, reason: "Direction Message" },
        "Gagal mengirim balasan",
      );
      toast(`Balasan terkirim ke ${thread.deviceName}.`);
      setComposeFor(null);
      setDraft("");
      await markThreadRead(thread);
    } catch (err) {
      toast((err as Error).message, "alert");
    } finally {
      setSending(false);
    }
  };

  return (
    <>
      <button
        type="button"
        onClick={() => {
          setOpen(true);
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
        <span className="lx-mono">{unread || page.replies.length}</span> balasan
      </button>

      <Modal
        isOpen={isOpen}
        onClose={() => {
          setOpen(false);
          setComposeFor(null);
          setDraft("");
        }}
        title="Balasan pengguna"
        description="Jawaban dari pesan yang dikirim ke workstation."
        width={520}
        footer={
          <Button
            label="Tutup"
            variant="secondary"
            size="sm"
            onClick={() => {
              setOpen(false);
              setComposeFor(null);
            }}
          />
        }
      >
        <div style={{ display: "grid", gap: 18 }}>
          {threads.map((thread) => (
            <div key={thread.hostname}>
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  marginBottom: 8,
                }}
              >
                <StatusDot status={thread.unread > 0 ? "active" : "idle"} />
                <Mono style={{ fontSize: 13, fontWeight: 600 }}>{thread.deviceName}</Mono>
                {thread.unread > 0 && (
                  <span className="lx-mono" style={{ fontSize: 11, color: "var(--lx-muted)" }}>
                    {thread.unread} belum dibaca
                  </span>
                )}
                <span style={{ flex: 1 }} />
                {thread.unread > 0 && (
                  <Button
                    label="Tandai dibaca"
                    variant="ghost"
                    size="sm"
                    onClick={() => markThreadRead(thread)}
                  />
                )}
                <Button
                  label="Balas"
                  variant="secondary"
                  size="sm"
                  onClick={() => {
                    setComposeFor(composeFor === thread.hostname ? null : thread.hostname);
                    setDraft("");
                  }}
                />
              </div>

              <div style={{ display: "grid", gap: 10, paddingLeft: 18 }}>
                {thread.replies.map((r) => (
                  <div key={r.id}>
                    {/* What the user was answering, when we know it. Without
                        this a bare "OK" three hours later is unreadable. */}
                    {r.in_reply_to && (
                      <div
                        style={{
                          fontSize: 12,
                          lineHeight: 1.45,
                          color: "var(--lx-muted)",
                          borderLeft: "2px solid var(--lx-hairline)",
                          paddingLeft: 9,
                          marginBottom: 4,
                        }}
                      >
                        {r.in_reply_to}
                      </div>
                    )}
                    <div style={{ fontSize: 13.5, lineHeight: 1.5 }}>{r.message}</div>
                    <Mono style={{ fontSize: 11, color: "var(--lx-muted)" }}>
                      {formatLogTime(r.created_at)}
                      {r.read_at ? " · dibaca" : ""}
                    </Mono>
                  </div>
                ))}
              </div>

              {composeFor === thread.hostname && (
                <div style={{ paddingLeft: 18, marginTop: 12, display: "grid", gap: 10 }}>
                  <TextArea
                    label={`Balas ke ${thread.deviceName}`}
                    value={draft}
                    onChange={setDraft}
                    placeholder="Pesan muncul di widget timer pengguna."
                    rows={2}
                    maxLength={280}
                  />
                  <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
                    <Button
                      label="Batal"
                      variant="ghost"
                      size="sm"
                      onClick={() => setComposeFor(null)}
                    />
                    <Button
                      label={isSending ? "Mengirim..." : "Kirim"}
                      variant="primary"
                      size="sm"
                      disabled={isSending || draft.trim().length === 0}
                      onClick={() => sendReply(thread)}
                    />
                  </div>
                </div>
              )}
            </div>
          ))}
          {threads.length === 0 && (
            <SectionLabel>Belum ada balasan</SectionLabel>
          )}
        </div>
      </Modal>
    </>
  );
}
