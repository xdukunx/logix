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
//
// While open it also reads /api/active, so each thread says whether anyone is
// at that station right now. A message to an offline station waits in the
// queue and then expires, and the admin should know that before typing it.
import {
  Fragment,
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
  type ReactNode,
} from "react";

import { getJson, postEmpty, sendJson } from "../api";
import { ACCESS_LABEL, resolveAccessType, type StationStatus } from "../tokens";
import type { ActiveWorkstation, ConversationMessage, ConversationsPage, ConversationThread } from "../types";
import { Mono, SectionLabel, StatusDot } from "../ui/base";
import { Button } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { Modal, useToast } from "../ui/overlays";
import { durationSince, formatClock, formatLogTime, splitDeviceName, usePolling } from "../util";
import { FrameTrigger } from "./AlertsBell";

const POLL_CLOSED_MS = 20000;
const POLL_OPEN_MS = 4000;
const MAX_LENGTH = 280;

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

type Presence = Exclude<StationStatus, "alert">;

const PRESENCE_LABEL: Record<Presence, string> = {
  active: "Dipakai",
  locked: "Terkunci",
  idle: "Bebas",
  offline: "Offline",
};

/** The same reading of a heartbeat as Monitoring's station cards. */
const presenceOf = (live: ActiveWorkstation | undefined): Presence => {
  if (!live) return "offline";
  if (live.status === "LOCKED") return "locked";
  return live.username ? "active" : "idle";
};

const DAYS_SHORT = ["Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"];
const pad = (n: number) => String(n).padStart(2, "0");

const dayLabel = (iso: string): ReactNode => {
  const d = new Date(iso);
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return "Hari ini";
  if (d.toDateString() === yesterday.toDateString()) return "Kemarin";
  return (
    <>
      {DAYS_SHORT[d.getDay()]} <Mono>{`${pad(d.getDate())}/${pad(d.getMonth() + 1)}`}</Mono>
    </>
  );
};

const UNREAD_TAG: CSSProperties = {
  minWidth: 20,
  height: 20,
  padding: "0 6px",
  borderRadius: "var(--lx-radius-pill)",
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  fontSize: 11,
  fontWeight: 700,
  background: "var(--lx-accent)",
  color: "var(--lx-on-accent)",
};

const CHAT = <path d="M20 11.5a7.5 7.5 0 0 1-11 6.6L4.5 19.5l1.3-4.2A7.5 7.5 0 1 1 20 11.5z" />;

// The rise plays on mount only, so after a thread opens it marks exactly the
// messages that arrive while it is on screen; polls re-render the rest in place.
const Bubble = ({ m, isNew }: { m: ConversationMessage; isNew: boolean }) => {
  const isOut = m.direction === "out";
  const isBroadcast = isOut && Boolean(m.to_all);
  const isFailed = isUndelivered(m);
  const label = isOut ? deliveryLabel(m) : "";
  return (
    <div
      className="lx-rise"
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: isOut ? "flex-end" : "flex-start",
        // Something the admin just sent lands with a small overshoot; an
        // answer arriving on its own just rises in.
        animationTimingFunction: isOut ? "var(--lx-ease-spring)" : undefined,
      }}
    >
      <div
        style={{
          maxWidth: "min(82%, 460px)",
          padding: "9px 14px",
          borderRadius: 18,
          borderBottomRightRadius: isOut ? 6 : 18,
          borderBottomLeftRadius: isOut ? 18 : 6,
          fontSize: 13.5,
          lineHeight: 1.5,
          whiteSpace: "pre-wrap",
          overflowWrap: "anywhere",
          // An ALL broadcast went to every station, not into this thread; ink
          // instead of lime keeps it from reading as a private message.
          background: isBroadcast ? "var(--lx-ink)" : isOut ? "var(--lx-accent)" : "var(--lx-card)",
          color: isBroadcast ? "var(--lx-on-ink)" : isOut ? "var(--lx-on-accent)" : "var(--lx-text)",
          border: isOut ? "1px solid transparent" : "1px solid var(--lx-border)",
          opacity: isFailed ? 0.55 : 1,
        }}
      >
        {isBroadcast && (
          <span
            style={{
              display: "block",
              fontSize: 10,
              fontWeight: 700,
              letterSpacing: ".06em",
              textTransform: "uppercase",
              opacity: 0.6,
              marginBottom: 2,
            }}
          >
            Semua stasiun
          </span>
        )}
        {m.text}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 4, padding: "0 4px" }}>
        {isFailed && <StatusDot status="alert" label="Tidak terkirim" />}
        {isOut && !m.to_all && m.status === "done" && (
          <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true" style={{ flexShrink: 0 }}>
            <path d="M2 6.5 L4.8 9 L10 3" fill="none" stroke="var(--lx-accent-text)" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        )}
        {isNew && (
          <span className="lx-anim-tag" style={{ ...UNREAD_TAG, height: 18, fontSize: 10, fontWeight: 650 }}>
            baru
          </span>
        )}
        <Mono style={{ fontSize: 11, color: "var(--lx-muted)" }}>
          {formatClock(m.at)}
          {label ? ` · ${label}` : ""}
        </Mono>
      </div>
    </div>
  );
};

