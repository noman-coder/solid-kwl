"""Traffic Analytics: ek jagah par saara hisaab (dashboard, daily email aur export teeno yahin se).

Sirf padhta hai (read-only), sirf naye traffic tables + purane orders ko dekhta hai, kuch change nahi karta.
"""
from datetime import datetime, time, timedelta

from django.db.models import Count, Max, Q, Sum
from django.utils import timezone

from .models import (
    CustomerOrder, CustomerOrderItem, ShopKeywordAction, ShopSearchLog, ShopTrafficEvent,
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
    s_dt, e_dt = day_bounds(start, end)
    return CustomerOrder.objects.filter(created_at__gte=s_dt, created_at__lt=e_dt).exclude(status='cancelled')


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


def collect(start, end, limit=20):
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

    # ---- funnel ----
    funnel = [
        ('Visitors', cur['visitors']),
        ('Product dekha', ev.filter(event_type='product').values('session_key').distinct().count()),
        ('Cart mein dala', ev.filter(event_type='cart_add').values('session_key').distinct().count()),
        ('Order kiya', cur['orders']),
    ]
    top_n = funnel[0][1] or 0
    funnel = [{'label': l, 'n': n, 'pct': round(n * 100.0 / top_n) if top_n else 0} for l, n in funnel]

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
    ordered = CustomerOrderItem.objects.filter(
        order__created_at__gte=s_dt, order__created_at__lt=e_dt).exclude(order__status='cancelled') \
        .values('product_id').annotate(name=Max('product_name'), o=Count('order', distinct=True),
                                       q=Sum('quantity'))
    for r in ordered:
        row = prod_rows.setdefault(r['product_id'], {
            'id': r['product_id'], 'name': r['name'] or f"#{r['product_id']}", 'views': 0,
            'viewers': 0, 'carts': 0, 'orders': 0, 'qty': 0})
        row['orders'], row['qty'] = r['o'], r['q'] or 0
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
    for r in _orders(start, end).values('shipping_city').annotate(n=Count('id'), v=Sum('total_amount')):
        name = ' '.join((r['shipping_city'] or '').split()).title() or UNKNOWN_AREA
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
    }


# ---------------------------------------------------------------------------
# Export (Excel / CSV)
# ---------------------------------------------------------------------------

CSV_TABLES = ('daily', 'products', 'searches', 'notfound', 'areas')


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
              ('Not Found', 'notfound'), ('Areas', 'areas'))
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
