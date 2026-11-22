"""Shop traffic tracking helpers (Traffic Analytics).

Har function try/except mein hai: tracking fail ho to shop ka koi page ya order kabhi nahi rukta.
Sirf naye tables mein likhta hai, kisi purane data ko touch nahi karta.
"""
import logging
import re
from urllib.parse import urlparse

from django.core.cache import cache
from django.utils import timezone

logger = logging.getLogger(__name__)

BOT_RE = re.compile(
    r'bot|crawl|spider|slurp|facebookexternalhit|preview|monitor|uptime|curl|wget|python-requests|headless',
    re.I)
MOBILE_RE = re.compile(r'android|iphone|ipad|ipod|mobile|opera mini', re.I)

SOURCES = (
    ('facebook', ('facebook.', 'fb.', 'fbclid', 'm.facebook')),
    ('instagram', ('instagram.',)),
    ('whatsapp', ('whatsapp', 'wa.me')),
    ('google', ('google.',)),
    ('tiktok', ('tiktok.',)),
    ('youtube', ('youtube.', 'youtu.be')),
)


def is_bot(request):
    ua = request.META.get('HTTP_USER_AGENT', '')
    return (not ua) or bool(BOT_RE.search(ua))


def _device(request):
    return 'mobile' if MOBILE_RE.search(request.META.get('HTTP_USER_AGENT', '')) else 'desktop'


def _is_staff(request):
    user = getattr(request, 'user', None)
    return bool(user is not None and user.is_authenticated and (user.is_staff or user.is_superuser))


def _source(request):
    """Where the visitor came from (only meaningful on the first page of a visit)."""
    utm = (request.GET.get('utm_source') or '').lower()
    ref = request.META.get('HTTP_REFERER', '')
    text = utm
    if ref:
        host = urlparse(ref).netloc.lower()
        if host and host == request.get_host().lower():
            return 'internal'
        text = f"{utm} {host}"
    if request.GET.get('fbclid'):
        text += ' fbclid'
    if not text.strip():
        return 'direct'
    for name, keys in SOURCES:
        if any(k in text for k in keys):
            return name
    return 'other'


def _session_key(request):
    if not request.session.session_key:
        request.session.create()
    return request.session.session_key or ''


def _once(key, seconds):
    try:
        return cache.add(key, 1, seconds)
    except Exception:
        return True


def _local_now():
    n = timezone.localtime(timezone.now())
    return n.date(), n.hour


def normalize_keyword(text):
    return re.sub(r'\s+', ' ', (text or '').strip().lower())[:100]


def log_page(request):
    try:
        if is_bot(request) or _is_staff(request):
            return
        sk = _session_key(request)
        path = request.path[:255]
        if not _once(f"trf_pg:{sk}:{path}", 20):      # refresh / double-load = 1 view
            return
        from .models import ShopTrafficEvent
        day, hour = _local_now()
        ShopTrafficEvent.objects.create(
            event_type='page', day=day, hour=hour, session_key=sk, path=path,
            device=_device(request), source=_source(request))
    except Exception:
        logger.exception("Traffic page tracking failed")


def log_product_view(request, product):
    try:
        if is_bot(request) or _is_staff(request):
            return
        sk = _session_key(request)
        if not _once(f"trf_pv:{sk}:{product.id}", 600):   # same product again within 10 min = 1 view
            return
        from .models import ShopTrafficEvent
        day, hour = _local_now()
        ShopTrafficEvent.objects.create(
            event_type='product', day=day, hour=hour, session_key=sk, product=product,
            product_name=(product.name or '')[:200], path=request.path[:255], device=_device(request))
    except Exception:
        logger.exception("Traffic product tracking failed")


