// Colored stat tile used by the Devices and Analytics dashboards --
// icon + label + big number on a tinted Card, echoing the legacy
// dashboard's stat row.
import type { ComponentType, SVGProps } from "react";
import { Card } from "@astryxdesign/core/Card";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";

export type StatCardVariant =
  | "default"
  | "muted"
  | "blue"
  | "cyan"
  | "green"
  | "yellow"
  | "orange"
  | "purple";

export default function StatCard({
  label,
  value,
  icon: Icon,
  variant = "default",
}: {
  label: string;
  value: number | string;
  icon: ComponentType<SVGProps<SVGSVGElement>>;
  variant?: StatCardVariant;
}) {
  return (
    <Card padding={4} variant={variant}>
      <HStack gap={3} align="center">
        <Icon style={{ width: 26, height: 26, opacity: 0.65, flexShrink: 0 }} />
        <VStack gap={0.5}>
          <Text type="supporting" color="secondary">{label}</Text>
          <Heading level={2}>{value}</Heading>
        </VStack>
      </HStack>
    </Card>
  );
}
