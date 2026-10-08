// Mini serveur HTTP natif (sans npm) : sert l'application Angular compilée et relaie /api vers la gateway
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 80;
const GATEWAY_HOST = process.env.GATEWAY_HOST || 'gateway';
const GATEWAY_PORT = process.env.GATEWAY_PORT || 80;

// Dossier du build Angular (copié depuis le stage de build de l'image)
const PUBLIC_DIR = path.join(__dirname, 'public');
const INDEX = path.join(PUBLIC_DIR, 'index.html');

// Types MIME des fichiers produits par le build : sans le bon type, le navigateur refuse les scripts
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.woff2': 'font/woff2',
};

// Fichiers avec empreinte (main-AICTWSOV.js) : leur nom change à chaque build, le navigateur peut
// les garder en cache un an. index.html, lui, doit toujours être revérifié pour pointer vers les bons
const HASHED = /-[A-Z0-9]{8}\.(js|css)$/;

// Sert un fichier du build. Angular génère des noms imprévisibles (empreintes) : une liste blanche
// n'est plus possible, on sert donc tout PUBLIC_DIR, en interdisant d'en sortir (../)
function serveStatic(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { Allow: 'GET, HEAD' });
    return res.end();
  }
  let urlPath;
  try {
    urlPath = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  } catch {
    res.writeHead(400);
    return res.end('Requête invalide');
  }
  const file = path.join(PUBLIC_DIR, path.normalize(urlPath));
  if (file !== PUBLIC_DIR && !file.startsWith(PUBLIC_DIR + path.sep)) {
    res.writeHead(404);
    return res.end('Not found');
  }
  fs.stat(file, (err, stat) => {
    let target = file;
    if (err || !stat.isFile()) {
      // Fichier absent : 404 pour une ressource (.js, .png...), page de l'application sinon
      if (path.extname(urlPath)) {
        res.writeHead(404);
        return res.end('Not found');
      }
      target = INDEX;
    }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(target)] || 'application/octet-stream',
      'Cache-Control': HASHED.test(target) ? 'public, max-age=31536000, immutable' : 'no-cache',
    });
    if (req.method === 'HEAD') return res.end();
    // Lecture en flux : pas de fichier entier en mémoire
    fs.createReadStream(target).on('error', () => res.destroy()).pipe(res);
  });
}

// En-têtes « hop-by-hop » (RFC 7230) : ils décrivent une connexion, pas le message, et ne doivent
// pas être recopiés d'un saut à l'autre. Les recopier (chunked, keep-alive) bloquait les clients HTTP/1.0.
const HOP_BY_HOP = ['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'te', 'trailer', 'upgrade'];

function withoutHopByHop(headers) {
  const copy = { ...headers };
  for (const name of HOP_BY_HOP) delete copy[name];
  return copy;
}

// Relaie les appels /api/* vers la gateway (nom du service Docker, joignable seulement en interne)
function relayToGateway(req, res) {
  const gatewayReq = http.request(
    { host: GATEWAY_HOST, port: GATEWAY_PORT, path: req.url, method: req.method, headers: withoutHopByHop(req.headers) },
    (gatewayRes) => {
      // Node choisit lui-même le découpage adapté au client (chunked en HTTP/1.1, fermeture en HTTP/1.0)
      res.writeHead(gatewayRes.statusCode, withoutHopByHop(gatewayRes.headers));
      gatewayRes.pipe(res);
      // La gateway peut répondre avant la fin de l'envoi (ex. 413 fichier trop gros) :
      // on lit le reste du corps sans le transmettre, sinon le client reste bloqué
      gatewayRes.on('end', () => {
        req.unpipe(gatewayReq);
        req.resume();
      });
    }
  );
  gatewayReq.on('error', () => {
    // Si la réponse a déjà commencé (connexion coupée après un 413), on ne peut plus changer le statut
    if (res.headersSent) return res.end();
    res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: 'Gateway injoignable' }));
  });
  req.pipe(gatewayReq);
}

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/api/')) {
    return relayToGateway(req, res);
  }
  serveStatic(req, res);
});

server.listen(PORT, () => console.log(`Front en écoute sur le port ${PORT}`));

// Arrêt propre à la réception de SIGTERM (docker stop)
process.on('SIGTERM', () => {
  console.log('SIGTERM reçu, arrêt du serveur...');
  server.close(() => process.exit(0));
});
