// API du cloud de fichiers éphémères (Express + multer)
// Les fichiers sont lus et écrits directement dans STORAGE_DIR (volume Docker) : pas de base de données.
// La date d'expiration est inscrite dans le nom du fichier stocké : le back reste sans état
// (plusieurs instances possibles) et le worker de nettoyage la lit sans parler à l'API.
const express = require('express');
const multer = require('multer');
const crypto = require('crypto');
const fs = require('fs');
const fsp = require('fs/promises');
const os = require('os');
const path = require('path');

const PORT = process.env.PORT || 3000;
const STORAGE_DIR = process.env.STORAGE_DIR || '/data/files';
const MAX_UPLOAD_MB = Number(process.env.MAX_UPLOAD_MB || 50);
const TTL_DEFAULT_H = Number(process.env.TTL_DEFAULT_H || 24);
const TTL_MAX_H = Number(process.env.TTL_MAX_H || 168);
// 0 = pas de quota
const STORAGE_QUOTA_MB = Number(process.env.STORAGE_QUOTA_MB || 0);

// Durée de vie minimale : en dessous, le fichier expirerait avant même d'être téléchargé
const TTL_MIN_H = 1 / 60;
// Envois en cours : dans le volume (même système de fichiers, donc renommage atomique possible)
const INCOMING_DIR = path.join(STORAGE_DIR, '.incoming');
// Nom stocké : <expiration en secondes epoch>-<aléatoire>__<nom d'origine>
const SEPARATOR = '__';
const STORED_NAME = /^(\d+)-[0-9a-f]+__(.+)$/;

fs.mkdirSync(INCOMING_DIR, { recursive: true });

const app = express();
// Ne pas annoncer la techno du serveur aux clients
app.disable('x-powered-by');

// Nom du conteneur dans chaque réponse : permet de voir quelle instance a répondu (démo du scaling)
app.use((req, res, next) => {
  res.set('X-Served-By', os.hostname());
  next();
});

// Nom d'origine nettoyé : sans chemin, et seulement lettres (accents compris), chiffres, espaces et . _ -
function cleanName(original) {
  const base = path.basename(original).replace(/[^\p{L}\p{N}._\- ]/gu, '_').slice(0, 200);
  return base || 'fichier';
}

// Expiration et nom d'origine lus dans le nom stocké, ou null si le nom n'a pas le bon format
function parseStored(name) {
  const m = STORED_NAME.exec(name);
  return m ? { expiresAt: Number(m[1]) * 1000, originalName: m[2] } : null;
}

const isExpired = (info) => info.expiresAt <= Date.now();

// Chemin du fichier demandé, ou null si le nom tente de sortir du dossier (../, /, fichier caché)
function storedPath(name) {
  if (name !== path.basename(name) || name.startsWith('.')) return null;
  return path.join(STORAGE_DIR, name);
}

// Taille totale des fichiers stockés (hors envois en cours), pour le quota
async function usedBytes() {
  const entries = await fsp.readdir(STORAGE_DIR, { withFileTypes: true });
  const sizes = await Promise.all(
    entries.filter((e) => e.isFile()).map((e) => fsp.stat(path.join(STORAGE_DIR, e.name)).then((s) => s.size))
  );
  return sizes.reduce((a, b) => a + b, 0);
}

const upload = multer({
  // Écriture en flux dans .incoming/ : un gros fichier ne passe jamais entièrement en mémoire,
  // et un envoi incomplet n'apparaît jamais dans la liste
  storage: multer.diskStorage({
    destination: INCOMING_DIR,
    filename: (req, file, cb) => cb(null, `${Date.now()}-${crypto.randomBytes(4).toString('hex')}.part`),
  }),
  // Même limite que la gateway : double sécurité si le back est appelé sans elle
  limits: { fileSize: MAX_UPLOAD_MB * 1024 * 1024, files: 1 },
});

