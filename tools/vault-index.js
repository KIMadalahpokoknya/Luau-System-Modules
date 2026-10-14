/* Regenerasi vault/index.json dari isi folder vault/scripts/.
   Jalankan dari root repo ini:  node tools/vault-index.js   (atau: npm run vault)
   Judul/kategori/ringkasan tiap file diisi lewat tabel META di bawah.
   Hasilnya dibaca situs portofolio lewat URL mentah GitHub, jadi jangan pindah path. */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SCRIPTS = path.join(ROOT, 'vault', 'scripts');
const OUT = path.join(ROOT, 'vault', 'index.json');

const META = {
    'ProfileStore.lua': {
        title: 'ProfileStore v2', cat: 'Data', tags: ['DataStore', 'session lock', 'backoff', 'Luau'],
        updated: '2026-10-13',
        summary: 'Pembungkus DataStore dengan session lock, retry + jitter, UpdateAsync (bukan SetAsync), dan flush bertahap saat server ditutup.'
    },
    'RemoteGuard.lua': {
        title: 'RemoteGuard', cat: 'Keamanan', tags: ['exploit', 'rate limit', 'validasi', 'RemoteEvent'],
        updated: '2026-10-13',
        summary: 'Semua remote wajib lolos token-bucket rate limit, cek tipe & clamp argumen, lalu strike counter sampai kick. Client dianggap musuh.'
    },
    'Matchmaking.lua': {
        title: 'Matchmaking v3', cat: 'Sistem', tags: ['mmr', 'region', 'backfill', 'teleport'],
        updated: '2026-10-13',
        summary: 'Antrian 5v5: jendela MMR melebar seiring waktu, prioritas region, backfill bot saat kelewatan batas, dan rollback kalau teleport gagal.'
    },
    'NetSignal.lua': {
        title: 'NetSignal', cat: 'Networking', tags: ['batching', 'bandwidth', 'unreliable', 'optimasi'],
        updated: '2026-10-13',
        summary: 'Signal tereplikasi dengan batching per-tick dan last-write-wins: 300 fire/detik jadi 30 paket, termasuk jalur UnreliableRemoteEvent <900 byte.'
    },
    'RbxHttpAuth.lua': {
        title: 'RbxHttpAuth', cat: 'Integrasi', tags: ['HttpService', 'proxy', 'csrf', 'cache'],
        updated: '2026-10-13',
        summary: 'Panggil API Roblox tanpa membocorkan kredensial: bearer token ke worker proxy, cache + stale-if-error, retry sadar-429. Termasuk file worker-nya.'
    },
    'PerfProbe.lua': {
        title: 'PerfProbe', cat: 'Performa', tags: ['profiling', 'p95', 'memory leak', 'budget'],
        updated: '2026-10-13',
        summary: 'Ukur frame time dan durasi sistem pakai persentil (bukan rata-rata), deteksi leak dari tren memory, dan siap dipasangkan dengan Microprofiler.'
    }
};

function fail(msg) {
    console.error('✗ ' + msg);
    process.exit(1);
}

function main() {
    if (!fs.existsSync(SCRIPTS)) fail(`folder tidak ada: ${SCRIPTS}\n   jalankan dari root repo ini (yang ada package.json-nya).`);
    const files = fs.readdirSync(SCRIPTS).filter(f => f.endsWith('.lua')).sort();
    if (!files.length) fail('vault/scripts/ kosong — tidak ada .lua untuk diindeks.');
    const missing = files.filter(f => !META[f]);
    if (missing.length) {
        console.warn('⚠ belum ada META untuk:', missing.join(', '), '\n   -> entri dibuat otomatis, tambahkan ringkasannya di tools/vault-index.js');
    }

    const entries = files.map(file => {
        const body = fs.readFileSync(path.join(SCRIPTS, file), 'utf8');
        const lines = body.split('\n').filter(l => l.trim().length).length;
        const meta = META[file] || {};
        return {
            id: path.basename(file, '.lua'),
            title: meta.title || path.basename(file, '.lua'),
            cat: meta.cat || 'Lainnya',
            tags: meta.tags || [],
            summary: meta.summary || '',
            lang: 'Luau',
            file: 'scripts/' + file,
            lines,
            bytes: Buffer.byteLength(body),
            // Tanggal = kapan FILE-nya terakhir diubah (bukan kapan generator jalan),
            // supaya tidak semua modul tampak "baru" cuma karena ada satu file nambah.
            updated: meta.updated || fs.statSync(path.join(SCRIPTS, file)).mtime.toISOString().slice(0, 10)
        };
    });

    entries.sort((a, b) => a.title.localeCompare(b.title));
    const out = {
        version: 1,
        author: 'Kimtan / CukingStudio',
        note: 'Tambah script: taruh .lua di vault/scripts/ lalu jalankan node tools/vault-index.js. Manifest ini dibaca situs portofolio Kimtan.',
        totalLines: entries.reduce((sum, e) => sum + e.lines, 0),
        entries
    };
    fs.writeFileSync(OUT, JSON.stringify(out, null, 2) + '\n');
    console.log(`✓ vault/index.json: ${entries.length} script, ${out.totalLines} baris`);
    console.log(`  tempel ini ke SITE_CONFIG.vault.fallbackStats di repo portofolio (kalau angkanya berubah):`);
    console.log(`  fallbackStats: { scripts: ${entries.length}, lines: ${out.totalLines} }`);
}

main();
