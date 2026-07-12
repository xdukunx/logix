// Replies viewer (Action Modals §06). Shows a station's incoming replies,
// unread ones highlighted, with mark-all-read and a shortcut to reply.
import { useMemo } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Dialog } from "@astryxdesign/core/Dialog";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Text } from "@astryxdesign/core/Text";
import { ChatBubbleLeftRightIcon } from "@heroicons/react/24/outline";

import type { Reply } from "../../types";
import { timeAgo } from "../../util";

export default function RepliesModal({
  isOpen,
  onClose,
  deviceName,
  username,
  replies,
  onMarkAllRead,
  onReply,
}: {
  isOpen: boolean;
  onClose: () => void;
  deviceName: string;
  username?: string | null;
  replies: Reply[];
  onMarkAllRead: () => void;
  onReply?: () => void;
}) {
  const sorted = useMemo(
    () =>
      replies
        .slice()
        .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()),
    [replies],
  );
  const unread = sorted.filter((r) => !r.read_at).length;

  return (
    <Dialog isOpen={isOpen} onOpenChange={(open) => !open && onClose()} width={440} padding={0}>
      <VStack gap={0}>
        <HStack
          gap={3}
          align="center"
          style={{ padding: "20px 22px 14px", borderBottom: "1px solid var(--color-border)" }}
        >
          <span
            style={{
              width: 34,
              height: 34,
              borderRadius: 8,
              background: "var(--lx-access-physical-icon-bg)",
              color: "var(--lx-accent)",
              display: "inline-flex",
              alignItems: "center",
              justifyContent: "center",
              flexShrink: 0,
            }}
          >
            <ChatBubbleLeftRightIcon style={{ width: 17, height: 17 }} />
          </span>
          <VStack gap={0} style={{ flex: 1, minWidth: 0 }}>
            <Text type="large">
              <span style={{ fontWeight: 700 }}>Balasan · {deviceName}</span>
            </Text>
            <Text type="supporting" color="secondary">
              {username ? `${username} · ` : ""}
              {sorted.length} balasan
            </Text>
          </VStack>
          {unread > 0 && (
            <span
              style={{
                background: "var(--lx-status-alert)",
                color: "#fff",
                fontSize: 11,
                fontWeight: 700,
                padding: "2px 8px",
                borderRadius: 999,
              }}
            >
              {unread} baru
            </span>
          )}
        </HStack>

        <div style={{ maxHeight: 300, overflow: "auto" }}>
          {sorted.length === 0 ? (
            <VStack padding={5} align="center">
              <Text type="supporting" color="secondary">
                Belum ada balasan.
              </Text>
            </VStack>
          ) : (
            sorted.map((r) => {
              const isUnread = !r.read_at;
              return (
                <HStack
                  key={r.id}
                  gap={2}
                  align="start"
                  style={{
                    padding: "13px 22px",
                    borderBottom: "1px solid var(--color-border)",
                    background: isUnread ? "var(--lx-accent-weak)" : "transparent",
                  }}
                >
                  <span
                    style={{
                      width: 7,
                      height: 7,
                      borderRadius: "50%",
                      background: isUnread ? "var(--lx-accent)" : "var(--color-border-emphasized)",
                      flexShrink: 0,
                      marginTop: 6,
                    }}
                  />
                  <VStack gap={0.5} style={{ minWidth: 0 }}>
                    <Text type="body" color={isUnread ? "primary" : "secondary"}>
                      {r.message}
                    </Text>
                    <Text type="supporting" color="secondary">
                      {timeAgo(r.created_at)} · {isUnread ? "belum dibaca" : "dibaca"}
                    </Text>
                  </VStack>
                </HStack>
              );
            })
          )}
        </div>

        <HStack
          gap={2}
          justify="between"
          align="center"
          style={{ padding: "14px 22px", borderTop: "1px solid var(--color-border)" }}
        >
          <Button
            label="Tandai semua dibaca"
            variant="ghost"
            isDisabled={unread === 0}
            onClick={onMarkAllRead}
          />
          <Button label="Balas" variant="primary" isDisabled={!onReply} onClick={() => onReply?.()} />
        </HStack>
      </VStack>
    </Dialog>
  );
}
