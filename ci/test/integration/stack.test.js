// Tests d'intégration : la stack complète (front → gateway → back → volume ← cleaner) est appelée comme
// par un navigateur, depuis le réseau "public". Lancés par ci/compose.integration.yml.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const BASE = process.env.BASE_URL || 'http://front';
const STORAGE_DIR = process.env.STORAGE_DIR || '/data/files';
const INTERVAL_S = Number(process.env.CLEANUP_INTERVAL_S || 5);

function upload(content, filename, ttl) {
  const form = new FormData();
  form.append('file', new Blob([content]), filename);
  if (ttl !== undefined) form.append('ttl', String(ttl));
  return fetch(`${BASE}/api/files`, { method: 'POST', body: form });
}

test("le front sert l'application Angular", async () => {
  const res = await fetch(`${BASE}/`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/html/);
  assert.match(await res.text(), /<app-root/);
});

test('cycle complet à travers front, gateway et back', async () => {
  const sent = await upload('contenu de test', 'intégration.txt', 1);
  assert.equal(sent.status, 201);
  const { name } = await sent.json();
  // X-Served-By posé par le back et relayé jusqu'au client : la chaîne de bout en bout a répondu
  const list = await fetch(`${BASE}/api/files`);
  assert.ok(list.headers.get('x-served-by'));
  assert.ok((await list.json()).some((f) => f.name === name));

  const dl = await fetch(`${BASE}/api/files/${encodeURIComponent(name)}`);
  assert.equal(dl.status, 200);
  assert.equal(await dl.text(), 'contenu de test');

  assert.equal((await fetch(`${BASE}/api/files/${encodeURIComponent(name)}`, { method: 'DELETE' })).status, 204);
});

test('envoi trop gros : refusé par la gateway (413) sans atteindre le back', async () => {
  const res = await upload(Buffer.alloc(2 * 1024 * 1024), 'trop-gros.bin');
  assert.equal(res.status, 413);
  // Page HTML de nginx et non le JSON du back : c'est bien la gateway qui a refusé
  assert.match(res.headers.get('content-type') || '', /text\/html/);
});

test("isolation réseau : depuis l'extérieur, seul le front est joignable", async () => {
  for (const host of ['http://gateway', 'http://back:3000']) {
    // Le nom du service n'existe même pas sur le réseau public : la résolution DNS échoue
    await assert.rejects(fetch(`${host}/health`, { signal: AbortSignal.timeout(3000) }), `${host} ne doit pas être joignable`);
  }
});

test('le cleaner supprime un fichier expiré du volume', async () => {
  // Fichier déposé directement dans le volume avec une expiration passée, comme s'il avait vécu sa durée
  const name = `${Math.floor(Date.now() / 1000) - 60}-c1ea4e75__expire-integration.txt`;
  const file = path.join(STORAGE_DIR, name);
  fs.writeFileSync(file, 'à supprimer');
  // Attente bornée : 3 intervalles du cleaner au plus, puis échec plutôt qu'un test bloqué
  const deadline = Date.now() + INTERVAL_S * 3 * 1000;
  while (fs.existsSync(file) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 500));
  assert.ok(!fs.existsSync(file), `fichier toujours présent après ${INTERVAL_S * 3} s`);
});
