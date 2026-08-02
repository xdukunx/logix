// Settings tab: Branding, Popup Builder, Device Naming, Report Settings,
// and Privacy Notice -- all persisted through the existing GET/PUT
// /api/config (no new endpoint; the config object just grew new keys).
import { fetchWithAuth, escapeHtml, showToast } from "./api.js";

const btnSaveSettings = document.getElementById("btn-save-settings");

// Branding
const cfgLogoText = document.getElementById("cfg-logo-text");
const cfgTitle = document.getElementById("cfg-title");
const cfgSubtitle = document.getElementById("cfg-subtitle");
const cfgColorPrimary = document.getElementById("cfg-color-primary");
const cfgColorPrimaryPicker = document.getElementById("cfg-color-primary-picker");
const cfgColorAccent = document.getElementById("cfg-color-accent");
const cfgColorAccentPicker = document.getElementById("cfg-color-accent-picker");

// Popup Builder
const cfgAccessTypes = document.getElementById("cfg-access-types");
const previewTitle = document.getElementById("preview-title");
const previewWelcome = document.getElementById("preview-welcome");
const previewPurposeField = document.getElementById("preview-purpose-field");

// Device Naming
const cfgNamingPattern = document.getElementById("cfg-naming-pattern");

// Report Settings
const cfgReportDefaultScope = document.getElementById("cfg-report-default-scope");
const cfgReportIncludeBranding = document.getElementById("cfg-report-include-branding");
const cfgReportIncludePurposeSummary = document.getElementById("cfg-report-include-purpose-summary");
const cfgReportIncludeDeviceSummary = document.getElementById("cfg-report-include-device-summary");

// Privacy Notice
const cfgPrivacyNotice = document.getElementById("cfg-privacy-notice");

// Keeps whatever the server had for fields this UI doesn't expose (e.g.
// `text.*` label strings, `requiredFields`) so saving never clobbers them.
let loadedConfig = {};

// --- Generic editable list (purpose options, device types, privacy lists) --

const renderEditableList = (containerId, items) => {
    const container = document.getElementById(containerId);
    container.innerHTML = items.map(item => `
        <div class="editable-list-item">
            <input type="text" value="${escapeHtml(item)}" data-list-input>
            <button type="button" class="btn-icon-danger" data-remove title="Hapus"></button>
        </div>
    `).join("");
};

const readEditableList = (containerId) => {
    const container = document.getElementById(containerId);
    return Array.from(container.querySelectorAll("[data-list-input]"))
        .map(input => input.value.trim())
        .filter(Boolean);
};

const addEditableListItem = (containerId, value = "") => {
    const container = document.getElementById(containerId);
    const div = document.createElement("div");
    div.className = "editable-list-item";
    div.innerHTML = `<input type="text" value="${escapeHtml(value)}" data-list-input><button type="button" class="btn-icon-danger" data-remove title="Hapus"></button>`;
    container.appendChild(div);
    div.querySelector("input").focus();
};

const wireListRemoval = (containerId) => {
    document.getElementById(containerId).addEventListener("click", (e) => {
        const btn = e.target.closest("[data-remove]");
        if (btn) {
            btn.closest(".editable-list-item").remove();
            if (containerId === "cfg-purposes-list") updatePreview();
        }
    });
};

[
    "cfg-purposes-list",
    "cfg-device-types-list",
    "cfg-privacy-collected-list",
    "cfg-privacy-not-collected-list",
].forEach(wireListRemoval);

document.getElementById("btn-add-purpose").addEventListener("click", () => addEditableListItem("cfg-purposes-list"));
document.getElementById("btn-add-device-type").addEventListener("click", () => addEditableListItem("cfg-device-types-list"));
document.getElementById("btn-add-collected").addEventListener("click", () => addEditableListItem("cfg-privacy-collected-list"));
document.getElementById("btn-add-not-collected").addEventListener("click", () => addEditableListItem("cfg-privacy-not-collected-list"));

// --- Color pickers (bidirectional text <-> swatch binding) -----------------

const linkColorPicker = (textEl, pickerEl) => {
    pickerEl.addEventListener("input", (e) => {
        textEl.value = e.target.value.toUpperCase();
    });
    textEl.addEventListener("input", (e) => {
        if (/^#[0-9A-Fa-f]{6}$/.test(e.target.value)) {
            pickerEl.value = e.target.value;
        }
    });
};
linkColorPicker(cfgColorPrimary, cfgColorPrimaryPicker);
linkColorPicker(cfgColorAccent, cfgColorAccentPicker);

