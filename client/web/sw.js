// ============================================================================
// sw.js — Service Worker di AnimeRank (PWA)
// ============================================================================
//
// Cosa fa
// -------
// 1. Mette in cache la "shell" dell'app (pagina, icona, manifesto, avvio) cosi'
//    l'app si apre anche senza rete.
// 2. Per tutto cio' che CAMBIA a ogni versione (pagina, `main.dart.js`,
//    `flutter_bootstrap.js`, i file `.json`/`.bin` dei manifest) usa
//    **network-first**: quando sei online la versione nuova arriva subito, e
//    solo se la rete manca si ripiega sulla copia in cache.
// 3. Per cio' che NON cambia mai (font, icone, `canvaskit/`) usa **cache-first**:
//    si scarica una volta sola e poi parte istantaneamente.
// 4. Avvisa la pagina quando c'e' una nuova versione pronta, cosi' l'app puo'
//    mostrare "Aggiorna" (stessa idea dell'APK su Android).
//
// Nota su iOS
// -----------
// Su iPhone il service worker si aggiorna quando l'utente riapre l'app dalla
// home (Safari lo fa in background). L'avviso compare quindi alla prima
// apertura dopo il rilascio.
//
// Versione
// --------
// `VERSION` viene sostituito a ogni deploy (con il numero di build o il
// timestamp). Cambia il nome delle cache, cosi' le copie vecchie spariscono da
// sole. Se il segnaposto non viene sostituito il worker funziona comunque: la
// regola network-first garantisce l'aggiornamento anche a cache name invariato.
// ============================================================================

'use strict';

const VERSION = '__BUILD_NUMBER__';
const SHELL_CACHE = 'animerank-shell-' + VERSION;
const ASSETS_CACHE = 'animerank-assets-' + VERSION;

// file da tenere pronti per l'apertura offline.
const SHELL_ASSETS = [
  './',
  './index.html',
  './main.dart.js',
  './flutter_bootstrap.js',
  './flutter.js',
  './manifest.json',
  './version.json',
  './favicon.png',
  './icons/Icon-192.png',
  './icons/Icon-512.png',
  './icons/Icon-maskable-192.png',
  './icons/Icon-maskable-512.png',
  './icons/apple-touch-icon.png',
];

// ---------------------------------------------------------------------------
// Installazione: prepara la shell. Un file mancante non deve far fallire
// l'installazione (che altrimenti lascerebbe l'app senza service worker):
// si salta e si prosegue.
// ---------------------------------------------------------------------------
self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL_CACHE);
    await Promise.all(SHELL_ASSETS.map(async (url) => {
      try {
        await cache.add(new Request(url, { cache: 'reload' }));
      } catch (error) {
        console.warn('[sw] precache saltata:', url, error);
      }
    }));
  })());
});

// ---------------------------------------------------------------------------
// Attivazione: butta le cache delle versioni vecchie e prende il controllo
// delle pagine gia' aperte.
// ---------------------------------------------------------------------------
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys
        .filter((key) => key !== SHELL_CACHE && key !== ASSETS_CACHE)
        .map((key) => caches.delete(key)),
    );
    await self.clients.claim();
  })());
});

// ---------------------------------------------------------------------------
// Strategie
// ---------------------------------------------------------------------------

/** File che non cambiano mai fra una build e l'altra. */
function isImmutable(pathname) {
  if (/\.(json|bin)$/i.test(pathname)) return false; // manifest: cambiano
  return (
    pathname.includes('/canvaskit/') ||
    pathname.includes('/icons/') ||
    (pathname.includes('/assets/') && !/\.(json|bin)$/i.test(pathname)) ||
    /\.(png|jpe?g|gif|webp|svg|ico|woff2?|ttf|otf|wasm|symbols)$/i.test(pathname)
  );
}

async function cacheFirst(request, cacheName) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  if (cached) return cached;

  try {
    const response = await fetch(request);
    if (response && response.ok) cache.put(request, response.clone());
    return response;
  } catch (error) {
    return new Response('', { status: 504, statusText: 'Offline' });
  }
}

async function networkFirst(request, cacheName, fallbackUrl) {
  const cache = await caches.open(cacheName);
  try {
    const response = await fetch(request);
    if (response && response.ok) cache.put(request, response.clone());
    return response;
  } catch (error) {
    const cached = await cache.match(request);
    if (cached) return cached;
    if (fallbackUrl) {
      const fallback = await cache.match(fallbackUrl);
      if (fallback) return fallback;
    }
    return new Response('Offline', {
      status: 503,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  // Solo risorse del nostro sito: tutto il resto (Supabase, CDN esterne) va
  // dritto in rete, senza passare dalla cache.
  if (url.origin !== self.location.origin) return;

  // Apertura dell'app: network-first, con la shell in cache come rete di
  // sicurezza per l'uso offline.
  if (request.mode === 'navigate') {
    event.respondWith(networkFirst(request, SHELL_CACHE, './index.html'));
    return;
  }

  if (isImmutable(url.pathname)) {
    event.respondWith(cacheFirst(request, ASSETS_CACHE));
    return;
  }

  event.respondWith(networkFirst(request, SHELL_CACHE));
});

// ---------------------------------------------------------------------------
// Messaggi dalla pagina
// ---------------------------------------------------------------------------
self.addEventListener('message', (event) => {
  const data = event.data || {};

  // L'utente ha premuto "Aggiorna": il worker in attesa prende subito il posto
  // del vecchio. Il ricaricamento lo fa la pagina, su `controllerchange`.
  if (data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
