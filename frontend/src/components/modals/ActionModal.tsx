// ActionModal — the shared modal shell that replaces every browser
// prompt()/confirm(). Encodes the design's "sensitive action" template
// (docs/design/LogiX Action Modals.dc.html): tinted action icon -> title +
// subtitle -> body (consequence / reason / privacy note) -> Cancel + Confirm.
// tone="danger" adds the red top border and a destructive confirm button.
import type { ReactNode } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Dialog } from "@astryxdesign/core/Dialog";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Text } from "@astryxdesign/core/Text";

export type ModalTone = "brand" | "danger";

const ICON_TINT: Record<ModalTone, { bg: string; fg: string }> = {
  brand: { bg: "var(--lx-access-physical-icon-bg)", fg: "var(--lx-accent)" },
  danger: { bg: "var(--lx-status-alert-bg)", fg: "var(--lx-status-alert)" },
};

export function ActionModal({
  isOpen,
  onClose,
  icon,
  title,
  subtitle,
  tone = "brand",
  width = 440,
  children,
  confirmLabel,
  confirmIcon,
  onConfirm,
  isConfirmDisabled,
  isConfirmLoading,
  cancelLabel = "Batal",
  iconSize = 40,
}: {
  isOpen: boolean;
  onClose: () => void;
  icon: ReactNode;
  title: string;
  subtitle?: ReactNode;
  tone?: ModalTone;
  width?: number;
  children?: ReactNode;
  confirmLabel: string;
  confirmIcon?: ReactNode;
  onConfirm: () => void;
  isConfirmDisabled?: boolean;
  isConfirmLoading?: boolean;
  cancelLabel?: string;
  iconSize?: number;
}) {
  const tint = ICON_TINT[tone];
  return (
    <Dialog isOpen={isOpen} onOpenChange={(open) => !open && onClose()} width={width} padding={0}>
      <VStack
        gap={0}
        style={tone === "danger" ? { borderTop: "4px solid var(--lx-status-alert)" } : undefined}
      >
        <VStack gap={4} style={{ padding: "22px 24px 4px" }}>
          <HStack gap={3} align="center">
            <span
              style={{
                width: iconSize,
                height: iconSize,
                borderRadius: 10,
                background: tint.bg,
                color: tint.fg,
                display: "inline-flex",
                alignItems: "center",
                justifyContent: "center",
                flexShrink: 0,
              }}
            >
              {icon}
            </span>
            <VStack gap={0.5} style={{ minWidth: 0 }}>
              <Text type="large">
                <span style={{ fontWeight: 700 }}>{title}</span>
              </Text>
              {subtitle && (
                <Text type="supporting" color="secondary">
                  {subtitle}
                </Text>
              )}
            </VStack>
          </HStack>
          {children}
        </VStack>
        <HStack gap={2} justify="end" style={{ padding: "16px 24px 20px" }}>
          <Button label={cancelLabel} variant="secondary" onClick={onClose} />
          <Button
            label={confirmLabel}
            variant={tone === "danger" ? "destructive" : "primary"}
            icon={confirmIcon}
            isDisabled={isConfirmDisabled}
            isLoading={isConfirmLoading}
            onClick={onConfirm}
          />
        </HStack>
      </VStack>
    </Dialog>
  );
}

// The blue "privacy note" callout used by sensitive modals (screenshot).
export function PrivacyNote({ children }: { children: ReactNode }) {
  return (
    <HStack
      gap={2}
      align="start"
      style={{
        background: "var(--lx-accent-weak)",
        border: "1px solid var(--color-border)",
        borderRadius: 8,
        padding: "12px 14px",
      }}
    >
      <ShieldGlyph />
      <Text type="supporting">
        <span style={{ color: "var(--color-text-accent, var(--lx-accent))", lineHeight: 1.5 }}>
          {children}
        </span>
      </Text>
    </HStack>
  );
}

// The red warning callout used by destructive modals (power).
export function WarningNote({ children }: { children: ReactNode }) {
  return (
    <HStack
      gap={2}
      align="start"
      style={{
        background: "var(--lx-status-alert-bg)",
        border: "1px solid var(--lx-status-alert)",
        borderRadius: 8,
        padding: "11px 13px",
      }}
    >
      <AlertGlyph />
      <Text type="supporting">
        <span style={{ color: "var(--lx-status-alert-fg)", lineHeight: 1.5 }}>{children}</span>
      </Text>
    </HStack>
  );
}

const ShieldGlyph = () => (
  <svg
    width="18"
    height="18"
    viewBox="0 0 24 24"
    fill="none"
    stroke="var(--lx-accent)"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{ flexShrink: 0, marginTop: 1 }}
    aria-hidden
  >
    <path d="M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6z" />
    <path d="M9 12l2 2 4-4" />
  </svg>
);

const AlertGlyph = () => (
  <svg
    width="17"
    height="17"
    viewBox="0 0 24 24"
    fill="none"
    stroke="var(--lx-status-alert)"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{ flexShrink: 0, marginTop: 1 }}
    aria-hidden
  >
    <path d="M12 9v4M12 17h.01" />
    <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
  </svg>
);

export default ActionModal;
