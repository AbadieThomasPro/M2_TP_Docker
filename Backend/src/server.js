// API du mini cloud de stockage (Express + multer)
// Les fichiers sont lus et écrits directement dans STORAGE_DIR (volume Docker) : pas de base de données.
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
const PHRASE = process.env.PHRASE || 'Hello World depuis le back !';

// Séparateur entre le préfixe unique et le nom d'origine dans le nom stocké
const SEPARATOR = '__';

fs.mkdirSync(STORAGE_DIR, { recursive: true });

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

// Préfixe horodaté + aléatoire : deux envois du même nom (ou deux instances du back) n'écrasent rien
function storedName(original) {
  return `${Date.now()}-${crypto.randomBytes(4).toString('hex')}${SEPARATOR}${cleanName(original)}`;
}

function originalName(stored) {
  const i = stored.indexOf(SEPARATOR);
  return i === -1 ? stored : stored.slice(i + SEPARATOR.length);
}

// Chemin du fichier demandé, ou null si le nom tente de sortir du dossier (../, /, fichier caché)
function storedPath(name) {
  if (name !== path.basename(name) || name.startsWith('.')) return null;
  return path.join(STORAGE_DIR, name);
}

const upload = multer({
  // Écriture directe sur disque (dans le volume) : un gros fichier ne passe jamais entièrement en mémoire
  storage: multer.diskStorage({
    destination: STORAGE_DIR,
    // multer lit le nom en latin1 : on le réinterprète en UTF-8 pour garder les accents
    filename: (req, file, cb) => cb(null, storedName(Buffer.from(file.originalname, 'latin1').toString('utf8'))),
  }),
  // Même limite que la gateway : double sécurité si le back est appelé sans elle
  limits: { fileSize: MAX_UPLOAD_MB * 1024 * 1024, files: 1 },
});

// Liste des fichiers, du plus récent au plus ancien
app.get('/api/files', async (req, res) => {
  const entries = await fsp.readdir(STORAGE_DIR, { withFileTypes: true });
  const files = await Promise.all(
    entries
      .filter((e) => e.isFile() && !e.name.startsWith('.'))
      .map(async (e) => {
        const stat = await fsp.stat(path.join(STORAGE_DIR, e.name));
        return { name: e.name, originalName: originalName(e.name), size: stat.size, date: stat.mtime };
      })
  );
  files.sort((a, b) => b.date - a.date);
  res.json(files);
});

// Envoi d'un fichier (formulaire multipart, champ "file")
app.post('/api/files', upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'Aucun fichier reçu (champ "file" attendu)' });
  res.status(201).json({
    name: req.file.filename,
    originalName: originalName(req.file.filename),
    size: req.file.size,
  });
});

// Téléchargement, sous son nom d'origine
app.get('/api/files/:name', async (req, res) => {
  const file = storedPath(req.params.name);
  if (!file || !fs.existsSync(file)) return res.status(404).json({ error: 'Fichier introuvable' });
  res.download(file, originalName(req.params.name));
});

// Suppression
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

// Route de démo de la version Hello World, gardée tant que le front l'utilise
app.get('/api/phrase', (req, res) => res.json({ phrase: PHRASE }));

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

const server = app.listen(PORT, () => console.log(`Back en écoute sur le port ${PORT} (stockage : ${STORAGE_DIR})`));

// Arrêt propre à la réception de SIGTERM (docker stop)
process.on('SIGTERM', () => {
  console.log("SIGTERM reçu, arrêt de l'API...");
  server.close(() => process.exit(0));
});
