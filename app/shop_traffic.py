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


VID_COOKIE = 'kc_vid'


def _visitor(request):
    """Browser ki pehchan (1 saal ki cookie). Nayi ho to middleware cookie laga deta hai."""
    vid = (request.COOKIES.get(VID_COOKIE) or '').strip()
    if len(vid) == 36:
        return vid
    vid = getattr(request, '_kc_vid', '') or ''
    if not vid:
        import uuid
        vid = str(uuid.uuid4())
        request._kc_vid = vid
        request._kc_vid_set = True
    return vid


def _user_id(request):
    user = getattr(request, 'user', None)
    if user is not None and user.is_authenticated and not (user.is_staff or user.is_superuser):
        return user.id
    return None


def _touch_visitor(vid, day):
    """ShopVisitor: naya hai to banao, purana ho to din mein sirf aik baar last_seen/visits update."""
    if not _once(f"trf_vd:{vid}:{day}", 86400):
        return
    from django.db.models import F

    from .models import ShopVisitor
    obj, created = ShopVisitor.objects.get_or_create(
        visitor_id=vid, defaults={'first_seen': day, 'last_seen': day, 'visits': 1})
    if not created and obj.last_seen != day:
        ShopVisitor.objects.filter(pk=obj.pk).update(last_seen=day, visits=F('visits') + 1)


def _area(request):
    """Customer ka "Deliver to" shehar/area (session ya login customer ka address). Na mile to ''."""
    try:
        from .customer.views_customer_portal import get_delivery_area
        return (get_delivery_area(request) or '')[:100]
    except Exception:
        return ''


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
            device=_device(request), source=_source(request), area=_area(request),
            visitor_id=_visitor(request), user_id=_user_id(request))
        _touch_visitor(_visitor(request), day)
        maybe_send_daily_summary()
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
            product_name=(product.name or '')[:200], path=request.path[:255], device=_device(request),
            area=_area(request), visitor_id=_visitor(request), user_id=_user_id(request))
    except Exception:
        logger.exception("Traffic product tracking failed")


def log_cart_add(request, product, quantity=1, unit_price=None):
    try:
        if is_bot(request) or _is_staff(request):
            return
        sk = _session_key(request)
        from .models import ShopTrafficEvent
        qty = max(int(quantity or 1), 1)
        try:
            amount = float(unit_price) * qty if unit_price is not None else 0
        except (TypeError, ValueError):
            amount = 0
        day, hour = _local_now()
        ShopTrafficEvent.objects.create(
            event_type='cart_add', day=day, hour=hour, session_key=sk, product=product,
            product_name=(product.name or '')[:200], quantity=qty, amount=amount,
            path=request.path[:255], device=_device(request), area=_area(request),
            visitor_id=_visitor(request), user_id=_user_id(request))
    except Exception:
        logger.exception("Traffic cart tracking failed")


def log_order(request, order):
    """Order ban gaya (cart -> order funnel + abandoned-cart ke liye). Aik order aik hi baar."""
    try:
        if is_bot(request):
            return
        from .models import ShopTrafficEvent
        if ShopTrafficEvent.objects.filter(event_type='order', ref_id=order.id).exists():
            return
        try:
            amount = sum(float(i.total_amt) for i in order.items.all()) + float(order.delivery_fee or 0)
        except Exception:
            amount = 0
        day, hour = _local_now()
        ShopTrafficEvent.objects.create(
            event_type='order', day=day, hour=hour, session_key=_session_key(request), ref_id=order.id,
            amount=amount, label=(order.order_no or '')[:255], device=_device(request),
            area=_area(request), visitor_id=_visitor(request), user_id=getattr(request.user, 'id', None))
    except Exception:
        logger.exception("Traffic order tracking failed")


def log_banner_click(request, banner):
    try:
        if is_bot(request) or _is_staff(request):
            return
        from .models import ShopTrafficEvent
        day, hour = _local_now()
        ShopTrafficEvent.objects.create(
            event_type='banner', day=day, hour=hour, session_key=_session_key(request), ref_id=banner.id,
            label=(banner.title or '')[:255], device=_device(request), area=_area(request),
            visitor_id=_visitor(request), user_id=_user_id(request))
    except Exception:
        logger.exception("Traffic banner tracking failed")