def log_cart_add(request, product, quantity=1):
    try:
        if is_bot(request) or _is_staff(request):
            return
        sk = _session_key(request)
        from .models import ShopTrafficEvent
        day, hour = _local_now()
        ShopTrafficEvent.objects.create(
            event_type='cart_add', day=day, hour=hour, session_key=sk, product=product,
            product_name=(product.name or '')[:200], quantity=max(int(quantity or 1), 1),
            path=request.path[:255], device=_device(request))
    except Exception:
        logger.exception("Traffic cart tracking failed")


def log_search(request, keyword, results_count, corrected_to=''):
    """Every keyword is saved, even when no product matches (results_count = 0)."""
    try:
        norm = normalize_keyword(keyword)
        if not norm or is_bot(request) or _is_staff(request):
            return
        sk = _session_key(request)
        if not _once(f"trf_sr:{sk}:{norm}", 30):
            return
        from .models import ShopSearchLog
        day, hour = _local_now()
        ShopSearchLog.objects.create(
            keyword=(keyword or '').strip()[:100], keyword_norm=norm,
            results_count=int(results_count or 0), corrected_to=(corrected_to or '')[:100],
            day=day, hour=hour, session_key=sk, device=_device(request))
    except Exception:
        logger.exception("Traffic search tracking failed")


# ---------------------------------------------------------------------------
# 90-din retention: purana raw data pehle daily summary mein save, phir raw hataya.
# Summary (ShopTrafficDaily) kabhi delete nahi hoti.
# ---------------------------------------------------------------------------

def rollup_old_traffic(keep_days=90, max_days=10, dry_run=False):
    """Returns list of (day, raw_events, raw_searches) processed."""
    from datetime import timedelta

    from django.db import transaction
    from django.db.models import Count, Max, Q

    from .models import ShopSearchLog, ShopTrafficDaily, ShopTrafficEvent

    cutoff = timezone.localtime(timezone.now()).date() - timedelta(days=keep_days)
    days = set(ShopTrafficEvent.objects.filter(day__lt=cutoff).values_list('day', flat=True).distinct())
    days |= set(ShopSearchLog.objects.filter(day__lt=cutoff).values_list('day', flat=True).distinct())
    done = []
    for day in sorted(days)[:max_days]:
        ev = ShopTrafficEvent.objects.filter(day=day)
        sr = ShopSearchLog.objects.filter(day=day)
        n_ev, n_sr = ev.count(), sr.count()
        if dry_run:
            done.append((day, n_ev, n_sr))
            continue
        with transaction.atomic():
            ShopTrafficDaily.objects.filter(day=day).delete()      # only rebuilds this same day's summary
            pages = ev.filter(event_type='page')
            ShopTrafficDaily.objects.create(
                day=day, kind='site', label='all',
                views=pages.count(),
                visitors=pages.values('session_key').distinct().count(),
                cart_adds=ev.filter(event_type='cart_add').count(),
                searches=n_sr, zero_results=sr.filter(results_count=0).count())
            rows = []
            for r in ev.exclude(event_type='page').values('product_id').annotate(
                    name=Max('product_name'),
                    views=Count('id', filter=Q(event_type='product')),
                    visitors=Count('session_key', distinct=True, filter=Q(event_type='product')),
                    carts=Count('id', filter=Q(event_type='cart_add'))):
                rows.append(ShopTrafficDaily(
                    day=day, kind='product', label=(r['name'] or '')[:200], product_id=r['product_id'],
                    views=r['views'], visitors=r['visitors'], cart_adds=r['carts']))
            for r in sr.values('keyword_norm').annotate(
                    n=Count('id'), zero=Count('id', filter=Q(results_count=0)),
                    users=Count('session_key', distinct=True)):
                rows.append(ShopTrafficDaily(
                    day=day, kind='search', label=r['keyword_norm'][:200],
                    searches=r['n'], zero_results=r['zero'], visitors=r['users']))
            ShopTrafficDaily.objects.bulk_create(rows, batch_size=500)
            ev.delete()
            sr.delete()
        done.append((day, n_ev, n_sr))
    return done
