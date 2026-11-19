// Service worker (PWA ke liye).
// - Navigation (page) requests: network-first, internet na ho to chhota offline page.
// - Tesseract (OCR) files: cache-first (offline chalti hain).
// - Baqi sab seedha network par, isliye purana data stale nahi hota.
var TESS_CACHE = 'tesseract-v1';

self.addEventListener('install', function (event) {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.filter(function (k) {
        return k.indexOf('tesseract-') === 0 && k !== TESS_CACHE;
      }).map(function (k) { return caches.delete(k); }));
    }).then(function () { return self.clients.claim(); })
  );
});

var OFFLINE_HTML = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
  '<title>Offline</title><style>body{font-family:system-ui,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;' +
  'margin:0;background:#f6f8fb;color:#1f2937;text-align:center;padding:20px}button{margin-top:14px;padding:10px 20px;border:0;border-radius:10px;' +
  'background:#1e3a8a;color:#fff;font-size:1rem}</style></head><body><div><h2>Internet nahi hai</h2><p>Connection check karein aur dobara koshish karein.</p>' +
  '<button onclick="location.reload()">Retry</button></div></body></html>';

self.addEventListener('fetch', function (event) {
  var req = event.request;
  if (req.method !== 'GET') return;
  var url = new URL(req.url);

  // OCR files: cache-first
  if (url.origin === self.location.origin && url.pathname.indexOf('/tesseract/') !== -1) {
    event.respondWith(
      caches.open(TESS_CACHE).then(function (cache) {
        return cache.match(req).then(function (hit) {
          if (hit) return hit;
          return fetch(req).then(function (res) {
            if (res && res.ok) cache.put(req, res.clone());
            return res;
          });
        });
      })
    );
    return;
  }

  // Page navigations: network-first, offline fallback
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).catch(function () {
        return new Response(OFFLINE_HTML, { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
      })
    );
  }
});
