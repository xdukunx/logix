// Report download modal: Today / All Data / Date Range.
import { fetchWithAuth, showToast } from "./api.js";

const modal = document.getElementById("report-modal");
const btnOpen = document.getElementById("btn-open-report-modal");
const btnClose = document.getElementById("close-report-modal");
const scopeOptions = document.querySelectorAll(".report-scope-option");
const scopeRadios = document.querySelectorAll('input[name="report-scope"]');
const dateRangeRow = document.getElementById("report-date-range");
const startDateInput = document.getElementById("report-start-date");
const endDateInput = document.getElementById("report-end-date");
const errorEl = document.getElementById("report-modal-error");
const btnConfirm = document.getElementById("btn-report-download-confirm");

const showError = (message) => {
    errorEl.textContent = message;
    errorEl.classList.remove("hidden");
};
const clearError = () => {
    errorEl.textContent = "";
    errorEl.classList.add("hidden");
};

const getSelectedScope = () => {
    const checked = Array.from(scopeRadios).find(r => r.checked);
    return checked ? checked.value : "today";
};

const updateScopeVisuals = () => {
    const scope = getSelectedScope();
    scopeOptions.forEach(opt => opt.classList.toggle("active", opt.dataset.scope === scope));
    dateRangeRow.hidden = scope !== "range";
    clearError();
};

scopeRadios.forEach(radio => radio.addEventListener("change", updateScopeVisuals));
scopeOptions.forEach(opt => {
    opt.addEventListener("click", () => {
        opt.querySelector('input[type="radio"]').checked = true;
        updateScopeVisuals();
    });
});

btnOpen.addEventListener("click", () => {
    clearError();
    modal.classList.remove("hidden");
});
btnClose.addEventListener("click", () => modal.classList.add("hidden"));

const downloadReport = (queryString) => {
    showToast("Menyiapkan unduhan Excel...");
    fetchWithAuth(`/api/reports?${queryString}`)
        .then(res => {
            if (!res.ok) return res.json().then(body => { throw new Error(body.detail || "Gagal membuat laporan"); });
            return res.blob();
        })
        .then(blob => {
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = url;
            a.download = `report-logix-${new Date().toISOString().slice(0, 10)}.xlsx`;
            document.body.appendChild(a);
            a.click();
            a.remove();
            window.URL.revokeObjectURL(url);
            showToast("Laporan Excel berhasil diunduh.");
            modal.classList.add("hidden");
        })
        .catch(err => {
            showError(err.message);
        });
};

btnConfirm.addEventListener("click", () => {
    clearError();
    const scope = getSelectedScope();

    if (scope === "today") {
        downloadReport("today=true");
        return;
    }
    if (scope === "all") {
        downloadReport("full=true");
        return;
    }

    // Date Range
    const start = startDateInput.value;
    const end = endDateInput.value;
    if (!start) {
        showError("Pilih tanggal mulai.");
        return;
    }
    if (end && start > end) {
        showError("Tanggal mulai tidak boleh setelah tanggal akhir.");
        return;
    }
    const params = new URLSearchParams({ start_date: start });
    if (end) params.set("end_date", end);
    downloadReport(params.toString());
});
