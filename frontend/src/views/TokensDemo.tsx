// Dev-only token gallery, reachable at #tokens. Renders the full Logix token
// layer + C0 primitives in BOTH modes side by side (via nested <Theme mode>),
// independent of the app's global mode, plus a live global toggle to prove the
// switch works. Not linked from the nav; never shipped in a user flow.
import { Theme } from "@astryxdesign/core/theme";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";

import { logixTheme } from "../theme";
import { useThemeMode } from "../theme/ThemeMode";
import { ACCESS_TYPE, STATUS, type AccessType, type StationStatus } from "../tokens";
import AccessTypeBadge, { AccessTypeTile } from "../components/AccessTypeBadge";
import { SkeletonLines } from "../components/states/Skeleton";
import EmptyState from "../components/states/EmptyState";
import ErrorState from "../components/states/ErrorState";

const STATUSES: StationStatus[] = ["inuse", "locked", "idle", "offline", "alert"];
const ACCESS: AccessType[] = ["physical", "ssh", "anydesk"];

function Wordmark({ size = 26 }: { size?: number }) {
  return (
    <span style={{ fontSize: size, fontWeight: 800, letterSpacing: "0.2em", color: "var(--color-text-primary)" }}>
      LOGI<span style={{ color: "var(--lx-accent)" }}>X</span>
    </span>
  );
}

function StatusPill({ status, small }: { status: StationStatus; small?: boolean }) {
  const t = STATUS[status];
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        padding: small ? "3px 10px" : "4px 11px",
        borderRadius: 999,
        background: t.bg,
        color: t.fg,
        fontSize: small ? 11 : 12,
        fontWeight: 700,
      }}
    >
      <span
        className={status === "inuse" ? "lx-pulse-dot" : undefined}
        style={{ width: 8, height: 8, borderRadius: "50%", background: t.dot }}
      />
      {t.label}
    </span>
  );
}

function Section({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <VStack gap={2}>
      <Text type="supporting" color="secondary">
        <span style={{ textTransform: "uppercase", letterSpacing: "0.08em", fontWeight: 700 }}>{label}</span>
      </Text>
      {children}
    </VStack>
  );
}

// The content rendered once per mode.
function Gallery() {
  return (
    <VStack
      gap={5}
      padding={5}
      style={{ background: "var(--color-background-body)", borderRadius: 14, minHeight: "100%" }}
    >
      <HStack gap={2} align="center" justify="between">
        <Wordmark />
        <Button label="Lihat sesi" variant="primary" size="sm" />
      </HStack>

      <Section label="Status stasiun">
        <HStack gap={2} wrap="wrap">
          {STATUSES.map((s) => (
            <StatusPill key={s} status={s} />
          ))}
        </HStack>
      </Section>

      <Section label="Tipe akses — badge">
        <VStack gap={2}>
          {ACCESS.map((a) => (
            <AccessTypeBadge key={a} type={a} detail="sejak 09:14 · 2j 41m" />
          ))}
        </VStack>
      </Section>

      <Section label="Tipe akses — tile">
        <VStack gap={3}>
          {ACCESS.map((a) => (
            <AccessTypeTile key={a} type={a} />
          ))}
        </VStack>
      </Section>

      <Section label="KPI + kartu stasiun">
        <HStack gap={3} wrap="wrap" align="stretch">
          <Card padding={4} style={{ minWidth: 150 }}>
            <VStack gap={0.5}>
              <Text type="supporting" color="secondary">Aktif sekarang</Text>
              <span style={{ fontSize: 30, fontWeight: 800, letterSpacing: "-0.02em", color: "var(--color-text-primary)" }}>
                7<span style={{ fontSize: 15, color: "var(--lx-text-muted)" }}>/12</span>
              </span>
            </VStack>
          </Card>
          <Card padding={4} style={{ minWidth: 220, borderLeft: "3px solid var(--lx-status-inuse)" }}>
            <VStack gap={2}>
              <HStack gap={2} align="center" justify="between">
                <Text type="label">WS-07 · GPU-A100</Text>
                <StatusPill status="inuse" small />
              </HStack>
              <AccessTypeBadge type="ssh" detail="sejak 09:14 · 2j 41m" size="sm" />
            </VStack>
          </Card>
        </HStack>
      </Section>

      <Section label="Buttons + badge">
        <HStack gap={2} wrap="wrap" align="center">
          <Button label="Utama" variant="primary" />
          <Button label="Sekunder" variant="secondary" />
          <Button label="Ghost" variant="ghost" />
          <Badge variant="success" label="3 Aktif" />
        </HStack>
      </Section>

      <Section label="Skeleton">
        <Card padding={4}>
          <SkeletonLines lines={3} />
        </Card>
      </Section>

      <Section label="Empty state">
        <EmptyState
          title="Belum ada sesi hari ini"
          description="Logi si rubah sedang berjaga. Aktivitas muncul begitu ada yang masuk."
        />
      </Section>

      <Section label="Error state">
        <ErrorState
          description="Tidak dapat memuat data workstation aktif."
          onRetry={() => {}}
        />
      </Section>
    </VStack>
  );
}

export default function TokensDemo() {
  const { mode, cycleMode } = useThemeMode();
  return (
    <VStack gap={4} padding={6} style={{ maxWidth: 1200, margin: "0 auto" }}>
      <HStack gap={3} align="center" justify="between">
        <VStack gap={1}>
          <Heading level={3}>Design Foundation — C0 tokens</Heading>
          <Text type="supporting" color="secondary">
            Light &amp; dark, side by side. Toggle switches the whole app.
          </Text>
        </VStack>
        <Button label={`Mode: ${mode}`} variant="secondary" onClick={cycleMode} />
      </HStack>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
        <Theme theme={logixTheme} mode="light">
          <Gallery />
        </Theme>
        <Theme theme={logixTheme} mode="dark">
          <Gallery />
        </Theme>
      </div>
    </VStack>
  );
}
