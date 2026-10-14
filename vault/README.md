# vault/

- `scripts/*.lua` — isi modul. Nama file = nama ModuleScript.
- `index.json` — manifest yang dibaca situs portofolio. **Jangan dihapus/dipindah**, dan
  jangan diedit manual: hasilkan dengan `node tools/vault-index.js` dari root repo.

Nambah file `.lua` baru langsung muncul di situs begitu `index.json` ikut di-commit —
angka baris dan ukuran dihitung dari file aslinya, bukan diketik.
