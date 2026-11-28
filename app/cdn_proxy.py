"""Same-origin proxy for the few CDN files the shop pages need (Bootstrap, Bootstrap Icons).

Why: kuch ISPs / networks par cdn.jsdelivr.net band ya bohat slow hota hai. Bootstrap CSS render-blocking hai,
is liye page khali / loading hi rehta tha (VPN lagane par chalta tha). Ab browser ye files hamare apne domain
(/static/cdn/...) se leta hai; server (jahan internet khula hai) jsdelivr se ek baar laa kar disk par cache kar leta hai.

Sirf neeche likhi hui files allowed hain (open proxy nahi).
"""
import hashlib
import logging
import os
import re
import threading
import urllib.request

from django.conf import settings
from django.http import Http404, HttpResponse

log = logging.getLogger(__name__)

UPSTREAM = 'https://cdn.jsdelivr.net/npm/'
ALLOWED = re.compile(r'^(?:bootstrap@5\.3\.0|bootstrap-icons@1\.11\.0)/[A-Za-z0-9._/-]+\.(css|js|woff2?)$')
TYPES = {
    'css': 'text/css; charset=utf-8',
    'js': 'application/javascript; charset=utf-8',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
}
MAX_BYTES = 3 * 1024 * 1024
_lock = threading.Lock()


def _cache_dir():
    d = os.path.join(str(settings.BASE_DIR), 'django_cache', 'cdn_assets')
    os.makedirs(d, exist_ok=True)
    return d


def _fetch(rel):
    req = urllib.request.Request(UPSTREAM + rel, headers={'User-Agent': 'Mozilla/5.0 (cdn-cache)'})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES or not data:
        raise ValueError('bad size')
    return data


def cdn_asset(request, asset):
    if '..' in asset or not ALLOWED.match(asset):
        raise Http404()
    ext = asset.rsplit('.', 1)[1]
    fp = os.path.join(_cache_dir(), hashlib.sha1(asset.encode()).hexdigest() + '.' + ext)
    data = None
    if os.path.exists(fp):
        with open(fp, 'rb') as f:
            data = f.read()
    else:
        with _lock:
            if os.path.exists(fp):
                with open(fp, 'rb') as f:
                    data = f.read()
            else:
                try:
                    data = _fetch(asset)
                except Exception as exc:  # network / upstream problem: page ka onerror fallback original CDN lega
                    log.warning('cdn_asset fetch failed for %s: %s', asset, exc)
                    return HttpResponse('upstream unavailable', status=502, content_type='text/plain')
                tmp = fp + '.tmp'
                with open(tmp, 'wb') as f:
                    f.write(data)
                os.replace(tmp, fp)
    resp = HttpResponse(data, content_type=TYPES[ext])
    resp['Cache-Control'] = 'public, max-age=31536000, immutable'
    return resp
