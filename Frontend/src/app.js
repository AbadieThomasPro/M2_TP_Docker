// Récupère la phrase du back (via le front puis le proxy) et l'affiche dans #message
const message = document.getElementById('message');

fetch('/api/phrase')
  .then((res) => {
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  })
  .then((data) => {
    message.textContent = data.phrase;
  })
  .catch(() => {
    message.textContent = 'Impossible de récupérer la phrase.';
  });
