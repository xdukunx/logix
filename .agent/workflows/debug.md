---
description: Protokol debugging 5 langkah terstruktur — isolasi, reproduksi, log, perbaiki, verifikasi. Ubah hanya penyebab error, bukan bagian lain.
---

1. **Isolasi**: Persempit lokasi masalah. Identifikasi file/fungsi/baris yang paling mungkin jadi penyebab. Jangan menebak — tunjukkan bukti.
2. **Reproduksi**: Pastikan bisa memicu error secara konsisten. Kalau tidak bisa reproduksi, katakan dan minta info yang kurang.
3. **Log**: Tambahkan logging/inspeksi sementara secukupnya untuk memastikan akar masalah. Ingat menghapusnya nanti.
4. **Perbaiki**: Ubah HANYA bagian yang menyebabkan error. Jangan refactor atau ubah logika lain tanpa diminta.
5. **Verifikasi**: Jalankan ulang untuk konfirmasi error hilang dan tidak ada regresi. Hapus logging sementara. Jelaskan singkat apa yang salah dan apa yang diubah.