const ThreadRow = ({
  thread,
  index,
  isActive,
  presence,
  onSelect,
}: {
  thread: ConversationThread;
  index: number;
  isActive: boolean;
  presence: Presence | null;
  onSelect: () => void;
}) => {
  const last = thread.messages[thread.messages.length - 1];
  const isUnread = thread.unread > 0;
  return (
    <button
      type="button"
      className="lx-tap lx-rise"
      aria-current={isActive ? "true" : undefined}
      onClick={onSelect}
      style={
        {
          "--i": index,
          font: "inherit",
          textAlign: "left",
          width: "100%",
          padding: 0,
          border: "none",
          borderRadius: 16,
          background: "transparent",
          color: isActive ? "var(--lx-on-ink)" : "var(--lx-text)",
          cursor: "pointer",
        } as CSSProperties
      }
    >
      {/* The fill lives on this inner box: the button needs an inline
          transparent background to shed the UA one, and an inline value
          would beat .lx-row-hover's :hover wash. */}
      <span
        className="lx-row-hover"
        style={{
          display: "grid",
          gap: 4,
          padding: "11px 12px",
          borderRadius: 16,
          background: isActive ? "var(--lx-ink)" : undefined,
        }}
      >
        <span style={{ display: "flex", alignItems: "center", gap: 8 }}>
          {presence && <StatusDot status={presence} label={PRESENCE_LABEL[presence]} />}
          <Mono style={{ fontSize: 13, fontWeight: 700 }}>{splitDeviceName(thread.device_name).id}</Mono>
          <span style={{ flex: 1 }} />
          {last && <Mono style={{ fontSize: 10.5, opacity: 0.6 }}>{stamp(last.at)}</Mono>}
          {isUnread && (
            <span key={thread.unread} className="lx-mono lx-anim-dot" style={UNREAD_TAG}>
              {thread.unread}
            </span>
          )}
        </span>
        {last && (
          <span
            style={{
              fontSize: 12.5,
              fontWeight: isUnread ? 600 : 400,
              color: isActive ? undefined : isUnread ? "var(--lx-text)" : "var(--lx-muted)",
              opacity: isActive ? 0.72 : 1,
              paddingLeft: presence ? 16 : 0,
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            }}
          >
            {last.direction === "out" ? "Anda: " : ""}
            {last.text}
          </span>
        )}
      </span>
    </button>
  );
};

