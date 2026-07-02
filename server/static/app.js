// Logix Admin Dashboard Controller (Hardened with Auth, Controls & Analytics)
document.addEventListener("DOMContentLoaded", () => {
    // Pagination & Search States
    let currentPage = 1;
    const itemsPerPage = 15;
    let searchQuery = "";
    let totalLogs = 0;

    // Elements
    const loginOverlay = document.getElementById("login-overlay");
    const appWrapper = document.getElementById("app-wrapper");
    // Login elements are handled via Google OAuth redirect link
    const btnLogout = document.getElementById("btn-logout");

    const pcsGrid = document.getElementById("pcs-grid");
    const logsTbody = document.getElementById("logs-tbody");
    const auditLogTbody = document.getElementById("audit-log-tbody");
    const valActivePcs = document.getElementById("val-active-pcs");
    const valTotalLogs = document.getElementById("val-total-logs");
    const pcCountBadge = document.getElementById("pc-count-badge");
    
    const btnPrev = document.getElementById("btn-prev");
    const btnNext = document.getElementById("btn-next");
    const pageIndicator = document.getElementById("page-indicator");
    const searchInput = document.getElementById("log-search-input");
    
    // Download Buttons
    const btnDlToday = document.getElementById("btn-dl-today");
    const btnDlFull = document.getElementById("btn-dl-full");

    // Config Elements
    const configForm = document.getElementById("config-form");
    const btnSaveConfig = document.getElementById("btn-save-config");
    const cfgLogoText = document.getElementById("cfg-logo-text");
    const cfgTitle = document.getElementById("cfg-title");
    const cfgSubtitle = document.getElementById("cfg-subtitle");
    
    const cfgColorPrimary = document.getElementById("cfg-color-primary");
    const cfgColorPrimaryPicker = document.getElementById("cfg-color-primary-picker");
    const cfgColorAccent = document.getElementById("cfg-color-accent");
    const cfgColorAccentPicker = document.getElementById("cfg-color-accent-picker");
    
    const cfgAccessTypes = document.getElementById("cfg-access-types");
    const cfgPurposes = document.getElementById("cfg-purposes");

    // Broadcast Modal Elements
    const broadcastModal = document.getElementById("broadcast-modal");
    const btnShowBroadcast = document.getElementById("btn-show-broadcast");
    const btnCloseBroadcast = document.getElementById("close-broadcast");
    const broadcastForm = document.getElementById("broadcast-form");
    const broadcastTarget = document.getElementById("broadcast-target");
    const broadcastMessage = document.getElementById("broadcast-message");

    // HTML-escaping helper. Server-ingested fields (hostname, username, nama,
    // nim, tujuan, keterangan, etc.) come from unauthenticated/agent-supplied
    // data and must never be interpolated raw into innerHTML.
    const escapeHtml = (value) => {
        if (value === null || value === undefined) return "";
        return String(value)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
    };

    // Toast Utility
    const toast = document.getElementById("toast");
    const showToast = (message, isError = false) => {
        toast.textContent = message;
        toast.style.borderColor = isError ? "var(--danger-color)" : "var(--primary-color)";
        toast.classList.remove("hidden");
        setTimeout(() => {
            toast.classList.add("hidden");
        }, 3000);
    };

    // Color Pickers Bidirectional Binding
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

    // Auth Utilities
    const getToken = () => localStorage.getItem("logix_admin_token");
    const setToken = (token) => localStorage.setItem("logix_admin_token", token);
    const clearToken = () => localStorage.removeItem("logix_admin_token");

    const fetchWithAuth = async (url, options = {}) => {
        const token = getToken();
        if (!options.headers) options.headers = {};
        if (token) {
            options.headers["Authorization"] = `Bearer ${token}`;
        }
        
        try {
            const res = await fetch(url, options);
            if (res.status === 401) {
                // Token invalid or expired - trigger login redirect
                clearToken();
                showLoginScreen();
                throw new Error("Sesi berakhir. Silakan masuk kembali.");
            }
            return res;
        } catch (err) {
            throw err;
        }
    };

    const showLoginScreen = () => {
        loginOverlay.classList.remove("hidden");
        appWrapper.classList.add("hidden");
    };

    const showAppScreen = () => {
        loginOverlay.classList.add("hidden");
        appWrapper.classList.remove("hidden");
        
        // Load initially
        fetchActiveWorkstations();
        fetchSessionLogs();
        loadConfiguration();
        fetchAnalytics();
        fetchAuditLog();
    };

    // Login is handled directly by Google OAuth redirection links

    // Logout Handler
    btnLogout.addEventListener("click", async () => {
        try {
            await fetchWithAuth("/api/auth/logout", { method: "POST" });
        } catch(e) {}
        clearToken();
        showLoginScreen();
        showToast("Berhasil keluar.");
    });

    // Fetch and Render Active Workstations
    const fetchActiveWorkstations = async () => {
        try {
            const res = await fetchWithAuth("/api/active");
            if (!res.ok) throw new Error("Gagal mengambil data workstation aktif");
            const pcs = await res.json();
            
            valActivePcs.textContent = pcs.length;
            pcCountBadge.textContent = `${pcs.length} Aktif`;

            // Update modal select options with active hosts
            const currentSelected = broadcastTarget.value;
            broadcastTarget.innerHTML = '<option value="ALL">Semua Workstation</option>';
            pcs.forEach(pc => {
                const option = document.createElement("option");
                option.value = pc.hostname; // control commands are addressed by hostname, not the display name
                option.textContent = pc.device_name || pc.hostname;
                broadcastTarget.appendChild(option);
            });
            broadcastTarget.value = currentSelected;

            if (pcs.length === 0) {
                pcsGrid.innerHTML = `
                    <div class="loading-placeholder">
                        <i class="fa-solid fa-circle-info"></i>
                        <p>Tidak ada workstation aktif saat ini.</p>
                    </div>
                `;
                return;
            }

            pcsGrid.innerHTML = pcs.map(pc => {
                const lastSeenDate = new Date(pc.last_seen);
                const timeStr = lastSeenDate.toLocaleTimeString("id-ID", { hour: "2-digit", minute: "2-digit" });
                const statusClass = pc.status.toLowerCase();
                const statusLabel = pc.status === "ACTIVE" ? "Dalam Penggunaan" : "Terkunci";
                const isUserActive = pc.status === "ACTIVE";
                const hostname = escapeHtml(pc.hostname);
                const deviceName = escapeHtml(pc.device_name) || hostname;
                const showHostnameMeta = pc.device_name && pc.device_name !== pc.hostname;

                return `
                    <div class="workstation-card">
                        <div class="ws-status-light ${statusClass}"></div>
                        <div class="ws-host">${deviceName}</div>
                        ${showHostnameMeta ? `<div class="ws-meta">Hostname: ${hostname}</div>` : ""}
                        <div class="ws-meta">Status: ${statusLabel}</div>
                        <div class="ws-meta"><i class="fa-regular fa-clock"></i> Aktif: ${timeStr}</div>
                        ${pc.username ? `
                            <div class="ws-user-box">
                                <p>Pengguna:</p>
                                <strong>${escapeHtml(pc.username)}</strong>
                            </div>
                        ` : ""}
                        <div class="ws-controls">
                            ${pc.anydesk_id ? `
                                <a href="anydesk:${escapeHtml(pc.anydesk_id)}" class="btn-anydesk-remote" title="Remote via AnyDesk">
                                    <i class="fa-solid fa-desktop"></i> Remote
                                </a>
                            ` : `
                                <button class="btn-anydesk-remote" style="opacity:0.4; cursor:not-allowed;" title="AnyDesk ID tidak terdeteksi" disabled>
                                    <i class="fa-solid fa-desktop"></i> Remote
                                </button>
                            `}
                            ${isUserActive ? `
                                <button class="btn-ws-lock" data-lock-hostname="${hostname}">
                                    <i class="fa-solid fa-lock"></i> Lock
                                </button>
                            ` : `
                                <button class="btn-ws-lock" style="opacity:0.4; cursor:not-allowed;" disabled>
                                    <i class="fa-solid fa-lock"></i> Lock
                                </button>
                            `}
                        </div>
                    </div>
                `;
            }).join("");

        } catch (err) {
            console.error(err);
        }
    };

    // Send Lock Command
    const lockWorkstation = async (hostname) => {
        if (!confirm(`Apakah Anda yakin ingin mengunci stasiun ${hostname} secara paksa?`)) return;
        try {
            const res = await fetchWithAuth("/api/control/lock", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ hostname })
            });
            if (!res.ok) throw new Error("Gagal mengirim perintah kunci");
            showToast(`Perintah KUNCI ditambahkan ke antrean stasiun ${hostname}`);
            fetchActiveWorkstations();
        } catch (err) {
            showToast(err.message, true);
        }
    };

    // Delegated listener for lock buttons (replaces inline onclick, which was
    // vulnerable to JS-string-context injection via agent-supplied hostname).
    pcsGrid.addEventListener("click", (e) => {
        const btn = e.target.closest("[data-lock-hostname]");
        if (btn) lockWorkstation(btn.dataset.lockHostname);
    });

    // Broadcast Modal Actions
    btnShowBroadcast.addEventListener("click", () => broadcastModal.classList.remove("hidden"));
    btnCloseBroadcast.addEventListener("click", () => broadcastModal.classList.add("hidden"));
    
    broadcastForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        const hostname = broadcastTarget.value;
        const param = broadcastMessage.value.trim();

        try {
            const res = await fetchWithAuth("/api/control/broadcast", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ hostname, param })
            });

            if (!res.ok) throw new Error("Gagal mengirim pesan broadcast");
            
            showToast(`Pesan broadcast berhasil dikirim ke target: ${hostname}`);
            broadcastMessage.value = "";
            broadcastModal.classList.add("hidden");
        } catch (err) {
            showToast(err.message, true);
        }
    });

    // Fetch & Render SVG Analytics Graphs
    const fetchAnalytics = async () => {
        try {
            const res = await fetchWithAuth("/api/analytics");
            if (!res.ok) throw new Error("Gagal memuat analitik");
            const data = await res.json();

            // 1. Render Workstation Utilization (Total Hours)
            const workContainer = document.getElementById("chart-utilization");
            if (data.by_workstation.length === 0) {
                workContainer.innerHTML = '<p class="text-secondary">Tidak ada data stasiun.</p>';
            } else {
                const maxHours = Math.max(...data.by_workstation.map(w => w.hours)) || 1;
                workContainer.innerHTML = `
                    <div class="utilization-bar-list">
                        ${data.by_workstation.map(w => {
                            const pct = (w.hours / maxHours) * 100;
                            return `
                                <div class="util-bar-item">
                                    <div class="util-bar-labels">
                                        <strong>${escapeHtml(w.hostname)}</strong>
                                        <span class="text-secondary">${w.hours} jam</span>
                                    </div>
                                    <div class="util-bar-bg">
                                        <div class="util-bar-fill" style="width: ${pct}%"></div>
                                    </div>
                                </div>
                            `;
                        }).join("")}
                    </div>
                `;
            }

            // 2. Render Purposes Breakdown
            const purposeContainer = document.getElementById("chart-purposes");
            if (data.by_purpose.length === 0) {
                purposeContainer.innerHTML = '<p class="text-secondary">Tidak ada data tujuan.</p>';
            } else {
                const maxCount = Math.max(...data.by_purpose.map(p => p.count)) || 1;
                purposeContainer.innerHTML = `
                    <div class="utilization-bar-list">
                        ${data.by_purpose.map(p => {
                            const pct = (p.count / maxCount) * 100;
                            return `
                                <div class="util-bar-item">
                                    <div class="util-bar-labels">
                                        <strong>${escapeHtml(p.purpose)}</strong>
                                        <span class="text-secondary">${p.count} sesi</span>
                                    </div>
                                    <div class="util-bar-bg">
                                        <div class="util-bar-fill" style="width: ${pct}%; background: linear-gradient(90deg, var(--accent-color), var(--success-color))"></div>
                                    </div>
                                </div>
                            `;
                        }).join("")}
                    </div>
                `;
            }

            // 3. Render SVG Hourly line/bar graph
            const hourlyContainer = document.getElementById("chart-hourly");
            const maxHourVal = Math.max(...data.by_hour.map(h => h.count)) || 1;
            
            // Build simple SVG bar chart
            const width = 360;
            const height = 180;
            const padding = 20;
            const chartWidth = width - padding * 2;
            const chartHeight = height - padding * 2;
            const barWidth = chartWidth / 24 - 2;

            let svgContent = `
                <svg viewBox="0 0 ${width} ${height}" style="width: 100%; height: 100%">
                    <!-- Grid Lines -->
                    <line x1="${padding}" y1="${padding}" x2="${width - padding}" y2="${padding}" stroke="rgba(255,255,255,0.05)" stroke-width="1" />
                    <line x1="${padding}" y1="${height - padding}" x2="${width - padding}" y2="${height - padding}" stroke="rgba(255,255,255,0.1)" stroke-width="1.5" />
            `;

            // Draw bars
            data.by_hour.forEach((h, index) => {
                const barHeight = (h.count / maxHourVal) * chartHeight;
                const x = padding + index * (chartWidth / 24);
                const y = height - padding - barHeight;
                
                svgContent += `
                    <rect x="${x}" y="${y}" width="${barWidth}" height="${barHeight}" fill="var(--primary-color)" opacity="0.8" rx="2">
                        <title>Pukul ${h.hour}: ${h.count} sesi</title>
                    </rect>
                `;
                
                // Add labels for key hours (every 4 hours)
                if (index % 4 === 0) {
                    svgContent += `
                        <text x="${x + barWidth/2}" y="${height - 4}" fill="var(--text-secondary)" font-size="8" text-anchor="middle">
                            ${index}
                        </text>
                    `;
                }
            });

            svgContent += `</svg>`;
            hourlyContainer.innerHTML = svgContent;

        } catch (err) {
            console.error(err);
        }
    };

    // Fetch and Render Session Logs Table
    const fetchSessionLogs = async () => {
        try {
            const offset = (currentPage - 1) * itemsPerPage;
            let url = `/api/sessions?limit=${itemsPerPage}&offset=${offset}`;
            if (searchQuery) {
                url += `&username=${encodeURIComponent(searchQuery)}&hostname=${encodeURIComponent(searchQuery)}`;
            }

            const res = await fetchWithAuth(url);
            if (!res.ok) throw new Error("Gagal mengambil data catatan sesi");
            const data = await res.json();
            
            totalLogs = data.total;
            valTotalLogs.textContent = totalLogs;

            if (data.sessions.length === 0) {
                logsTbody.innerHTML = `
                    <tr>
                        <td colspan="8" class="text-center">Tidak ada catatan sesi ditemukan.</td>
                    </tr>
                `;
                btnNext.disabled = true;
                return;
            }

            logsTbody.innerHTML = data.sessions.map(s => {
                const dateStr = new Date(s.timestamp).toLocaleString("id-ID");
                const eventText = escapeHtml(s.event);
                let eventBadge = `<span class="badge">${eventText}</span>`;
                if (s.event === "START" || s.event === "UNLOCK") {
                    eventBadge = `<span class="badge" style="border-color: rgba(16,185,129,0.3); color: var(--success-color)">${eventText}</span>`;
                } else if (s.event === "END" || s.event === "LOCK" || (s.event || "").includes("AUTO")) {
                    eventBadge = `<span class="badge" style="border-color: rgba(239,68,68,0.3); color: var(--danger-color)">${eventText}</span>`;
                }

                return `
                    <tr>
                        <td>${dateStr}</td>
                        <td><strong>${escapeHtml(s.hostname) || "-"}</strong></td>
                        <td>${eventBadge}</td>
                        <td>${escapeHtml(s.session_type) || "-"}</td>
                        <td>${escapeHtml(s.nama || s.username) || "-"}</td>
                        <td>${escapeHtml(s.nim) || "-"}</td>
                        <td>${escapeHtml(s.tujuan) || "-"}</td>
                        <td><small>${escapeHtml(s.keterangan) || "-"}</small></td>
                    </tr>
                `;
            }).join("");

            btnPrev.disabled = currentPage === 1;
            btnNext.disabled = offset + data.sessions.length >= totalLogs;
            pageIndicator.textContent = `Halaman ${currentPage} dari ${Math.ceil(totalLogs / itemsPerPage) || 1}`;

        } catch (err) {
            console.error(err);
            logsTbody.innerHTML = `
                <tr>
                    <td colspan="8" class="text-center" style="color: var(--danger-color)">
                        <i class="fa-solid fa-triangle-exclamation"></i> Gagal memuat data dari server.
                    </td>
                </tr>
            `;
        }
    };

    // Fetch and Render Control Audit Log (Logix Control, Milestone 2).
    // "Terkirim" (queued) is not proof the device executed the command --
    // see docs/LOGIX_CONTROL.md §6.
    const fetchAuditLog = async () => {
        try {
            const res = await fetchWithAuth("/api/audit-log?limit=20");
            if (!res.ok) throw new Error("Gagal mengambil audit log");
            const data = await res.json();

            if (data.actions.length === 0) {
                auditLogTbody.innerHTML = `
                    <tr>
                        <td colspan="7" class="text-center">Belum ada tindakan admin tercatat.</td>
                    </tr>
                `;
                return;
            }

            auditLogTbody.innerHTML = data.actions.map(a => {
                const dateStr = new Date(a.timestamp).toLocaleString("id-ID");
                const statusBadge = a.status === "queued"
                    ? `<span class="badge" style="border-color: rgba(16,185,129,0.3); color: var(--success-color)">Terkirim</span>`
                    : `<span class="badge" style="border-color: rgba(239,68,68,0.3); color: var(--danger-color)">${escapeHtml(a.status)}</span>`;

                return `
                    <tr>
                        <td>${dateStr}</td>
                        <td>${escapeHtml(a.actor_email)}</td>
                        <td><strong>${escapeHtml(a.target_device) || "-"}</strong></td>
                        <td>${escapeHtml(a.action_type)}</td>
                        <td>${statusBadge}</td>
                        <td>${escapeHtml(a.reason) || "-"}</td>
                        <td><small>${escapeHtml(a.result_summary) || "-"}</small></td>
                    </tr>
                `;
            }).join("");

        } catch (err) {
            console.error(err);
            auditLogTbody.innerHTML = `
                <tr>
                    <td colspan="7" class="text-center" style="color: var(--danger-color)">
                        <i class="fa-solid fa-triangle-exclamation"></i> Gagal memuat audit log dari server.
                    </td>
                </tr>
            `;
        }
    };

    // Load Central Configuration
    const loadConfiguration = async () => {
        try {
            const res = await fetch("/api/config");
            if (!res.ok) throw new Error("Gagal memuat konfigurasi");
            const cfg = await res.json();

            cfgLogoText.value = cfg.branding.logoText || "";
            cfgTitle.value = cfg.branding.title || "";
            cfgSubtitle.value = cfg.branding.subtitle || "";
            
            cfgColorPrimary.value = cfg.branding.colors.primary.toUpperCase();
            cfgColorPrimaryPicker.value = cfg.branding.colors.primary;
            cfgColorAccent.value = cfg.branding.colors.accent.toUpperCase();
            cfgColorAccentPicker.value = cfg.branding.colors.accent;

            cfgAccessTypes.value = (cfg.accessTypes || []).join(", ");
            cfgPurposes.value = (cfg.purposes || []).join(", ");

        } catch (err) {
            console.error(err);
            showToast("Gagal memuat pengaturan popup", true);
        }
    };

    // Save Configuration
    btnSaveConfig.addEventListener("click", async (e) => {
        e.preventDefault();
        if (!configForm.checkValidity()) {
            configForm.reportValidity();
            return;
        }

        const newConfig = {
            branding: {
                logoText: cfgLogoText.value.trim(),
                logoPath: "C:\\lab\\logo.png",
                title: cfgTitle.value.trim(),
                subtitle: cfgSubtitle.value.trim(),
                colors: {
                    primary: cfgColorPrimary.value,
                    accent: cfgColorAccent.value,
                    muted: "#C0C0C0",
                    text: "#FFFFFF"
                }
            },
            text: {
                intro: "Isi data penggunaan workstation sebelum memulai sesi.",
                startHint: "Waktu mulai akan dicatat saat tombol Mulai sesi ditekan.",
                namaLabel: "Nama Pengguna",
                nimLabel: "NIM/NIP/NIK",
                accessLabel: "Tipe Akses",
                purposeLabel: "Tujuan Penggunaan",
                ketLabel: "Keterangan Kegiatan",
                submit: "Mulai Sesi",
                hint: "Mohon isi data dengan benar dan selengkap mungkin, apabila ada error atau kesalahan, segera hubungi admin.",
                hintIncomplete: "Lengkapi Nama, NIM/ID, tipe akses, tujuan, dan keterangan.",
                hintReady: "Siap disimpan. Nama, NIM, tujuan, dan keterangan akan dikirim ke SQLite."
            },
            accessTypes: cfgAccessTypes.value.split(",").map(s => s.trim()).filter(Boolean),
            purposes: cfgPurposes.value.split(",").map(s => s.trim()).filter(Boolean),
            requiredFields: ["nama", "nim", "access", "purpose", "keterangan"]
        };

        try {
            const res = await fetchWithAuth("/api/config", {
                method: "PUT",
                headers: {
                    "Content-Type": "application/json"
                },
                body: JSON.stringify(newConfig)
            });

            if (!res.ok) throw new Error("Gagal menyimpan konfigurasi ke server");
            showToast("Pengaturan popup berhasil disimpan!");

        } catch (err) {
            console.error(err);
            showToast(err.message, true);
        }
    });

    // Pagination Click Events
    btnPrev.addEventListener("click", () => {
        if (currentPage > 1) {
            currentPage--;
            fetchSessionLogs();
        }
    });

    btnNext.addEventListener("click", () => {
        currentPage++;
        fetchSessionLogs();
    });

    // Search Input Event
    let searchDebounce;
    searchInput.addEventListener("input", (e) => {
        clearTimeout(searchDebounce);
        searchDebounce = setTimeout(() => {
            searchQuery = e.target.value.trim();
            currentPage = 1;
            fetchSessionLogs();
        }, 400);
    });

    // Download Report Helper
    const downloadReport = (param) => {
        showToast("Menyiapkan unduhan Excel...");
        const token = getToken();
        // Since window.open doesn't support custom headers, download via fetch and triggers local link save
        fetchWithAuth(`/api/reports?${param}`)
            .then(res => {
                if (!res.ok) throw new Error("Gagal membuat laporan");
                return res.blob();
            })
            .then(blob => {
                const url = window.URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url;
                a.download = `report-logix-${new Date().toISOString().slice(0,10)}.xlsx`;
                document.body.appendChild(a);
                a.click();
                a.remove();
                window.URL.revokeObjectURL(url);
                showToast("Laporan Excel berhasil diunduh.");
            })
            .catch(err => {
                showToast(err.message, true);
            });
    };

    btnDlToday.addEventListener("click", () => downloadReport("today=true"));
    btnDlFull.addEventListener("click", () => downloadReport("full=true"));

    // Initial Setup Verification: Check URL for OAuth return token or check localStorage
    const urlParams = new URLSearchParams(window.location.search);
    const queryToken = urlParams.get('token');
    if (queryToken) {
        setToken(queryToken);
        // Strip token query param from browser bar to clean up
        window.history.replaceState({}, document.title, window.location.pathname);
        showToast("Login berhasil!");
        showAppScreen();
    } else if (getToken()) {
        showAppScreen();
    } else {
        showLoginScreen();
    }

    // Auto Polling
    setInterval(() => {
        if (getToken()) {
            fetchActiveWorkstations();
            fetchAnalytics();
        }
    }, 10000); // 10s for active workstations and analytics

    setInterval(() => {
        if (getToken()) {
            fetchSessionLogs();
            fetchAuditLog();
        }
    }, 30000); // 30s for session logs + audit log
});
