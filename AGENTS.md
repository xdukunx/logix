# AGENTS.md

Aturan kerja untuk agent di project ini. Berlaku sepanjang sesi, untuk model apa pun (Gemini / Claude).

## Stack

- Fullstack: Python (backend) + TypeScript/JavaScript (frontend).
- Sebutkan tool/framework spesifik saat mulai kerja jika belum jelas dari codebase; jangan asumsikan.

## Prinsip Kerja (urutan prioritas)

1. **Kualitas di atas kecepatan.** Kode yang benar dan bisa diverifikasi lebih penting daripada jawaban cepat.
2. **Rencanakan sebelum menulis kode.** Untuk task apa pun yang menyentuh lebih dari 1 file atau punya lebih dari 1 cara penyelesaian, WAJIB masuk fase planning dulu (lihat bagian Planning).
3. **Perubahan minimal.** Ubah hanya yang diminta. Jangan refactor, optimasi, atau ganti struktur bagian lain tanpa diminta. Kalau lihat masalah di tempat lain, sebut sebagai rekomendasi terpisah — jangan langsung eksekusi.

## Planning (WAJIB sebelum coding untuk task non-trivial)

Sebelum menulis kode, lakukan ini dan tunjukkan ke user:

1. **Klarifikasi kebutuhan.** Kalau ada yang ambigu, tanyakan dulu — jangan menebak. Maksimal fokus pada 1-2 pertanyaan terpenting.
2. **Pertimbangkan beberapa pendekatan.** Untuk keputusan desain/arsitektur, sajikan 2-3 opsi berbeda, masing-masing dengan:
   - Apa yang diprioritaskan opsi ini
   - Trade-off / kekurangannya
   - Kapan opsi ini paling cocok
3. **Tunggu pilihan user** sebelum implementasi, kecuali user eksplisit bilang "langsung saja / pilihkan".
4. Setelah disepakati, pecah jadi langkah-langkah kecil yang bisa diverifikasi satu per satu.

Jangan menuangkan seluruh solusi dalam satu prompt raksasa. Bangun bertahap.

## Efisiensi Model & Kuota

- Default ke model ringan (Gemini Flash) untuk task rutin: scaffolding, boilerplate, edit sederhana, formatting.
- Pindah ke model kuat (Claude Sonnet/Opus, Gemini Pro High) hanya untuk: keputusan arsitektur, debugging lintas file, reasoning yang rumit.
- Aturan praktis: mulai dengan model ringan, naik ke model kuat kalau satu task sudah menyentuh 3+ file atau gagal 2x berturut-turut, lalu turun lagi setelah jalan buntu terpecahkan.
- Untuk planning berat, boleh pakai model kuat; untuk implementasi mekanis setelahnya, turunkan ke model ringan.

## Verifikasi

- Setelah membuat perubahan, jelaskan singkat APA yang diubah dan MENGAPA.
- Untuk perubahan yang bisa dites, jalankan test atau tunjukkan cara memverifikasinya.
- Jangan klaim sesuatu berhasil tanpa bukti. Kalau belum diverifikasi, katakan begitu.

## Kejujuran

- Jangan mengarang: nama library, fungsi, parameter, API, atau angka yang tidak kamu ketahui pasti.
- Kalau tidak yakin atau butuh info yang tidak ada di codebase, katakan terus terang dan sebutkan asumsi yang kamu pakai sebelum lanjut.
- Jangan menyetujui ide user hanya karena disampaikan dengan percaya diri. Kalau ada masalah teknis, sampaikan langsung dengan sopan.

## Keamanan

- Jangan menaruh secret/API key/password di kode atau commit. Pakai environment variable.
- Untuk perintah terminal yang destruktif (hapus, force push, drop db), minta konfirmasi eksplisit dulu.

## Aturan untuk Sub-Agent (mode Manager/Worker)

Kalau kamu Manager yang membuat Worker, teruskan aturan inti ini ke setiap Worker dalam instruksi awalnya:
- Perubahan minimal, tidak refactor tanpa diminta.
- TypeScript untuk frontend, ikuti konvensi Python yang ada untuk backend.
- Tidak meninggalkan `console.log` / `print` debug di kode final.
- Verifikasi sebelum klaim selesai.
