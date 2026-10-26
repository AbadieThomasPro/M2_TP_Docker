// Tests de l'API : le vrai serveur (src/server.js) est lancé dans un sous-processus et appelé en HTTP,
// comme le ferait la gateway. Lanceur de tests intégré à Node (node:test) : aucune dépendance ajoutée.
// Lancement : npm test (dans le conteneur de CI, ou en local avec les dépendances installées)
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const SERVER = path.join(__dirname, '..', 'src', 'server.js');

// Port libre choisi par le système : plusieurs exécutions (ou une autre appli) ne se gênent pas
function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.unref();
    s.on('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

// Démarre l'API sur un dossier de stockage temporaire ; petites limites pour tester les refus
// sans envoyer de gros fichiers (1 Mo par envoi, 2 Mo au total)
async function startServer() {
  const port = await freePort();
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'cloud-test-'));
  const storage = path.join(dir, 'files');
  const proc = spawn(process.execPath, [SERVER], {
    env: { ...process.env, PORT: String(port), STORAGE_DIR: storage, MAX_UPLOAD_MB: '1', STORAGE_QUOTA_MB: '2', TTL_DEFAULT_H: '24', TTL_MAX_H: '168' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const base = `http://127.0.0.1:${port}`;
  // Attente bornée (5 s) : un serveur qui ne démarre pas fait échouer le test au lieu de le bloquer
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`${base}/health`)).ok) return { proc, base, dir, storage };
    } catch { /* pas encore à l'écoute */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  proc.kill('SIGKILL');
  throw new Error("L'API n'a pas démarré en 5 s");
}

async function stopServer(srv) {
  if (srv.proc.exitCode === null) {
    srv.proc.kill('SIGTERM');
    await new Promise((r) => srv.proc.once('exit', r));
  }
  await fsp.rm(srv.dir, { recursive: true, force: true });
}

function upload(base, content, filename, ttl) {
  const form = new FormData();
  form.append('file', new Blob([content]), filename);
  if (ttl !== undefined) form.append('ttl', String(ttl));
  return fetch(`${base}/api/files`, { method: 'POST', body: form });
}

const list = async (base) => (await fetch(`${base}/api/files`)).json();

let srv;
before(async () => { srv = await startServer(); });
after(async () => { await stopServer(srv); });

test('GET /health répond 200 sans dépendre des fichiers', async () => {
  const res = await fetch(`${srv.base}/health`);
  assert.equal(res.status, 200);
  assert.equal(await res.text(), 'OK');
});

test("chaque réponse indique l'instance qui a répondu (X-Served-By)", async () => {
  const res = await fetch(`${srv.base}/api/files`);
  assert.ok(res.headers.get('x-served-by'));
});

test('cycle complet : envoi, liste, téléchargement, suppression', async () => {
  const sent = await upload(srv.base, 'bonjour', 'été 2026.txt', 1);
  assert.equal(sent.status, 201);
  const body = await sent.json();
  // Nom stocké : <expiration epoch>-<aléatoire>__<nom d'origine>, accents conservés
  assert.match(body.name, /^\d+-[0-9a-f]+__été 2026\.txt$/);
  assert.equal(body.originalName, 'été 2026.txt');
  const expires = new Date(body.expiresAt).getTime();
  assert.ok(Math.abs(expires - (Date.now() + 3600 * 1000)) < 60 * 1000, 'expiration à environ 1 h');

  assert.ok((await list(srv.base)).some((f) => f.name === body.name), 'le fichier apparaît dans la liste');

  const dl = await fetch(`${srv.base}/api/files/${encodeURIComponent(body.name)}`);
  assert.equal(dl.status, 200);
  assert.equal(await dl.text(), 'bonjour');

  const del = await fetch(`${srv.base}/api/files/${encodeURIComponent(body.name)}`, { method: 'DELETE' });
  assert.equal(del.status, 204);
  const again = await fetch(`${srv.base}/api/files/${encodeURIComponent(body.name)}`);
  assert.equal(again.status, 404);
});

test('envoi sans fichier : 400', async () => {
  const res = await fetch(`${srv.base}/api/files`, { method: 'POST', body: new FormData() });
  assert.equal(res.status, 400);
});

test('durée de vie invalide : 400, et rien ne reste dans les envois en cours', async () => {
  for (const ttl of ['0', 'abc', '1000']) {
    const res = await upload(srv.base, 'x', 'ttl.txt', ttl);
    assert.equal(res.status, 400, `ttl=${ttl}`);
  }
  assert.deepEqual(await fsp.readdir(path.join(srv.storage, '.incoming')), []);
});

test('fichier plus gros que MAX_UPLOAD_MB : 413, et la liste ne change pas', async () => {
  const before = (await list(srv.base)).length;
  const res = await upload(srv.base, Buffer.alloc(1024 * 1024 + 1), 'gros.bin');
  assert.equal(res.status, 413);
  assert.equal((await list(srv.base)).length, before);
});

test('quota de stockage atteint : 507', async () => {
  const names = [];
  // 2 envois de 0,9 Mo tiennent dans le quota de 2 Mo, le 3e le dépasse
  for (let i = 0; i < 2; i++) {
    const res = await upload(srv.base, Buffer.alloc(900 * 1024), `quota${i}.bin`);
    assert.equal(res.status, 201);
    names.push((await res.json()).name);
  }
  const res = await upload(srv.base, Buffer.alloc(900 * 1024), 'quota2.bin');
  assert.equal(res.status, 507);
  for (const n of names) await fetch(`${srv.base}/api/files/${encodeURIComponent(n)}`, { method: 'DELETE' });
});

test('fichier expiré : absent de la liste, 410 au téléchargement, mais supprimable', async () => {
  // Déposé directement dans le dossier, comme un fichier dont la durée de vie vient de passer
  // et que le worker n'a pas encore supprimé
  const name = `${Math.floor(Date.now() / 1000) - 60}-abcd1234__vieux.txt`;
  fs.writeFileSync(path.join(srv.storage, name), 'périmé');

  assert.ok(!(await list(srv.base)).some((f) => f.name === name));
  assert.equal((await fetch(`${srv.base}/api/files/${name}`)).status, 410);
  assert.equal((await fetch(`${srv.base}/api/files/${name}`, { method: 'DELETE' })).status, 204);
});

test('chemins piégés et noms hors format : 404', async () => {
  for (const name of ['..%2Fpackage.json', '.incoming', 'pas-un-fichier-stocke.txt']) {
    const res = await fetch(`${srv.base}/api/files/${name}`);
    assert.equal(res.status, 404, name);
  }
});

test('route inconnue : 404', async () => {
  assert.equal((await fetch(`${srv.base}/inconnue`)).status, 404);
});

test("SIGTERM : l'API s'arrête proprement, code de sortie 0", async () => {
  // Instance à part : arrêter celle des autres tests fausserait leur ordre d'exécution
  const own = await startServer();
  const t0 = Date.now();
  own.proc.kill('SIGTERM');
  const code = await new Promise((r) => own.proc.once('exit', (c) => r(c)));
  assert.equal(code, 0);
  assert.ok(Date.now() - t0 < 2000, 'arrêt en moins de 2 s');
  await fsp.rm(own.dir, { recursive: true, force: true });
});