NOT_FOUND_SKIP = re.compile(
    r'^/(static|media|admin|favicon|robots|apple-touch|\.well-known)|\.(php|asp|aspx|env|git|sql|bak|zip|xml|txt|map|ico|png|jpe?g|gif|webp|svg|css|js)$|wp-|xmlrpc|phpmyadmin|cgi-bin',
    re.I)


def log_404(request):
    """Customer ko jo page nahi mila (sirf asli visitors; scanner/bot aur image/css wale 404 nahi)."""
    try:
        path = request.path
        if NOT_FOUND_SKIP.search(path) or is_bot(request) or _is_staff(request):
            return
        sk = _session_key(request)
        if not _once(f"trf_404:{sk}:{path}", 60):
            return
        from .models import ShopTrafficEvent
        ref = request.META.get('HTTP_REFERER', '')[:255]
        day, hour = _local_now()
        ShopTrafficEvent.objects.create(
            event_type='notfound', day=day, hour=hour, session_key=sk, path=path[:255], label=ref,
            device=_device(request), source=_source(request), visitor_id=_visitor(request))
    except Exception:
        logger.exception("Traffic 404 tracking failed")


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
            for r in ev.filter(event_type__in=['product', 'cart_add']).exclude(product__isnull=True).values('product_id').annotate(
                    name=Max('product_name'),
                    views=Count('id', filter=Q(event_type='product')),
                    visitors=Count('session_key', distinct=True, filter=Q(event_type='product')),
                    carts=Count('id', filter=Q(event_type='cart_add'))):
                rows.append(ShopTrafficDaily(
                    day=day, kind='product', label=(r['name'] or '')[:200], product_id=r['product_id'],
                    views=r['views'], visitors=r['visitors'], cart_adds=r['carts']))
            for r in ev.values('area').annotate(
                    v=Count('id', filter=Q(event_type='product')),
                    u=Count('session_key', distinct=True, filter=Q(event_type='page')),
                    c=Count('id', filter=Q(event_type='cart_add'))):
                rows.append(ShopTrafficDaily(
                    day=day, kind='area', label=((r['area'] or '').strip() or 'unknown')[:200],
                    views=r['v'], visitors=r['u'], cart_adds=r['c']))
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


# ---------------------------------------------------------------------------
# Daily summary email (receiver: secret SUMMERY_REC -> settings.TRAFFIC_SUMMARY_RECIPIENTS)
# ---------------------------------------------------------------------------

SUMMARY_HOUR = 8          # raat ke baad, subah 8 baje ke baad pehle visitor par kal ki summary jati hai


def summary_recipients():
    from django.conf import settings
    return [e for e in (getattr(settings, 'TRAFFIC_SUMMARY_RECIPIENTS', None) or []) if '@' in e]


