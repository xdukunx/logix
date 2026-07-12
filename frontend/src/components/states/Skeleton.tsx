// Skeleton loading primitives. The shimmer + colors live in tokens.css
// (.lx-skeleton), which already respects prefers-reduced-motion. Use these
// wherever data is loading instead of a bare "Memuat data..." string.
import { Card } from "@astryxdesign/core/Card";
import { HStack, VStack } from "@astryxdesign/core/Stack";

export function Skeleton({
  width = "100%",
  height = 12,
  radius = 4,
}: {
  width?: number | string;
  height?: number | string;
  radius?: number;
}) {
  return (
    <span
      className="lx-skeleton"
      style={{ display: "block", width, height, borderRadius: radius }}
      aria-hidden
    />
  );
}

// A few shimmer lines of decreasing width — the generic "text is loading" block.
export function SkeletonLines({
  lines = 3,
  widths = ["55%", "85%", "40%"],
}: {
  lines?: number;
  widths?: (number | string)[];
}) {
  return (
    <VStack gap={2} style={{ width: "100%" }} aria-hidden>
      {Array.from({ length: lines }).map((_, i) => (
        <Skeleton key={i} width={widths[i % widths.length]} />
      ))}
    </VStack>
  );
}

// A card-shaped placeholder that mirrors a station / device card while loading.
export function SkeletonCard() {
  return (
    <Card padding={4} aria-hidden>
      <VStack gap={3}>
        <HStack gap={2} align="center" justify="between">
          <Skeleton width="45%" height={14} />
          <Skeleton width={64} height={20} radius={999} />
        </HStack>
        <SkeletonLines lines={3} widths={["80%", "60%", "40%"]} />
      </VStack>
    </Card>
  );
}

// A responsive grid of skeleton cards for a loading dashboard.
export function SkeletonGrid({ count = 6 }: { count?: number }) {
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "repeat(auto-fill, minmax(240px, 1fr))",
        gap: "var(--spacing-4, 16px)",
      }}
      aria-hidden
    >
      {Array.from({ length: count }).map((_, i) => (
        <SkeletonCard key={i} />
      ))}
    </div>
  );
}

export default Skeleton;
