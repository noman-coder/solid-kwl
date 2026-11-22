"""Traffic Analytics: ek jagah par saara hisaab (dashboard, daily email aur export teeno yahin se).

Sirf padhta hai (read-only), sirf naye traffic tables + purane orders ko dekhta hai, kuch change nahi karta.
"""
import hashlib
import re
from collections import Counter
from datetime import datetime, time, timedelta
from itertools import combinations
from urllib.parse import quote, urlparse

from django.conf import settings
from django.db.models import Count, Max, Min, Q, Sum
from django.utils import timezone

from .models import (
    CompanyInfo, CustomerProfile, SaleOrder, SaleOrderItem, ShopBanner, ShopCartFollowup,
    ShopHiddenItem, ShopKeywordAction, ShopSearchLog, ShopTrafficEvent, ShopVisitor, VendorProfile,
)

SOURCE_LABELS = {
    'direct': 'Direct', 'facebook': 'Facebook', 'instagram': 'Instagram', 'whatsapp': 'WhatsApp',
    'google': 'Google', 'tiktok': 'TikTok', 'youtube': 'YouTube', 'other': 'Other',
}
UNKNOWN_AREA = 'Area select nahi ki'


def pct_change(cur, prev):
    if not prev:
        return None if not cur else 100.0
    return round((cur - prev) * 100.0 / prev, 1)


def day_bounds(start, end):
    tz = timezone.get_current_timezone()
    s = timezone.make_aware(datetime.combine(start, time.min), tz)
    e = timezone.make_aware(datetime.combine(end + timedelta(days=1), time.min), tz)
    return s, e


def _orders(start, end):
    """Shop (website) ke asli orders: SaleOrder jin ke notes mein "WEB ORDER" ho. Cancelled shamil nahi."""
    s_dt, e_dt = day_bounds(start, end)
    return SaleOrder.objects.filter(
        created_at__gte=s_dt, created_at__lt=e_dt, notes__contains='WEB ORDER').exclude(status='cancelled')


def kpi_counts(start, end):
    ev = ShopTrafficEvent.objects.filter(day__range=(start, end))
    pages = ev.filter(event_type='page')
    return {
        'views': pages.count(),
        'visitors': pages.values('session_key').distinct().count(),
        'product_views': ev.filter(event_type='product').count(),
        'cart_adds': ev.filter(event_type='cart_add').count(),
        'searches': ShopSearchLog.objects.filter(day__range=(start, end)).count(),
        'orders': _orders(start, end).count(),
    }


def _search_stats(a, b):
    return {r['keyword_norm']: r for r in ShopSearchLog.objects.filter(day__range=(a, b))
            .values('keyword_norm').annotate(
                n=Count('id'), zero=Count('id', filter=Q(results_count=0)),
                users=Count('session_key', distinct=True), shown=Max('keyword'), found=Max('results_count'))}