// Liste des fichiers encore valides, du plus récent au plus ancien
app.get('/api/files', async (req, res) => {
  const entries = await fsp.readdir(STORAGE_DIR, { withFileTypes: true });
  const files = [];
  for (const e of entries) {
    const info = e.isFile() ? parseStored(e.name) : null;
    // Expiré mais pas encore supprimé par le worker : déjà invisible pour l'utilisateur
    if (!info || isExpired(info)) continue;
    const stat = await fsp.stat(path.join(STORAGE_DIR, e.name));
    files.push({
      name: e.name,
      originalName: info.originalName,
      size: stat.size,
      date: stat.mtime,
      expiresAt: new Date(info.expiresAt),
    });
  }
  files.sort((a, b) => b.date - a.date);
  res.json(files);
});

// Envoi d'un fichier (multipart : champ "file", champ "ttl" optionnel en heures)
app.post('/api/files', upload.single('file'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'Aucun fichier reçu (champ "file" attendu)' });

  // Le fichier n'est encore que dans .incoming/ : on le retire si l'envoi est refusé
  const reject = async (status, error) => {
    await fsp.rm(req.file.path, { force: true });
    res.status(status).json({ error });
  };

  const ttl = req.body.ttl === undefined || req.body.ttl === '' ? TTL_DEFAULT_H : Number(req.body.ttl);
  if (!Number.isFinite(ttl) || ttl < TTL_MIN_H || ttl > TTL_MAX_H) {
    return reject(400, `Durée de vie invalide : entre 1 minute et ${TTL_MAX_H} h`);
  }

  if (STORAGE_QUOTA_MB > 0 && (await usedBytes()) + req.file.size > STORAGE_QUOTA_MB * 1024 * 1024) {
    return reject(507, `Stockage plein (quota de ${STORAGE_QUOTA_MB} Mo)`);
  }

  // multer lit le nom en latin1 : on le réinterprète en UTF-8 pour garder les accents
  const original = cleanName(Buffer.from(req.file.originalname, 'latin1').toString('utf8'));
  const expiresAt = Math.floor(Date.now() / 1000 + ttl * 3600);
  const name = `${expiresAt}-${crypto.randomBytes(4).toString('hex')}${SEPARATOR}${original}`;

  // Renommage atomique (même système de fichiers) : le fichier apparaît d'un coup, complet
  await fsp.rename(req.file.path, path.join(STORAGE_DIR, name));
  res.status(201).json({ name, originalName: original, size: req.file.size, expiresAt: new Date(expiresAt * 1000) });
});

// Téléchargement, sous son nom d'origine ; 410 si le fichier a expiré
app.get('/api/files/:name', async (req, res) => {
  const file = storedPath(req.params.name);
  const info = parseStored(req.params.name);
  if (!file || !info || !fs.existsSync(file)) return res.status(404).json({ error: 'Fichier introuvable' });
  // Le worker passe toutes les N secondes : entre-temps, un fichier expiré ne doit plus être servi
  if (isExpired(info)) return res.status(410).json({ error: 'Fichier expiré' });
  res.download(file, info.originalName);
});

// Suppression (possible même si le fichier a expiré)
app.delete('/api/files/:name', async (req, res) => {
  const file = storedPath(req.params.name);
  if (!file) return res.status(404).json({ error: 'Fichier introuvable' });
  try {
    await fsp.unlink(file);
    res.status(204).end();
  } catch (err) {
    if (err.code === 'ENOENT') return res.status(404).json({ error: 'Fichier introuvable' });
    throw err;
  }
});

// Route de santé utilisée par le healthcheck
app.get('/health', (req, res) => res.send('OK'));

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

// Erreurs : fichier trop gros -> 413, le reste -> 500 sans exposer le détail au client
app.use((err, req, res, next) => {
  if (err instanceof multer.MulterError && err.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({ error: `Fichier trop gros (max ${MAX_UPLOAD_MB} Mo)` });
  }
  if (err instanceof multer.MulterError) return res.status(400).json({ error: err.message });
  console.error(err);
  res.status(500).json({ error: 'Erreur serveur' });
});

const server = app.listen(PORT, () =>
  console.log(`Back en écoute sur le port ${PORT} (stockage : ${STORAGE_DIR}, durée de vie ${TTL_DEFAULT_H} h par défaut, ${TTL_MAX_H} h max)`)
);

// Arrêt propre à la réception de SIGTERM (docker stop)
process.on('SIGTERM', () => {
  console.log("SIGTERM reçu, arrêt de l'API...");
  server.close(() => process.exit(0));
});
