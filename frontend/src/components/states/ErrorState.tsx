// ErrorState — honest, calm failure panel with a retry affordance. Uses the
// alert token for the icon wash so it reads as a problem without shouting.
import { Button } from "@astryxdesign/core/Button";
import { VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";
import { ArrowPathIcon, ExclamationTriangleIcon } from "@heroicons/react/24/outline";

export function ErrorState({
  title = "Terjadi kesalahan",
  description,
  onRetry,
  retryLabel = "Coba lagi",
}: {
  title?: string;
  description?: string;
  onRetry?: () => void;
  retryLabel?: string;
}) {
  return (
    <VStack
      gap={3}
      align="center"
      padding={6}
      style={{
        border: "1px solid var(--color-border)",
        borderRadius: 12,
        background: "var(--color-background-surface)",
        textAlign: "center",
      }}
    >
      <span
        style={{
          width: 46,
          height: 46,
          borderRadius: 10,
          background: "var(--lx-status-alert-bg)",
          color: "var(--lx-status-alert-fg)",
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <ExclamationTriangleIcon style={{ width: 24, height: 24 }} />
      </span>
      <VStack gap={1} align="center">
        <Heading level={5}>{title}</Heading>
        {description && (
          <Text type="body" color="secondary">
            {description}
          </Text>
        )}
      </VStack>
      {onRetry && (
        <Button
          label={retryLabel}
          variant="secondary"
          icon={<ArrowPathIcon style={{ width: 16, height: 16 }} />}
          onClick={onRetry}
        />
      )}
    </VStack>
  );
}

export default ErrorState;