def collect(start, end, limit=20, with_contacts=False):
    """Dashboard / email / export ka poora data. limit=None => saari rows."""
    span = (end - start).days + 1
    prev_end = start - timedelta(days=1)
    prev_start = prev_end - timedelta(days=span - 1)
    cut = (lambda rows: rows[:limit]) if limit else (lambda rows: rows)

    cur, prev = kpi_counts(start, end), kpi_counts(prev_start, prev_end)
    kpis = []
    for key, label, icon in (
        ('views', 'Total Views', '👁️'), ('visitors', 'Unique Visitors', '🧑‍🤝‍🧑'),
        ('product_views', 'Product Views', '🛍️'), ('cart_adds', 'Add to Cart', '🛒'),
        ('searches', 'Searches', '🔎'), ('orders', 'Orders', '📦'),
    ):
        kpis.append({'key': key, 'label': label, 'icon': icon, 'value': cur[key],
                     'prev': prev[key], 'change': pct_change(cur[key], prev[key])})

    ev = ShopTrafficEvent.objects.filter(day__range=(start, end))
    pages = ev.filter(event_type='page')

    # ---- daily ----
    by_day = {r['day']: r for r in pages.values('day').annotate(
        v=Count('id'), u=Count('session_key', distinct=True))}
    daily = []
    for i in range(span):
        d = start + timedelta(days=i)
        daily.append({'day': d, 'views': by_day.get(d, {}).get('v', 0), 'visitors': by_day.get(d, {}).get('u', 0)})

    # ---- hours / devices / sources ----
    hours = {r['hour']: r['n'] for r in pages.values('hour').annotate(n=Count('id'))}
    hour_data = [hours.get(h, 0) for h in range(24)]
    peak_hour = max(range(24), key=lambda h: hour_data[h]) if any(hour_data) else None
    devices = [{'name': (r['device'] or 'unknown').title(), 'n': r['n']} for r in
               pages.values('device').annotate(n=Count('session_key', distinct=True)).order_by('-n')]
    sources = [{'name': SOURCE_LABELS.get(r['source'], (r['source'] or 'other').title()), 'n': r['n']} for r in
               pages.exclude(source='internal').values('source').annotate(
                   n=Count('session_key', distinct=True)).order_by('-n')]

    # ---- funnel (sessions) ----
    def _sess(qs):
        return qs.values('session_key').distinct().count()
    steps = [
        ('Visitors', cur['visitors']),
        ('Product dekha', _sess(ev.filter(event_type='product'))),
        ('Cart mein dala', _sess(ev.filter(event_type='cart_add'))),
        ('Cart page kholi', _sess(pages.filter(path='/shop/cart/'))),
        ('Checkout par aaye', _sess(pages.filter(path='/shop/checkout/'))),
        ('Order kiya', _sess(ev.filter(event_type='order'))),
    ]
    top_n = steps[0][1] or 0
    funnel, prev_n = [], None
    for label, n in steps:
        drop = None
        if prev_n:
            drop = max(round(100 - n * 100.0 / prev_n), 0)
        funnel.append({'label': label, 'n': n, 'pct': round(n * 100.0 / top_n) if top_n else 0, 'drop': drop})
        prev_n = n
    checkout = {
        'cart_page': steps[3][1], 'checkout': steps[4][1], 'ordered': steps[5][1],
        'cart_to_checkout_drop': funnel[4]['drop'], 'checkout_to_order_drop': funnel[5]['drop'],
    }
    checkout['hint'] = _checkout_hint(checkout)

    # ---- naye vs wapas aane wale visitors ----
    vids = pages.exclude(visitor_id='').values('visitor_id').distinct()
    total_v = ShopVisitor.objects.filter(visitor_id__in=vids).count()
    new_v = ShopVisitor.objects.filter(visitor_id__in=vids, first_seen__gte=start).count()
    visitor_mix = {
        'total': total_v, 'new': new_v, 'returning': total_v - new_v,
        'new_pct': round(new_v * 100.0 / total_v) if total_v else 0,
        'ret_pct': round((total_v - new_v) * 100.0 / total_v) if total_v else 0,
    }

    # ---- products: views -> cart -> orders ----
    s_dt, e_dt = day_bounds(start, end)
    prod_rows = {}
    for r in ev.exclude(event_type='page').exclude(product__isnull=True).values('product_id').annotate(
            name=Max('product_name'),
            views=Count('id', filter=Q(event_type='product')),
            viewers=Count('session_key', distinct=True, filter=Q(event_type='product')),
            carts=Count('id', filter=Q(event_type='cart_add'))):
        prod_rows[r['product_id']] = {
            'id': r['product_id'], 'name': r['name'] or f"#{r['product_id']}", 'views': r['views'],
            'viewers': r['viewers'], 'carts': r['carts'], 'orders': 0, 'qty': 0}
    ordered = SaleOrderItem.objects.filter(
        order__created_at__gte=s_dt, order__created_at__lt=e_dt, order__notes__contains='WEB ORDER') \
        .exclude(order__status='cancelled') \
        .values('product_id').annotate(name=Max('product__name'), o=Count('order', distinct=True), q=Sum('qty'))
    for r in ordered:
        row = prod_rows.setdefault(r['product_id'], {
            'id': r['product_id'], 'name': r['name'] or f"#{r['product_id']}", 'views': 0,
            'viewers': 0, 'carts': 0, 'orders': 0, 'qty': 0})
        row['orders'], row['qty'] = r['o'], int(r['q'] or 0)
    products = list(prod_rows.values())
    for p in products:
        p['conv'] = round(p['orders'] * 100.0 / p['views'], 1) if p['views'] else None
    all_viewed = sorted([p for p in products if p['views']], key=lambda p: (-p['views'], -p['orders']))
    viewed_not_bought = sorted([p for p in products if p['views'] >= 3 and p['orders'] == 0],
                               key=lambda p: -p['views'])
    viewed_not_bought = viewed_not_bought[:10] if limit else viewed_not_bought

    # ---- searches ----
    cur_s, prev_s = _search_stats(start, end), _search_stats(prev_start, prev_end)
    search_rows = sorted(cur_s.values(), key=lambda r: -r['n'])
    handled = {a.keyword_norm: a for a in ShopKeywordAction.objects.select_related('product')}
    not_found_all = sorted([r for r in search_rows if r['zero'] > 0 and r['keyword_norm'] not in handled],
                           key=lambda r: -r['zero'])
    handled_rows = [{'kw': r['shown'] or r['keyword_norm'], 'action': handled[r['keyword_norm']]}
                    for r in search_rows if r['zero'] > 0 and r['keyword_norm'] in handled]
    trending = []
    if span > 1:
        for k, r in cur_s.items():
            old = prev_s.get(k, {}).get('n', 0)
            if r['n'] - old >= 2:
                trending.append({'kw': r['shown'] or k, 'now': r['n'], 'before': old, 'new': old == 0})
        trending = sorted(trending, key=lambda t: -(t['now'] - t['before']))
        trending = trending[:10] if limit else trending

    # ---- area-wise ----
    areas = {}
    for r in ev.values('area').annotate(
            visitors=Count('session_key', distinct=True, filter=Q(event_type='page')),
            pviews=Count('id', filter=Q(event_type='product')),
            carts=Count('id', filter=Q(event_type='cart_add'))):
        name = (r['area'] or '').strip() or UNKNOWN_AREA
        key = name.lower()
        a = areas.setdefault(key, {'name': name, 'visitors': 0, 'product_views': 0, 'cart_adds': 0,
                                   'orders': 0, 'order_value': 0})
        a['visitors'] += r['visitors']
        a['product_views'] += r['pviews']
        a['cart_adds'] += r['carts']
    for r in ev.filter(event_type='order').values('area').annotate(n=Count('id'), v=Sum('amount')):
        name = (r['area'] or '').strip() or UNKNOWN_AREA
        a = areas.setdefault(name.lower(), {'name': name, 'visitors': 0, 'product_views': 0, 'cart_adds': 0,
                                            'orders': 0, 'order_value': 0})
        a['orders'] += r['n']
        a['order_value'] += float(r['v'] or 0)
    area_rows = sorted(areas.values(), key=lambda a: (a['name'] == UNKNOWN_AREA, -a['orders'], -a['visitors']))
    for a in area_rows:
        a['conv'] = round(a['orders'] * 100.0 / a['visitors'], 1) if a['visitors'] else None
        a['order_value'] = round(a['order_value'])

    return {
        'start': start, 'end': end, 'span': span,
        'kpis': kpis, 'cur': cur, 'prev': prev,
        'daily': daily, 'hour_data': hour_data, 'peak_hour': peak_hour,
        'devices': devices, 'sources': sources, 'funnel': funnel,
        'products': products, 'top_viewed': cut(all_viewed), 'all_viewed': all_viewed,
        'viewed_not_bought': viewed_not_bought,
        'search_rows': search_rows, 'top_searches': cut(search_rows),
        'not_found': cut(not_found_all), 'not_found_all': not_found_all,
        'handled_rows': handled_rows[:20] if limit else handled_rows,
        'trending': trending, 'areas': area_rows,
        'checkout': checkout, 'visitor_mix': visitor_mix,
        'abandoned': abandoned_carts(start, end, limit=limit or 500, with_contacts=with_contacts),
        'banners': banner_stats(ev, pages), 'stores': store_stats(ev, pages, start, end),
        'broken': broken_links(ev, limit), 'pairs': bought_pairs(),
    }



