// Mini serveur HTTP natif (sans npm) qui sert la page du front
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 80;
const GATEWAY_HOST = process.env.GATEWAY_HOST || 'gateway';
const GATEWAY_PORT = process.env.GATEWAY_PORT || 80;

// Seuls ces fichiers de src/ sont servis
const FILES = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/index.html': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'application/javascript; charset=utf-8'],
};

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
