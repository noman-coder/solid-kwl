"""Frontend views: system/traffic_analytics

Admin "Traffic Analytics" dashboard (shop): views, visitors, product views, searches,
cart/order conversion. Sirf padhta hai (read-only), koi data change nahi karta.
Permission: view_analytics.
"""
from datetime import datetime, time, timedelta

from django.contrib.auth.decorators import login_required
from django.core.cache import cache
from django.db.models import Count, Max, Q, Sum
from django.shortcuts import render
from django.utils import timezone

from ...models import (
    CompanyInfo, CustomerOrder, CustomerOrderItem, LiveVisitor, ShopSearchLog, ShopTrafficEvent,
)
from ...security.permissions import perm_required
from ...shop_traffic import rollup_old_traffic

PERIODS = {1: 'Aaj', 7: '7 din', 30: '30 din', 90: '90 din'}
SOURCE_LABELS = {
    'direct': 'Direct', 'facebook': 'Facebook', 'instagram': 'Instagram', 'whatsapp': 'WhatsApp',
    'google': 'Google', 'tiktok': 'TikTok', 'youtube': 'YouTube', 'other': 'Other',
}


def _pct_change(cur, prev):
    if not prev:
        return None if not cur else 100.0
    return round((cur - prev) * 100.0 / prev, 1)


def _bounds(start, end):
    tz = timezone.get_current_timezone()
    s = timezone.make_aware(datetime.combine(start, time.min), tz)
    e = timezone.make_aware(datetime.combine(end + timedelta(days=1), time.min), tz)
    return s, e


def _kpis(start, end):
    ev = ShopTrafficEvent.objects.filter(day__range=(start, end))
    pages = ev.filter(event_type='page')
    s_dt, e_dt = _bounds(start, end)
    orders = CustomerOrder.objects.filter(created_at__gte=s_dt, created_at__lt=e_dt).exclude(status='cancelled')
    return {
        'views': pages.count(),
        'visitors': pages.values('session_key').distinct().count(),
        'product_views': ev.filter(event_type='product').count(),
        'cart_adds': ev.filter(event_type='cart_add').count(),
        'searches': ShopSearchLog.objects.filter(day__range=(start, end)).count(),
        'orders': orders.count(),
    }