# ---------------------------------------------------------------------------
# Checkout hint, abandoned carts, banners, stores, broken links, bought-together pairs
# ---------------------------------------------------------------------------

def _checkout_hint(c):
    """Funnel ke numbers se seedhi salaah (Urdu)."""
    if c['cart_page'] < 5:
        return 'Abhi itna data nahi ke nateeja nikala ja sake. Kuch din aur dekhein.'
    d1, d2 = c['cart_to_checkout_drop'], c['checkout_to_order_drop']
    if d1 is not None and d1 >= 50 and (d2 is None or d1 >= d2):
        return ('Zyada log cart se checkout par nahi ja rahe: delivery charges, minimum order ya total price '
                'cart page par pehle hi saaf dikhayein.')
    if d2 is not None and d2 >= 50:
        return ('Zyada log checkout par aa kar order nahi kar rahe: form chhota karein, OTP/payment ke options '
                'aur delivery ka waqt saaf likhein.')
    return 'Checkout ka funnel theek chal raha hai.'


def _norm_phone(raw):
    d = re.sub(r'\D', '', raw or '')
    if d.startswith('00'):
        d = d[2:]
    if d.startswith('0'):
        d = '92' + d[1:]
    elif len(d) == 10 and d.startswith('3'):
        d = '92' + d
    return d if 11 <= len(d) <= 15 else ''


