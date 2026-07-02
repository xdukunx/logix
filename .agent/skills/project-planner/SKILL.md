---
name: project-planner
description: Use when starting a new feature, project, or any task with more than one reasonable approach. Guides requirement gathering, then presents 2-3 concrete architecture/implementation options with trade-offs before any code is written. Do not use for trivial single-file edits or when the user explicitly asks to skip planning.
---

# Project Planner

Ubah permintaan yang masih kabur menjadi rencana yang jelas dan disepakati, SEBELUM menulis kode.

## Kapan aktif

Aktif saat: memulai fitur baru, project baru, atau task apa pun yang punya lebih dari satu cara penyelesaian yang masuk akal. Jangan aktif untuk edit sepele satu file.

## Langkah

### 1. Pahami kebutuhan
- Baca konteks yang ada (codebase, file terkait, Knowledge Items).
- Identifikasi apa yang benar-benar diminta vs apa yang belum jelas.
- Kalau ada ambiguitas yang menentukan arah, tanyakan MAKSIMAL 1-2 pertanyaan terpenting. Jangan membanjiri dengan pertanyaan.

### 2. Petakan kebutuhan
Rangkum secara ringkas:
- **Tujuan**: apa hasil akhir yang diinginkan
- **Batasan**: stack yang harus dipakai, hal yang tidak boleh diubah, deadline/kuota
- **Kriteria selesai**: bagaimana kita tahu ini berhasil (acceptance criteria)

### 3. Sajikan opsi (INTI dari skill ini)
Berikan **2-3 pendekatan berbeda**, bukan variasi kosmetik. Untuk tiap opsi:

- **Nama & deskripsi singkat** pendekatan
- **Diprioritaskan**: apa keunggulan utamanya (mis. kesederhanaan, skalabilitas, kecepatan development)
- **Trade-off**: apa yang dikorbankan
- **Cocok untuk**: kondisi di mana opsi ini paling masuk akal
- **Estimasi effort**: kasar (kecil/sedang/besar)

Kalau ada satu opsi yang jelas paling baik untuk konteks ini, tetap sebutkan alternatifnya tapi rekomendasikan yang terbaik beserta alasannya. Pisahkan dengan jelas mana **fakta**, mana **analisis**, mana **rekomendasi**.

### 4. Tunggu keputusan
Jangan langsung implementasi. Tunggu user memilih, KECUALI user bilang "langsung/pilihkan saja".

### 5. Pecah jadi langkah
Setelah opsi dipilih, buat checklist langkah kecil yang bisa diverifikasi satu per satu. Simpan sebagai plan artifact kalau memungkinkan.

## Prinsip

- Jangan menebak kebutuhan yang tidak jelas — tanya.
- Jangan menyodorkan satu solusi seolah tidak ada alternatif.
- Untuk fase planning ini boleh pakai model kuat (reasoning bagus). Setelah rencana disepakati dan tinggal implementasi mekanis, sarankan turun ke model ringan untuk hemat kuota.
- Jangan menuangkan seluruh implementasi sekaligus. Bangun bertahap sesuai checklist.