@login_required
@perm_required('view_analytics')
def traffic_analytics(request):
    try:                                        # once a day: 90+ din purana raw data -> summary
        if cache.add('traffic_rollup_done', 1, 86400):
            rollup_old_traffic(keep_days=90, max_days=10)
    except Exception:
        pass

    try:
        days = int(request.GET.get('days', 1))
    except (TypeError, ValueError):
        days = 1
    if days not in PERIODS:
        days = 1

    today = timezone.localtime(timezone.now()).date()
    start = today - timedelta(days=days - 1)
    prev_end = start - timedelta(days=1)
    prev_start = prev_end - timedelta(days=days - 1)

    cur, prev = _kpis(start, today), _kpis(prev_start, prev_end)
    kpis = []
    for key, label, icon in (
        ('views', 'Total Views', '👁️'), ('visitors', 'Unique Visitors', '🧑‍🤝‍🧑'),
        ('product_views', 'Product Views', '🛍️'), ('cart_adds', 'Add to Cart', '🛒'),
        ('searches', 'Searches', '🔎'), ('orders', 'Orders', '📦'),
    ):
        kpis.append({'label': label, 'icon': icon, 'value': cur[key], 'change': _pct_change(cur[key], prev[key])})

    ev = ShopTrafficEvent.objects.filter(day__range=(start, today))
    pages = ev.filter(event_type='page')

    # ---- daily chart ----
    by_day = {r['day']: r for r in pages.values('day').annotate(
        v=Count('id'), u=Count('session_key', distinct=True))}
    chart_labels, chart_views, chart_visitors = [], [], []
    for i in range(days):
        d = start + timedelta(days=i)
        chart_labels.append(d.strftime('%d %b'))
        chart_views.append(by_day.get(d, {}).get('v', 0))
        chart_visitors.append(by_day.get(d, {}).get('u', 0))

    # ---- peak hours ----
    hours = {r['hour']: r['n'] for r in pages.values('hour').annotate(n=Count('id'))}
    hour_data = [hours.get(h, 0) for h in range(24)]
    peak_hour = max(range(24), key=lambda h: hour_data[h]) if any(hour_data) else None

    # ---- devices & sources (distinct visitors) ----
    devices = [{'name': (r['device'] or 'unknown').title(), 'n': r['n']} for r in
               pages.values('device').annotate(n=Count('session_key', distinct=True)).order_by('-n')]
    sources = [{'name': SOURCE_LABELS.get(r['source'], r['source'].title()), 'n': r['n']} for r in
               pages.exclude(source='internal').values('source').annotate(
                   n=Count('session_key', distinct=True)).order_by('-n')]

    # ---- funnel (visitors -> viewed a product -> added to cart -> ordered) ----
    funnel = [
        ('Visitors', cur['visitors']),
        ('Product dekha', ev.filter(event_type='product').values('session_key').distinct().count()),
        ('Cart mein dala', ev.filter(event_type='cart_add').values('session_key').distinct().count()),
        ('Order kiya', cur['orders']),
    ]
    top_n = funnel[0][1] or 0
    funnel = [{'label': l, 'n': n, 'pct': round(n * 100.0 / top_n) if top_n else 0} for l, n in funnel]

    # ---- products: views -> cart -> orders ----
    s_dt, e_dt = _bounds(start, today)
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
    top_viewed = sorted(products, key=lambda p: (-p['views'], -p['orders']))[:20]
    top_viewed = [p for p in top_viewed if p['views']]
    viewed_not_bought = sorted([p for p in products if p['views'] >= 3 and p['orders'] == 0],
                               key=lambda p: -p['views'])[:10]

    # ---- searches ----
    def _search_stats(a, b):
        return {r['keyword_norm']: r for r in ShopSearchLog.objects.filter(day__range=(a, b))
                .values('keyword_norm').annotate(
                    n=Count('id'), zero=Count('id', filter=Q(results_count=0)),
                    users=Count('session_key', distinct=True), shown=Max('keyword'), found=Max('results_count'))}

    cur_s, prev_s = _search_stats(start, today), _search_stats(prev_start, prev_end)
    search_rows = sorted(cur_s.values(), key=lambda r: -r['n'])
    top_searches = search_rows[:20]
    not_found = sorted([r for r in search_rows if r['zero'] > 0], key=lambda r: -r['zero'])[:20]
    trending = []
    if days > 1:
        for k, r in cur_s.items():
            old = prev_s.get(k, {}).get('n', 0)
            if r['n'] - old >= 2:
                trending.append({'kw': r['shown'] or k, 'now': r['n'], 'before': old, 'new': old == 0})
        trending = sorted(trending, key=lambda t: -(t['now'] - t['before']))[:10]

    company = CompanyInfo.objects.first()
    try:
        live_now = LiveVisitor.get_active_count(seconds=60)
    except Exception:
        live_now = 0
    first_day = ShopTrafficEvent.objects.order_by('day').values_list('day', flat=True).first()

    return render(request, 'system/traffic_analytics.html', {
        'company_name': company.name if company else 'ERP System',
        'days': days, 'periods': PERIODS, 'start': start, 'end': today,
        'kpis': kpis, 'live_now': live_now,
        'chart_labels': chart_labels, 'chart_views': chart_views, 'chart_visitors': chart_visitors,
        'hour_data': hour_data, 'peak_hour': peak_hour,
        'devices': devices, 'sources': sources, 'funnel': funnel,
        'top_viewed': top_viewed, 'viewed_not_bought': viewed_not_bought,
        'top_searches': top_searches, 'not_found': not_found, 'trending': trending,
        'tracking_since': first_day,
    })
