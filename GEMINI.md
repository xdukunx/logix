# GEMINI.md

Aturan spesifik Antigravity. Aturan umum project ada di AGENTS.md — baca keduanya; jika ada konflik, GEMINI.md yang menang.

## Perilaku Antigravity

- Gunakan Planning Mode untuk task kompleks atau project baru. Jangan langsung lompat ke eksekusi.
- Manfaatkan Artifacts (plan, checklist, walkthrough) sebagai bukti kerja yang bisa direview.
- Untuk task berulang, cek dulu apakah ada Workflow yang cocok di `.agent/workflows/` sebelum mengerjakan manual.
- Cek Knowledge Items di awal sesi untuk menghindari kerja berulang dari sesi sebelumnya.

## Model default

- Task rutin: Gemini Flash.
- Reasoning berat / arsitektur / debug lintas file: naikkan ke Claude Sonnet, Claude Opus, atau Gemini Pro (High).
- Ganti model boleh di tengah task; percakapan tetap lanjut.
