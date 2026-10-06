// Mini serveur HTTP natif (sans npm) qui sert la page du front
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 80;
const PROXY_HOST = process.env.PROXY_HOST || 'proxy';
const PROXY_PORT = process.env.PROXY_PORT || 80;

// Seuls ces fichiers de src/ sont servis
const FILES = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/index.html': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'application/javascript; charset=utf-8'],
};

// Relaie les appels /api/* vers le proxy (nom du service Docker, joignable seulement en interne)
function relayToProxy(req, res) {
  const proxyReq = http.request(
    { host: PROXY_HOST, port: PROXY_PORT, path: req.url, method: req.method, headers: req.headers },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  );
  proxyReq.on('error', () => {
    res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: 'Proxy injoignable' }));
  });
  req.pipe(proxyReq);
}

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/api/')) {
    return relayToProxy(req, res);
  }

  const file = FILES[req.url];
  if (!file) {
    res.writeHead(404);
    return res.end('Not found');
  }
  fs.readFile(path.join(__dirname, 'src', file[0]), (err, data) => {
    if (err) {
      res.writeHead(500);
      return res.end('Erreur serveur');
    }
    res.writeHead(200, { 'Content-Type': file[1] });
    res.end(data);
  });
});

server.listen(PORT, () => console.log(`Front en écoute sur le port ${PORT}`));

// Arrêt propre à la réception de SIGTERM (docker stop)
process.on('SIGTERM', () => {
  console.log('SIGTERM reçu, arrêt du serveur...');
  server.close(() => process.exit(0));
});
