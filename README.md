# Luau System Modules

Modul Luau yang saya pakai di proyek CukingStudio. Isinya bukan snippet tempel — tiap file
adalah versi perapihan dari kode produksi, dengan komentar yang menjelaskan **kenapa** sebuah
pendekatan dipilih, bukan cuma apa yang dilakukan.

Repo ini **publik dan MIT**: silakan baca, kutip, fork, atau pakai di game kamu (termasuk komersial).
Kode situs portofolio saya ada di repo terpisah dan memang tidak saya buka.

## Daftar modul

| File | Kategori | Masalah yang dipecahkan |
|---|---|---|
| `vault/scripts/ProfileStore.lua` | Data | Write-but-read & tabrakan session → session lock + `UpdateAsync` + backoff |
| `vault/scripts/RemoteGuard.lua` | Keamanan | Spam remote & argumen ngawur → token bucket, validasi tipe, strike → kick |
| `vault/scripts/Matchmaking.lua` | Sistem | Antrian lama & tim timpang → jendela MMR melebar, prioritas region, backfill, rollback |
| `vault/scripts/NetSignal.lua` | Networking | Remote 300×/detik jebol bandwidth → batching per-tick + last-write-wins |
| `vault/scripts/RbxHttpAuth.lua` | Integrasi | Kredensial bocor di game → proxy worker + cache + retry sadar-429 |
| `vault/scripts/PerfProbe.lua` | Performa | Optimasi pakai feeling → persentil p50/p95/p99 + deteksi tren memory |

Jumlah baris tiap file tidak saya tulis tangan — dihitung dari file aslinya lewat
`vault/index.json` (lihat di bawah), jadi angkanya tidak mungkin basi.

## Cara pakai di Studio

1. Insert **ModuleScript** di `ServerScriptService` (untuk `RemoteGuard`, `Matchmaking`,
   `NetSignal`, `ProfileStore`, `PerfProbe`) atau di `ReplicatedStorage` kalau client ikut memanggil.
2. Tempel isi file, nama modul sama dengan nama file (mis. `ProfileStore`).
3. `local ProfileStore = require(game:GetService("ServerScriptService").ProfileStore)`.
4. Tiap modul tidak punya dependensi ke modul lain di repo ini — boleh diambil satu-satu.

Kecuali `RbxHttpAuth.lua`: itu butuh worker di sisi server (HTTP proxy) — file worker-nya ikut
di dalam komentar di bagian bawah modul itu, dan **token tidak boleh** ditempel di Script yang
ada di dalam place.

## Status jujur

Semua modul di folder ini dibaca ulang manual, **belum** saya jalankan di Roblox Studio maupun
diuji otomatis. Kalau kamu nemu bug atau cara yang lebih baik:
[buka issue](https://github.com/KIMadalahpokoknya/Luau-System-Modules/issues/new) — lebih berguna
daripada diam-diam fork terus rusak.

## Nambah / ngubah script

```bash
# 1. taruh file .lua di vault/scripts/
# 2. regenerasi manifest (jumlah baris & ukuran dihitung otomatis)
node tools/vault-index.js
# 3. judul/kategori/ringkasan kustom: tambahkan ke tabel META di tools/vault-index.js
```

`npm run vault` = perintah yang sama.

`vault/index.json` adalah **satu-satunya** yang dibaca situs portofolio
([ckskimtan.vercel.app](https://ckskimtan.vercel.app/#vault)) lewat URL mentah GitHub.
Jadi:

- jangan pindah/rename `vault/index.json` dan `vault/scripts/` — portofolio mengambil
  `https://raw.githubusercontent.com/KIMadalahpokoknya/Luau-System-Modules/main/vault/index.json`;
- setelah commit ke `main`, situs ikut terisi ulang tanpa deploy ulang (manifest di-cache ±5 menit).

## Lisensi

MIT — bebas dipakai, termasuk untuk komersial. Kalau dipakai untuk sesuatu yang besar,
kabari saya di Discord CukingStudio, saya senang lihat hasilnya.