def cart_key(session_key):
    """Session key kabhi page par nahi dikhti: uska hash use hota hai."""
    return hashlib.sha256(f"{session_key}{settings.SECRET_KEY}".encode()).hexdigest()[:32]


def abandoned_carts(start, end, limit=30, with_contacts=False):
    """Cart mein maal daala, 1 ghante se zyada guzar gaya, order nahi hua."""
    now = timezone.now()
    ev = ShopTrafficEvent.objects.filter(day__range=(start, end), event_type='cart_add').exclude(session_key='')
    carts = list(ev.values('session_key').annotate(
        first=Min('created_at'), last=Max('created_at'), n=Count('id'), value=Sum('amount'),
        uid=Max('user_id'), ar=Max('area')).filter(last__lte=now - timedelta(minutes=60)).order_by('-last')[:600])
    if not carts:
        return []
    sessions = [c['session_key'] for c in carts]
    uids = [c['uid'] for c in carts if c['uid']]
    orders = ShopTrafficEvent.objects.filter(event_type='order')
    ordered_sess = {r['session_key']: r['last'] for r in orders.filter(session_key__in=sessions)
                    .values('session_key').annotate(last=Max('created_at'))}
    ordered_user = {r['user_id']: r['last'] for r in orders.filter(user_id__in=uids)
                    .values('user_id').annotate(last=Max('created_at'))} if uids else {}
    items = {}
    for r in ev.filter(session_key__in=sessions).values('session_key', 'product_name').annotate(q=Sum('quantity')):
        items.setdefault(r['session_key'], []).append(f"{r['product_name']} x{r['q']}")
    profiles = {}
    if with_contacts and uids:
        for pr in CustomerProfile.objects.filter(user_id__in=uids).select_related('customer'):
            profiles[pr.user_id] = pr.customer
    keys = {cart_key(sk): sk for sk in sessions}
    followed = {f.cart_key: f for f in ShopCartFollowup.objects.filter(cart_key__in=list(keys)).select_related('contacted_by')}
    company = CompanyInfo.objects.first()
    shop = company.name if company else 'hamari shop'

    rows = []
    for c in carts:
        sk = c['session_key']
        done = ordered_sess.get(sk)
        done_u = ordered_user.get(c['uid']) if c['uid'] else None
        if (done and done >= c['first']) or (done_u and done_u >= c['first']):
            continue                                            # order ho chuka
        key = cart_key(sk)
        cust = profiles.get(c['uid'])
        name = (cust.name if cust else '') or ''
        phone = _norm_phone(cust.contact_number) if cust else ''
        its = items.get(sk, [])
        items_text = ', '.join(its[:3]) + (f" +{len(its) - 3} aur" if len(its) > 3 else '')
        wa = ''
        if phone:
            msg = (f"Assalam o Alaikum {name or ''}! Aap ne {shop} se {items_text} cart mein dala tha. "
                   f"Agar order mukammal karna ho ya koi madad chahiye to bata dein, hum hazir hain.")
            wa = f"https://wa.me/{phone}?text={quote(msg)}"
        f = followed.get(key)
        rows.append({
            'key': key, 'name': name, 'phone': phone if with_contacts else '', 'wa_url': wa,
            'is_guest': not c['uid'], 'items': items_text, 'item_count': len(its),
            'value': round(float(c['value'] or 0)), 'last': timezone.localtime(c['last']),
            'mins_ago': int((now - c['last']).total_seconds() // 60), 'area': c['ar'] or '',
            'followed': bool(f), 'followed_by': (f.contacted_by.get_username() if f and f.contacted_by else ''),
            'followed_at': timezone.localtime(f.contacted_at) if f else None,
        })
        if len(rows) >= limit:
            break
    return rows


def banner_stats(ev, pages):
    clicks = {r['ref_id']: r for r in ev.filter(event_type='banner').values('ref_id').annotate(
        n=Count('id'), u=Count('session_key', distinct=True), lbl=Max('label'))}
    home_views = pages.filter(path='/shop/').count()
    objs = {b.id: b for b in ShopBanner.objects.filter(Q(id__in=list(clicks)) | Q(is_active=True))}
    rows = []
    for bid in set(objs) | set(clicks):
        c = clicks.get(bid, {})
        n = c.get('n', 0)
        rows.append({
            'id': bid, 'title': objs[bid].title if bid in objs else (c.get('lbl') or f'#{bid}'),
            'active': bool(objs[bid].is_active) if bid in objs else False,
            'clicks': n, 'people': c.get('u', 0),
            'ctr': round(n * 100.0 / home_views, 1) if home_views else None,
        })
    return {'rows': sorted(rows, key=lambda r: (-r['clicks'], r['title'])), 'home_views': home_views}


def store_stats(ev, pages, start, end):
    profiles = list(VendorProfile.objects.filter(is_approved=True).values('id', 'vendor_id', 'business_name'))
    if not profiles:
        return []
    by_pk, by_vendor = {}, {}
    for pr in profiles:
        row = {'name': pr['business_name'], 'page_views': 0, 'visitors': 0, 'product_views': 0, 'cart_adds': 0,
               'orders': 0, 'revenue': 0}
        by_pk[pr['id']] = row
        by_vendor[pr['vendor_id']] = row
    for r in pages.filter(path__startswith='/shop/stores/').values('path').annotate(
            n=Count('id'), u=Count('session_key', distinct=True)):
        m = re.match(r'^/shop/stores/(\d+)/?$', r['path'])
        if m and int(m.group(1)) in by_pk:
            by_pk[int(m.group(1))]['page_views'] += r['n']
            by_pk[int(m.group(1))]['visitors'] += r['u']
    for r in ev.filter(event_type__in=['product', 'cart_add'], product__vendor_id__isnull=False) \
            .values('product__vendor_id', 'event_type').annotate(n=Count('id')):
        row = by_vendor.get(r['product__vendor_id'])
        if row:
            row['product_views' if r['event_type'] == 'product' else 'cart_adds'] += r['n']
    for r in _orders(start, end).filter(vendor_id__isnull=False).values('vendor_id').annotate(
            n=Count('id', distinct=True), v=Sum('items__total_amt')):
        row = by_vendor.get(r['vendor_id'])
        if row:
            row['orders'], row['revenue'] = r['n'], round(float(r['v'] or 0))
    rows = [r for r in by_pk.values() if r['page_views'] or r['product_views'] or r['cart_adds'] or r['orders']]
    for r in rows:
        r['conv'] = round(r['orders'] * 100.0 / r['visitors'], 1) if r['visitors'] else None
    return sorted(rows, key=lambda r: (-r['orders'], -r['page_views'], -r['product_views']))


def broken_links(ev, limit):
    hidden = set(ShopHiddenItem.objects.filter(kind='404').values_list('key', flat=True))
    site = (getattr(settings, 'SITE_DOMAIN', '') or '').lower()
    rows = []
    for r in ev.filter(event_type='notfound').values('path').annotate(
            n=Count('id'), u=Count('session_key', distinct=True), last=Max('created_at'), ref=Max('label')).order_by('-n'):
        if r['path'] in hidden:
            continue
        ref = r['ref'] or ''
        host = urlparse(ref).netloc.lower() if ref else ''
        if not ref:
            ref_short = 'Seedha / bookmark'
        elif site and site in host:
            ref_short = 'Site ke andar se: ' + urlparse(ref).path[:60]
        else:
            ref_short = (host + urlparse(ref).path)[:70]
        rows.append({'path': r['path'], 'hits': r['n'], 'people': r['u'],
                     'last': timezone.localtime(r['last']), 'ref': ref_short})
    return rows[:limit] if limit else rows


def bought_pairs(days=90, top=10):
    """Aksar aik hi order mein khareedi jane wali jodiyan (pichle 90 din ke shop orders)."""
    since = timezone.now() - timedelta(days=days)
    per_order = {}
    rows = SaleOrderItem.objects.filter(order__created_at__gte=since, order__notes__contains='WEB ORDER') \
        .exclude(order__status='cancelled').values_list('order_id', 'product_id', 'product__name')[:40000]
    names = {}
    for oid, pid, name in rows:
        per_order.setdefault(oid, set()).add(pid)
        names[pid] = name
    pairs = Counter()
    for pids in per_order.values():
        if 2 <= len(pids) <= 12:
            for a, b in combinations(sorted(pids), 2):
                pairs[(a, b)] += 1
    return [{'a': names[a], 'b': names[b], 'count': n} for (a, b), n in pairs.most_common(top) if n >= 2]


# ---------------------------------------------------------------------------
# Export (Excel / CSV)
# ---------------------------------------------------------------------------

CSV_TABLES = ('daily', 'products', 'searches', 'notfound', 'areas', 'abandoned', 'stores', 'banners', 'broken')


def _safe(v):
    """Customer ka likha text Excel/CSV mein formula ban kar na chale (=, +, -, @ se shuru ho to)."""
    if isinstance(v, str) and v[:1] in ('=', '+', '-', '@', '\t', '\r'):
        return "'" + v
    return v


def table_rows(name, d):
    """(header, rows) for one export table (text cells formula-safe)."""
    header, rows = _table_rows(name, d)
    return header, [[_safe(c) for c in r] for r in rows]


def _table_rows(name, d):
    if name == 'daily':
        return (['Date', 'Views', 'Visitors'],
                [[r['day'].isoformat(), r['views'], r['visitors']] for r in d['daily']])
    if name == 'products':
        return (['Product', 'Views', 'Visitors', 'Add to cart', 'Orders', 'Qty ordered', 'Conversion %'],
                [[p['name'], p['views'], p['viewers'], p['carts'], p['orders'], p['qty'],
                  p['conv'] if p['conv'] is not None else ''] for p in d['all_viewed']])
    if name == 'searches':
        return (['Keyword', 'Searches', 'Visitors', 'Results found', 'Zero-result searches'],
                [[r['shown'] or r['keyword_norm'], r['n'], r['users'], r['found'], r['zero']]
                 for r in d['search_rows']])
    if name == 'notfound':
        return (['Keyword', 'Times searched with 0 results', 'Visitors'],
                [[r['shown'] or r['keyword_norm'], r['zero'], r['users']] for r in d['not_found_all']])
    if name == 'areas':
        return (['Area', 'Visitors', 'Product views', 'Add to cart', 'Orders', 'Order value (Rs)', 'Conversion %'],
                [[a['name'], a['visitors'], a['product_views'], a['cart_adds'], a['orders'], a['order_value'],
                  a['conv'] if a['conv'] is not None else ''] for a in d['areas']])
    if name == 'abandoned':
        return (['Customer', 'Phone', 'Items', 'Value (Rs)', 'Last cart', 'Area', 'Follow-up'],
                [[a['name'] or 'Guest', a['phone'], a['items'], a['value'], a['last'].strftime('%Y-%m-%d %H:%M'),
                  a['area'], 'Done' if a['followed'] else ''] for a in d['abandoned']])
    if name == 'stores':
        return (['Store', 'Page views', 'Visitors', 'Product views', 'Add to cart', 'Orders', 'Revenue (Rs)', 'Conversion %'],
                [[r['name'], r['page_views'], r['visitors'], r['product_views'], r['cart_adds'], r['orders'],
                  r['revenue'], r['conv'] if r['conv'] is not None else ''] for r in d['stores']])
    if name == 'banners':
        return (['Banner', 'Clicks', 'People', 'CTR % (home views)', 'Active'],
                [[r['title'], r['clicks'], r['people'], r['ctr'] if r['ctr'] is not None else '',
                  'Yes' if r['active'] else 'No'] for r in d['banners']['rows']])
    if name == 'broken':
        return (['Page (404)', 'Hits', 'People', 'Last seen', 'Came from'],
                [[r['path'], r['hits'], r['people'], r['last'].strftime('%Y-%m-%d %H:%M'), r['ref']] for r in d['broken']])
    raise ValueError(name)


def build_xlsx(d):
    from io import BytesIO

    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill
    from openpyxl.utils import get_column_letter

    wb = Workbook()
    ws = wb.active
    ws.title = 'Summary'
    ws.append(['Shop Traffic Report'])
    ws.append([f"{d['start']:%d %b %Y} - {d['end']:%d %b %Y}"])
    ws.append([])
    ws.append(['Metric', 'This period', 'Previous period', 'Change %'])
    for k in d['kpis']:
        ws.append([k['label'], k['value'], k['prev'], k['change'] if k['change'] is not None else ''])
    ws['A1'].font = Font(bold=True, size=14)
    sheets = (('Daily', 'daily'), ('Products', 'products'), ('Searches', 'searches'),
              ('Not Found', 'notfound'), ('Areas', 'areas'), ('Abandoned Carts', 'abandoned'),
              ('Stores', 'stores'), ('Banners', 'banners'), ('Broken Links', 'broken'))
    head_fill = PatternFill('solid', fgColor='4F46E5')
    for title, key in sheets:
        header, rows = table_rows(key, d)
        sh = wb.create_sheet(title)
        sh.append(header)
        for r in rows:
            sh.append(r)
        for c in sh[1]:
            c.font = Font(bold=True, color='FFFFFF')
            c.fill = head_fill
        sh.freeze_panes = 'A2'
        for i in range(1, len(header) + 1):
            width = max(len(str(c.value or '')) for c in sh[get_column_letter(i)][:200])
            sh.column_dimensions[get_column_letter(i)].width = min(max(width + 2, 12), 50)
    for c in ws[4]:
        c.font = Font(bold=True, color='FFFFFF')
        c.fill = head_fill
    ws.column_dimensions['A'].width = 24
    for col in 'BCD':
        ws.column_dimensions[col].width = 16
    buf = BytesIO()
    wb.save(buf)
    return buf.getvalue()
