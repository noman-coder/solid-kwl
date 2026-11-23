// Service worker (PWA ke liye).  v4
// - Navigation (page) requests: network-first. Pehli nakami par FORAN offline page nahi dikhate:
//   chand baar retry karte hain (mobile data / tunnel / server restart ke chhote hiccups chhup jate hain).
// - Sirf tab offline page dikhate hain jab retries bhi fail hon. Page khud bhi auto-retry karta hai.
// - Tesseract (OCR) files: cache-first (offline chalti hain).
// - Baqi sab seedha network par, isliye purana data stale nahi hota.
var TESS_CACHE = 'tesseract-v1';

// Navigation retry: pehli koshish + 3 retries (0.6s, 1.5s, 3s)
var RETRY_DELAYS = [600, 1500, 3000];
// Proxy/tunnel ke "server abhi available nahi" statuses (Cloudflare 52x / 530 bhi)
var GATEWAY_STATUS = { 502: 1, 503: 1, 504: 1, 520: 1, 521: 1, 522: 1, 523: 1, 524: 1, 530: 1 };

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

// kind: 'offline' (network error) ya 'server' (tunnel/server restart ho raha hai)
var OFFLINE_HTML = function (kind) {
  var title = kind === 'server' ? 'Server abhi tayyar nahi' : 'Connection nahi ban raha';
  var msg = kind === 'server'
    ? 'Server update ya restart ho raha hai. Page khud dobara koshish kar raha hai, thora intezar karein.'
    : 'Internet slow ya beech mein toot raha hai. Page khud dobara koshish kar raha hai.';
  return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>Offline</title><style>body{font-family:system-ui,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;' +
    'margin:0;background:#f6f8fb;color:#1f2937;text-align:center;padding:20px}button{margin-top:14px;padding:10px 20px;border:0;border-radius:10px;' +
    'background:#1e3a8a;color:#fff;font-size:1rem}small{display:block;margin-top:12px;color:#6b7280}</style></head><body><div>' +
    '<h2>' + title + '</h2><p>' + msg + '</p>' +
    '<button onclick="location.reload()">Retry</button><small id="s"></small></div>' +
    '<script>(function(){var n=0,max=12,t=5;var s=document.getElementById("s");' +
    'function go(){location.reload();}' +
    'window.addEventListener("online",go);' +
    'function tick(){if(n>=max){s.textContent="";return;}' +
    's.textContent="Auto retry "+t+"s mein...";t--;' +
    'if(t<0){n++;go();return;}setTimeout(tick,1000);}tick();})();</scr' + 'ipt></body></html>';
};

function htmlResponse(kind) {
  return new Response(OFFLINE_HTML(kind), {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }
  });
}

function sleep(ms) {
  return new Promise(function (resolve) { setTimeout(resolve, ms); });
}

// Network error ya gateway status par retry; kamyabi par asal response wapas.
function navigateWithRetry(req) {
  var attempt = 0;
  function run() {
    return fetch(req).then(function (res) {
      if (GATEWAY_STATUS[res.status] && attempt < RETRY_DELAYS.length) {
        return sleep(RETRY_DELAYS[attempt++]).then(run);
      }
      if (GATEWAY_STATUS[res.status]) return htmlResponse('server');
      return res;
    }, function () {
      if (attempt < RETRY_DELAYS.length) {
        return sleep(RETRY_DELAYS[attempt++]).then(run);
      }
      return htmlResponse('offline');
    });
  }
  return run();
}

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

  // Page navigations: network-first, retry, phir offline fallback
  if (req.mode === 'navigate') {
    event.respondWith(navigateWithRetry(req));
  }
});