// --- Popup live preview -----------------------------------------------------

const updatePreview = () => {
    previewTitle.textContent = cfgTitle.value || "Report Logbook";
    previewWelcome.textContent = "Isi data penggunaan workstation sebelum memulai sesi.";
    const firstPurpose = readEditableList("cfg-purposes-list")[0];
    previewPurposeField.textContent = firstPurpose ? `Tujuan Penggunaan (mis. ${firstPurpose})` : "Tujuan Penggunaan";
};
cfgTitle.addEventListener("input", updatePreview);

// --- Load / Save -------------------------------------------------------------

export const loadConfiguration = async () => {
    try {
        const res = await fetch("/api/config");
        if (!res.ok) throw new Error("Gagal memuat konfigurasi");
        const cfg = await res.json();
        loadedConfig = cfg;

        cfgLogoText.value = cfg.branding?.logoText || "";
        cfgTitle.value = cfg.branding?.title || "";
        cfgSubtitle.value = cfg.branding?.subtitle || "";

        cfgColorPrimary.value = (cfg.branding?.colors?.primary || "#073763").toUpperCase();
        cfgColorPrimaryPicker.value = cfg.branding?.colors?.primary || "#073763";
        cfgColorAccent.value = (cfg.branding?.colors?.accent || "#741B47").toUpperCase();
        cfgColorAccentPicker.value = cfg.branding?.colors?.accent || "#741B47";

        cfgAccessTypes.value = (cfg.accessTypes || []).join(", ");
        renderEditableList("cfg-purposes-list", cfg.purposes || []);

        const devices = cfg.devices || {};
        renderEditableList("cfg-device-types-list", devices.device_types || []);
        cfgNamingPattern.value = devices.naming_pattern || "{type} - {room} - {number}";

        const reports = cfg.reports || {};
        cfgReportDefaultScope.value = reports.default_scope || "today";
        cfgReportIncludeBranding.checked = reports.include_branding !== false;
        cfgReportIncludePurposeSummary.checked = reports.include_purpose_summary !== false;
        cfgReportIncludeDeviceSummary.checked = reports.include_device_summary !== false;

        const privacy = cfg.privacy || {};
        cfgPrivacyNotice.value = privacy.notice || "";
        renderEditableList("cfg-privacy-collected-list", privacy.collected || []);
        renderEditableList("cfg-privacy-not-collected-list", privacy.not_collected || []);

        updatePreview();
    } catch (err) {
        console.error(err);
        showToast("Gagal memuat pengaturan popup", true);
    }
};

btnSaveSettings.addEventListener("click", async () => {
    const newConfig = {
        ...loadedConfig,
        branding: {
            ...(loadedConfig.branding || {}),
            logoText: cfgLogoText.value.trim(),
            title: cfgTitle.value.trim(),
            subtitle: cfgSubtitle.value.trim(),
            colors: {
                ...(loadedConfig.branding?.colors || {}),
                primary: cfgColorPrimary.value,
                accent: cfgColorAccent.value,
            },
        },
        accessTypes: cfgAccessTypes.value.split(",").map(s => s.trim()).filter(Boolean),
        purposes: readEditableList("cfg-purposes-list"),
        devices: {
            device_types: readEditableList("cfg-device-types-list"),
            naming_pattern: cfgNamingPattern.value.trim() || "{type} - {room} - {number}",
        },
        reports: {
            default_scope: cfgReportDefaultScope.value,
            include_branding: cfgReportIncludeBranding.checked,
            include_purpose_summary: cfgReportIncludePurposeSummary.checked,
            include_device_summary: cfgReportIncludeDeviceSummary.checked,
        },
        privacy: {
            notice: cfgPrivacyNotice.value.trim(),
            collected: readEditableList("cfg-privacy-collected-list"),
            not_collected: readEditableList("cfg-privacy-not-collected-list"),
        },
    };

    try {
        const res = await fetchWithAuth("/api/config", {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(newConfig)
        });
        if (!res.ok) throw new Error("Gagal menyimpan konfigurasi ke server");
        loadedConfig = newConfig;
        showToast("Pengaturan berhasil disimpan!");
    } catch (err) {
        console.error(err);
        showToast(err.message, true);
    }
});