export default function RepliesInbox() {
  const toast = useToast();
  const isPhone = useBreakpoint() === "phone";
  const composerId = useId();
  const [page, setPage] = useState<ConversationsPage | null>(null);
  const [live, setLive] = useState<ActiveWorkstation[] | null>(null);
  const [isOpen, setOpen] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [isSending, setSending] = useState(false);
  const [isComposerFocused, setComposerFocused] = useState(false);
  // Replies that were unread when the admin opened the thread. Viewing marks
  // them read within one poll, so without this the "baru" marker would vanish
  // before anyone saw which lines were new.
  const [newIds, setNewIds] = useState<ReadonlySet<string>>(new Set());
  // Reply ids already sent to /read, so the 4s poll does not re-post them
  // (or retry forever for a role without replies_write).
  const markedRef = useRef(new Set<number>());
  const scrollRef = useRef<HTMLDivElement>(null);
  const composerRef = useRef<HTMLTextAreaElement>(null);
  const isPinnedRef = useRef(true);
  const scrolledHostRef = useRef<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setPage(await getJson<ConversationsPage>("/api/conversations", "Gagal memuat pesan"));
    } catch {
      // Roles without replies_read get a 403; keep the last known state rather
      // than flashing an error into the app chrome. Same call as AlertsBell.
    }
  }, []);

  // Opening shortens the interval, and that restart polls at once. Presence
  // only matters while the conversation is on screen; without it the threads
  // simply show no presence dot.
  usePolling(
    () => {
      refresh();
      if (isOpen) {
        getJson<ActiveWorkstation[]>("/api/active", "Gagal memuat status stasiun")
          .then(setLive)
          .catch(() => {});
      }
    },
    isOpen ? POLL_OPEN_MS : POLL_CLOSED_MS,
  );

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
    setNewIds((prev) => new Set([...prev, ...pending.map((m) => m.id)]));
    Promise.all(
      pending.map((m) => postEmpty(`/api/replies/${m.reply_id}/read`, "Gagal menandai pesan").catch(() => {})),
    ).then(refresh);
  }, [isOpen, active, refresh]);

  // Opening a thread lands on its newest message. After that, a new message
  // only pulls the view down if the admin was already at the bottom or sent
  // it -- not while they are scrolled up reading back.
  const lastMessage = active?.messages[active.messages.length - 1];
  useEffect(() => {
    const el = scrollRef.current;
    if (!el || !active) {
      scrolledHostRef.current = null;
      return;
    }
    if (scrolledHostRef.current !== active.hostname || isPinnedRef.current || lastMessage?.direction === "out") {
      el.scrollTop = el.scrollHeight;
      isPinnedRef.current = true;
    }
    scrolledHostRef.current = active.hostname;
  }, [lastMessage?.id, lastMessage?.direction, active?.hostname, isOpen]);

  const onChatScroll = () => {
    const el = scrollRef.current;
    if (el) isPinnedRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
  };

  const select = (hostname: string | null) => {
    setSelected(hostname);
    setDraft("");
    setNewIds(new Set());
  };

  const close = () => {
    setOpen(false);
    select(null);
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
      // A click on Kirim took focus off the composer; a follow-up line should
      // not need another click. Phones keep their keyboard closed instead.
      if (!isPhone) composerRef.current?.focus();
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

  const liveByHost = live ? new Map(live.map((a) => [a.hostname.toUpperCase(), a])) : null;
  const presenceFor = (hostname: string): Presence | null =>
    liveByHost ? presenceOf(liveByHost.get(hostname.toUpperCase())) : null;

  const list = (
    <div style={{ display: "flex", flexDirection: "column", minHeight: 0, gap: 8 }}>
      <SectionLabel>
        Stasiun · <Mono>{threads.length}</Mono>
      </SectionLabel>
      <div style={{ display: "grid", gap: 2, alignContent: "start", overflowY: "auto", minHeight: 0, margin: "0 -4px", padding: "0 4px" }}>
        {threads.map((t, i) => (
          <ThreadRow
            key={t.hostname}
            thread={t}
            index={i}
            isActive={t.hostname === active?.hostname}
            presence={presenceFor(t.hostname)}
            onSelect={() => {
              // Re-clicking the open thread must not wipe its draft or "baru" marks.
              if (t.hostname !== selected) select(t.hostname);
              if (!isPhone) composerRef.current?.focus();
            }}
          />
        ))}
      </div>
    </div>
  );

  let chat: ReactNode = null;
  if (active) {
    const { id: stationId, spec } = splitDeviceName(active.device_name);
    const station = liveByHost?.get(active.hostname.toUpperCase());
    const presence = presenceFor(active.hostname);
    let lastDay = "";
    chat = (
      // flex: 1 fills the phone's fixed-height column; the desktop grid cell
      // stretches it anyway.
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minHeight: 0, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, paddingBottom: 12 }}>
          {isPhone && <Button label="Kembali" variant="secondary" size="sm" onClick={() => select(null)} />}
          <div style={{ minWidth: 0, flex: 1 }}>
            <div style={{ display: "flex", alignItems: "baseline", gap: 8, minWidth: 0 }}>
              <Mono style={{ fontSize: 20, fontWeight: 700, letterSpacing: "-0.02em", whiteSpace: "nowrap" }}>{stationId}</Mono>
              {spec && (
                <span style={{ fontSize: 12.5, color: "var(--lx-muted)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {spec}
                </span>
              )}
            </div>
            {/* The line's height is held before /api/active answers: filling it
                later would shrink the chat below and hide the newest message. */}
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 7,
                fontSize: 12.5,
                color: "var(--lx-muted)",
                marginTop: 3,
                minWidth: 0,
                minHeight: 19,
              }}
            >
              {presence && (
                <>
                  <StatusDot status={presence} />
                  <span style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", minWidth: 0 }}>
                    {PRESENCE_LABEL[presence]}
                    {presence === "active" && station && (
                      <>
                        {" · "}
                        <span style={{ color: "var(--lx-text)", fontWeight: 600 }}>{station.username}</span>
                        {" · "}
                        {ACCESS_LABEL[resolveAccessType(station.access_type)]}
                        {station.session_started_at && (
                          <>
                            {" · "}
                            <Mono>{durationSince(station.session_started_at)}</Mono>
                          </>
                        )}
                      </>
                    )}
                    {presence === "idle" && " · tidak ada yang masuk"}
                    {presence === "offline" && " · pesan kedaluwarsa bila stasiun tak kunjung online"}
                  </span>
                </>
              )}
            </div>
          </div>
        </div>
        <div
          key={active.hostname}
          ref={scrollRef}
          onScroll={onChatScroll}
          className="lx-rise"
          style={{
            flex: 1,
            minHeight: 0,
            overflowY: "auto",
            display: "grid",
            gap: 10,
            alignContent: "start",
            padding: "14px 14px 16px",
            // The canvas grey, not --lx-sunken: sunken is lighter than the
            // modal's frosted surface and the well would vanish into it.
            background: "var(--lx-bg)",
            borderRadius: 18,
          }}
        >
          {active.messages.map((m) => {
            const day = new Date(m.at).toDateString();
            const isNewDay = day !== lastDay;
            lastDay = day;
            return (
              <Fragment key={m.id}>
                {isNewDay && (
                  <div
                    style={{
                      justifySelf: "center",
                      fontSize: 11,
                      color: "var(--lx-muted)",
                      padding: "3px 11px",
                      borderRadius: "var(--lx-radius-pill)",
                      background: "var(--lx-card)",
                      border: "1px solid var(--lx-border)",
                    }}
                  >
                    {dayLabel(m.at)}
                  </div>
                )}
                <Bubble m={m} isNew={newIds.has(m.id)} />
              </Fragment>
            );
          })}
        </div>
        <div style={{ display: "grid", gap: 6, paddingTop: 12 }}>
          <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
            <SectionLabel>
              <label htmlFor={composerId}>Balas ke {stationId}</label>
            </SectionLabel>
            <Mono
              style={{
                marginLeft: "auto",
                fontSize: 11,
                color: draft.length >= MAX_LENGTH - 20 ? "var(--lx-text)" : "var(--lx-muted)",
                fontWeight: draft.length >= MAX_LENGTH - 20 ? 700 : 400,
              }}
            >
              {draft.length}/{MAX_LENGTH}
            </Mono>
          </div>
          <div
            style={{
              display: "flex",
              alignItems: "flex-end",
              gap: 8,
              padding: "6px 6px 6px 14px",
              borderRadius: 20,
              background: "var(--lx-card)",
              // The textarea drops its own outline; the whole composer takes
              // the ink focus edge instead, so focus is still plainly visible.
              border: `1px solid ${isComposerFocused ? "var(--lx-ink)" : "var(--lx-border)"}`,
              transition: "border-color var(--lx-motion) var(--lx-ease)",
            }}
          >
            <textarea
              id={composerId}
              ref={composerRef}
              value={draft}
              rows={2}
              maxLength={MAX_LENGTH}
              placeholder="Muncul di widget timer pengguna. Enter kirim, Shift+Enter baris baru."
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={onComposerKey}
              onFocus={() => setComposerFocused(true)}
              onBlur={() => setComposerFocused(false)}
              style={{
                font: "inherit",
                flex: 1,
                minWidth: 0,
                fontSize: 13.5,
                lineHeight: 1.5,
                padding: "4px 0",
                border: "none",
                outline: "none",
                background: "transparent",
                color: "var(--lx-text)",
                resize: "none",
              }}
            />
            <Button
              label={isSending ? "Mengirim..." : "Kirim"}
              variant="primary"
              size="sm"
              disabled={isSending || draft.trim().length === 0}
              onClick={send}
              style={{ padding: "11px 18px" }}
            />
          </div>
        </div>
      </div>
    );
  }

  const placeholder = (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        textAlign: "center",
        padding: 24,
        borderRadius: 18,
        background: "var(--lx-bg)",
        fontSize: 13,
        color: "var(--lx-muted)",
      }}
    >
      Pilih stasiun untuk melihat percakapan
    </div>
  );

  return (
    <>
      <FrameTrigger
        icon={CHAT}
        label={unread > 0 ? "Pesan baru" : "Percakapan"}
        count={unread || threads.length}
        tone={unread > 0 ? "accent" : "quiet"}
        ariaLabel={unread > 0 ? `${unread} pesan baru` : `${threads.length} percakapan`}
        onClick={() => {
          setOpen(true);
          // Desktop opens straight onto the most urgent thread; a phone shows
          // the list first, since there is no room for both.
          if (!isPhone) setSelected(threads[0]?.hostname ?? null);
        }}
      />

      <Modal
        isOpen={isOpen}
        onClose={close}
        title="Pesan"
        description="Percakapan dengan pengguna di tiap stasiun. Pesan muncul di widget timer mereka; balasannya kembali ke sini."
        width={isPhone ? 420 : 860}
        footer={<Button label="Tutup" variant="secondary" size="sm" onClick={close} />}
      >
        {isPhone ? (
          <div style={{ height: "60vh", display: "flex", flexDirection: "column" }}>{active ? chat : list}</div>
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: "250px 1fr", gap: 18, height: 500 }}>
            {list}
            {chat || placeholder}
          </div>
        )}
      </Modal>
    </>
  );
}