def build_summary_email(day):
    """(subject, text, html) for one day."""
    from html import escape

    from .traffic_reports import collect
    d = collect(day, day, limit=5)
    title = f"Shop Traffic Summary: {day:%d %b %Y}"

    def arrow(c):
        return '' if c is None else (f" (▲{c}%)" if c > 0 else (f" (▼{abs(c)}%)" if c < 0 else ''))

    lines = [title, '']
    for k in d['kpis']:
        lines.append(f"{k['label']}: {k['value']}{arrow(k['change'])}")
    sections = [
        ('Top products', [f"{p['name']}: {p['views']} views, {p['carts']} cart, {p['orders']} orders" for p in d['top_viewed']]),
        ('Top searches', [f"{r['shown'] or r['keyword_norm']}: {r['n']}" for r in d['top_searches']]),
        ('Not found (customers maang rahe, shop mein nahi)', [f"{r['shown'] or r['keyword_norm']}: {r['zero']}" for r in d['not_found']]),
        ('Top areas', [f"{a['name']}: {a['visitors']} visitors, {a['orders']} orders" for a in d['areas'][:5]]),
        ('Abandoned carts (cart mein dala, order nahi hua)',
         ([f"{len(d['abandoned'])} carts, Rs. {sum(a['value'] for a in d['abandoned'])} ka maal"] +
          [f"{a['items']} (Rs. {a['value']})" for a in d['abandoned'][:3]]) if d['abandoned'] else []),
        ('Naye vs wapas aane wale',
         [f"Naye: {d['visitor_mix']['new']}, wapas aaye: {d['visitor_mix']['returning']}"] if d['visitor_mix']['total'] else []),
        ('Broken links (404)', [f"{r['path']}: {r['hits']} baar" for r in d['broken'][:3]]),
    ]
    for head, items in sections:
        lines += ['', head + ':'] + (['  ' + i for i in items] or ['  -'])
    text = '\n'.join(lines)

    kp = ''.join(
        f"<td style='padding:10px 12px;text-align:center'><div style='font-size:22px;font-weight:800'>{k['value']}</div>"
        f"<div style='font-size:11px;color:#6b7280;text-transform:uppercase'>{escape(k['label'])}</div>"
        f"<div style='font-size:11px;color:{'#16a34a' if (k['change'] or 0) >= 0 else '#dc2626'}'>{escape(arrow(k['change']))}</div></td>"
        for k in d['kpis'])
    blocks = ''
    for head, items in sections:
        li = ''.join(f"<li style='margin:2px 0'>{escape(i)}</li>" for i in items) or "<li style='color:#9ca3af'>-</li>"
        blocks += f"<h3 style='font-size:14px;margin:18px 0 6px'>{escape(head)}</h3><ul style='margin:0;padding-left:18px;font-size:13px'>{li}</ul>"
    html = (
        "<div style='font-family:Arial,sans-serif;max-width:640px;margin:auto;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden'>"
        f"<div style='background:#4f46e5;color:#fff;padding:16px 20px'><div style='font-size:18px;font-weight:800'>📈 {escape(title)}</div></div>"
        f"<div style='padding:16px 20px'><table style='width:100%;border-collapse:collapse;background:#f9fafb'>"
        f"<tr>{kp}</tr></table>{blocks}"
        "<p style='font-size:11px;color:#9ca3af;margin-top:20px'>Admin → People → Traffic Analytics mein poori detail.</p></div></div>")
    return title, text, html


def send_daily_summary(day, to=None):
    """Email bhejo. Returns True agar bhej di gayi."""
    from django.conf import settings
    from django.core.mail import EmailMultiAlternatives

    to = to or summary_recipients()
    if not to:
        return False
    subject, text, html = build_summary_email(day)
    msg = EmailMultiAlternatives(f"📈 {subject}", text, getattr(settings, 'DEFAULT_FROM_EMAIL', None), to)
    msg.attach_alternative(html, 'text/html')
    msg.send(fail_silently=False)
    return True


def maybe_send_daily_summary():
    """Subah SUMMARY_HOUR ke baad din mein sirf aik baar kal ki summary bhejta hai (visitor ki request se
    shuru, background thread mein). DB marker (ShopTrafficMailLog) se email dobara nahi jati."""
    import threading
    from datetime import timedelta

    from django.db import IntegrityError, connections

    try:
        if not summary_recipients():
            return
        local = timezone.localtime(timezone.now())
        if local.hour < SUMMARY_HOUR:
            return
        if not _once('trf_mail_check', 600):              # database ko baar baar na chhere
            return
        yesterday = local.date() - timedelta(days=1)
        from .models import ShopTrafficMailLog
        if ShopTrafficMailLog.objects.filter(day=yesterday).exists():
            return
        try:
            claim = ShopTrafficMailLog.objects.create(day=yesterday, recipients=','.join(summary_recipients())[:500])
        except IntegrityError:                            # kisi aur worker ne pehle claim kar liya
            return

        def _run():
            try:
                if not send_daily_summary(yesterday):
                    claim.delete()
            except Exception:
                logger.exception("Daily traffic summary email failed")
                try:
                    claim.delete()                        # agle chance par dobara koshish
                    cache.set('trf_mail_check', 1, 1800)  # 30 min ruk kar
                except Exception:
                    pass
            finally:
                connections.close_all()                   # is thread ka apna DB connection band

        threading.Thread(target=_run, daemon=True).start()
    except Exception:
        logger.exception("Daily traffic summary check failed")
