// System Alerts: bell button + panel, global chrome polled every 30s
// regardless of the visible tab. Ported from server/static/js/alerts.js.
import { useCallback, useState } from "react";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Dialog } from "@astryxdesign/core/Dialog";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { IconButton } from "@astryxdesign/core/IconButton";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { StatusDot } from "@astryxdesign/core/StatusDot";
import { Heading, Text } from "@astryxdesign/core/Text";
import { useToast } from "@astryxdesign/core/Toast";
import { BellIcon } from "@heroicons/react/24/outline";

import { getJson, postEmpty } from "../api";
import type { Alert } from "../types";
import { timeAgo, usePolling } from "../util";

const SEVERITY_VARIANT: Record<Alert["severity"], "accent" | "warning" | "error"> = {
  info: "accent",
  warning: "warning",
  critical: "error",
};

export default function AlertsBell() {
  const toast = useToast();
  const [alerts, setAlerts] = useState<Alert[]>([]);
  const [isOpen, setIsOpen] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const data = await getJson<{ alerts: Alert[] }>("/api/alerts?active=true", "Gagal memuat peringatan");
      setAlerts(data.alerts);
    } catch {
      // transient failure: keep last known alerts
    }
  }, []);

  usePolling(refresh, 30000);

  const acknowledge = async (alertId: number) => {
    try {
      await postEmpty(`/api/alerts/${alertId}/acknowledge`, "Gagal menandai peringatan");
      toast({ body: "Peringatan ditandai sebagai diketahui." });
      refresh();
    } catch (err) {
      toast({ body: (err as Error).message, type: "error" });
    }
  };

  const unacknowledged = alerts.filter((a) => a.status === "active").length;

  return (
    <>
      <HStack gap={1} align="center">
        <IconButton
          label="Peringatan sistem"
          variant="ghost"
          icon={<BellIcon style={{ width: 18, height: 18 }} />}
          onClick={() => {
            setIsOpen(true);
            refresh();
          }}
        />
        {unacknowledged > 0 && <Badge variant="error" label={String(unacknowledged)} />}
      </HStack>

      <Dialog isOpen={isOpen} onOpenChange={setIsOpen} width={440}>
        <VStack gap={3}>
          <Heading level={5}>Peringatan Sistem</Heading>
          {alerts.length === 0 ? (
            <EmptyState title="Tidak ada peringatan aktif." isCompact />
          ) : (
            <VStack gap={2}>
              {alerts.map((a) => {
                const isAcknowledged = a.status === "acknowledged";
                return (
                  <Card key={a.id} padding={3} variant={isAcknowledged ? "muted" : "default"}>
                    <VStack gap={1}>
                      <HStack gap={2} align="center" justify="between">
                        <HStack gap={2} align="center">
                          <StatusDot variant={SEVERITY_VARIANT[a.severity] ?? "accent"} label={a.severity} />
                          <Text type="label">{a.title}</Text>
                        </HStack>
                        {!isAcknowledged && (
                          <Button label="Tandai Diketahui" size="sm" onClick={() => acknowledge(a.id)} />
                        )}
                      </HStack>
                      <Text type="body">{a.message}</Text>
                      <Text type="supporting" color="secondary">
                        {timeAgo(a.created_at)}
                        {isAcknowledged ? " · Diketahui" : ""}
                      </Text>
                    </VStack>
                  </Card>
                );
              })}
            </VStack>
          )}
        </VStack>
      </Dialog>
    </>
  );
}
