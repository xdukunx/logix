// Report download dialog: Today / All Data / Date Range -> GET /api/reports
// as an Excel download. Ported from server/static/js/report-modal.js.
import { useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { DateInput } from "@astryxdesign/core/DateInput";
import { Dialog } from "@astryxdesign/core/Dialog";
import { SegmentedControl, SegmentedControlItem } from "@astryxdesign/core/SegmentedControl";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";
import { useToast } from "@astryxdesign/core/Toast";

import { fetchWithAuth } from "../api";

export default function ReportDialog({
  isOpen,
  onOpenChange,
}: {
  isOpen: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const toast = useToast();
  const [scope, setScope] = useState("today");
  type ISODate = `${number}${number}${number}${number}-${number}${number}-${number}${number}`;
  const [startDate, setStartDate] = useState<ISODate | undefined>(undefined);
  const [endDate, setEndDate] = useState<ISODate | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [isDownloading, setIsDownloading] = useState(false);

  const download = async () => {
    setError(null);

    let queryString: string;
    if (scope === "today") {
      queryString = "today=true";
    } else if (scope === "all") {
      queryString = "full=true";
    } else {
      if (!startDate) {
        setError("Pilih tanggal mulai.");
        return;
      }
      if (endDate && startDate > endDate) {
        setError("Tanggal mulai tidak boleh setelah tanggal akhir.");
        return;
      }
      const params = new URLSearchParams({ start_date: startDate });
      if (endDate) params.set("end_date", endDate);
      queryString = params.toString();
    }

    setIsDownloading(true);
    toast({ body: "Menyiapkan unduhan Excel..." });
    try {
      const res = await fetchWithAuth(`/api/reports?${queryString}`);
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.detail || "Gagal membuat laporan");
      }
      const blob = await res.blob();
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `report-logix-${new Date().toISOString().slice(0, 10)}.xlsx`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      window.URL.revokeObjectURL(url);
      toast({ body: "Laporan Excel berhasil diunduh." });
      onOpenChange(false);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setIsDownloading(false);
    }
  };

  return (
    <Dialog isOpen={isOpen} onOpenChange={onOpenChange} width={440}>
      <VStack gap={4}>
        <Heading level={5}>Unduh Laporan Excel</Heading>

        <SegmentedControl value={scope} onChange={setScope} label="Cakupan laporan" layout="fill">
          <SegmentedControlItem value="today" label="Hari Ini" />
          <SegmentedControlItem value="all" label="Semua Data" />
          <SegmentedControlItem value="range" label="Rentang" />
        </SegmentedControl>

        {scope === "range" && (
          <HStack gap={3}>
            <DateInput label="Tanggal Mulai" value={startDate} onChange={setStartDate} isRequired />
            <DateInput label="Tanggal Akhir" value={endDate} onChange={setEndDate} isOptional />
          </HStack>
        )}

        {error && <Text type="body" color="secondary">{error}</Text>}

        <HStack gap={2} justify="end">
          <Button label="Batal" onClick={() => onOpenChange(false)} />
          <Button label="Unduh" variant="primary" isLoading={isDownloading} onClick={download} />
        </HStack>
      </VStack>
    </Dialog>
  );
}
