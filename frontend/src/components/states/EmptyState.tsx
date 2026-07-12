// EmptyState — the friendly "nothing here yet" panel from the Style Tile:
// a dashed card, Logi the fox, a calm title + line of copy, and an optional
// action. Reassuring, never a dead end. Distinct from Astryx's own EmptyState
// (which we no longer use) so it carries the mascot + Logix voice.
import type { ReactNode } from "react";
import { VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";

import mascot from "../../assets/mascot.png";

export function EmptyState({
  title,
  description,
  action,
  icon,
  showMascot = true,
}: {
  title: string;
  description?: string;
  action?: ReactNode;
  /** Custom illustration; overrides the mascot when provided. */
  icon?: ReactNode;
  showMascot?: boolean;
}) {
  return (
    <VStack
      gap={3}
      align="center"
      padding={6}
      style={{
        border: "1px dashed var(--color-border-emphasized)",
        borderRadius: 12,
        background: "var(--color-background-surface)",
        textAlign: "center",
      }}
    >
      {icon ? (
        <span style={{ color: "var(--lx-text-muted)" }}>{icon}</span>
      ) : showMascot ? (
        <img
          src={mascot}
          alt=""
          width={72}
          height={72}
          style={{ opacity: 0.9, objectFit: "contain" }}
        />
      ) : null}
      <VStack gap={1} align="center">
        <Heading level={5}>{title}</Heading>
        {description && (
          <Text type="body" color="secondary">
            {description}
          </Text>
        )}
      </VStack>
      {action}
    </VStack>
  );
}

export default EmptyState;
