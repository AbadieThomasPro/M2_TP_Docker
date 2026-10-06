// Mini API HTTP native (sans npm) qui renvoie une phrase
const http = require('http');

const PORT = process.env.PORT || 3000;
const PHRASE = process.env.PHRASE || 'Hello World depuis le back !';

const server = http.createServer((req, res) => {
  // Route principale : renvoie la phrase à afficher dans le front
  if (req.method === 'GET' && req.url === '/api/phrase') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    return res.end(JSON.stringify({ phrase: PHRASE }));
  }

  // Route de santé utilisée par le healthcheck
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200);
    return res.end('OK');
  }

  res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(PORT, () => console.log(`Back en écoute sur le port ${PORT}`));

// Arrêt propre à la réception de SIGTERM (docker stop)
process.on('SIGTERM', () => {
  console.log('SIGTERM reçu, arrêt de l\'API...');
  server.close(() => process.exit(0));
});
