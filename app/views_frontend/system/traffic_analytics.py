"""Frontend views: system/traffic_analytics

Admin "Traffic Analytics" dashboard (shop): views, visitors, product views, searches, area-wise traffic,
cart/order conversion, "Not Found" keyword actions, Excel/CSV export, daily summary email.

Dashboard sirf padhta hai. Data badalne wale sirf 2 kaam hain (alias lagana / ignore karna) aur wo bhi
sirf naye ShopKeywordAction table aur ProductAlias mein ENTRY ADD karte hain: kuch delete nahi hota.
Permissions: dekhna = view_analytics, alias/ignore = manage_products.
"""
import csv
import json
from datetime import timedelta

from django.contrib.auth.decorators import login_required
from django.core.cache import cache
from django.db.models import Q
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_POST

from ...models import (
    CompanyInfo, LiveVisitor, Product, ProductAlias, ShopKeywordAction, ShopSearchLog, ShopTrafficEvent,
)
from ...security.permissions import perm_required
from ...shop_traffic import (
    normalize_keyword, rollup_old_traffic, send_daily_summary, summary_recipients,
)
from ...traffic_reports import CSV_TABLES, build_xlsx, collect, table_rows

PERIODS = {1: 'Aaj', 7: '7 din', 30: '30 din', 90: '90 din'}


def _period(request):
    try:
        days = int(request.GET.get('days', 1))
    except (TypeError, ValueError):
        days = 1
    if days not in PERIODS:
        days = 1
    today = timezone.localtime(timezone.now()).date()
    return days, today - timedelta(days=days - 1), today


@login_required
@perm_required('view_analytics')
def traffic_analytics(request):
    try:                                        # once a day: 90+ din purana raw data -> summary
        if cache.add('traffic_rollup_done', 1, 86400):
            rollup_old_traffic(keep_days=90, max_days=10)
    except Exception:
        pass

    days, start, today = _period(request)
    d = collect(start, today, limit=20)

    try:
        live_now = LiveVisitor.get_active_count(seconds=60)
    except Exception:
        live_now = 0
    company = CompanyInfo.objects.first()
    first_day = ShopTrafficEvent.objects.order_by('day').values_list('day', flat=True).first()
    user = request.user
    from ...security.permissions import has_matrix_perm
    try:
        can_manage = has_matrix_perm(user, 'manage_products')
    except Exception:
        can_manage = bool(user.is_superuser)

    return render(request, 'system/traffic_analytics.html', {
        'company_name': company.name if company else 'ERP System',
        'days': days, 'periods': PERIODS, 'start': start, 'end': today,
        'kpis': d['kpis'], 'live_now': live_now,
        'chart_labels': [r['day'].strftime('%d %b') for r in d['daily']],
        'chart_views': [r['views'] for r in d['daily']],
        'chart_visitors': [r['visitors'] for r in d['daily']],
        'hour_data': d['hour_data'], 'peak_hour': d['peak_hour'],
        'devices': d['devices'], 'sources': d['sources'], 'funnel': d['funnel'],
        'top_viewed': d['top_viewed'], 'viewed_not_bought': d['viewed_not_bought'],
        'top_searches': d['top_searches'], 'not_found': d['not_found'],
        'handled_rows': d['handled_rows'], 'trending': d['trending'], 'areas': d['areas'],
        'tracking_since': first_day, 'can_manage': can_manage,
        'csv_tables': CSV_TABLES, 'mail_configured': bool(summary_recipients()),
    })


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

@login_required
@perm_required('view_analytics')
def traffic_export(request):
    days, start, today = _period(request)
    d = collect(start, today, limit=None)
    stamp = f"{start:%Y%m%d}-{today:%Y%m%d}"
    if request.GET.get('format') == 'csv':
        table = request.GET.get('table', 'products')
        if table not in CSV_TABLES:
            table = 'products'
        header, rows = table_rows(table, d)
        resp = HttpResponse(content_type='text/csv; charset=utf-8')
        resp['Content-Disposition'] = f'attachment; filename="traffic-{table}-{stamp}.csv"'
        resp.write('\ufeff')                       # Excel mein Urdu/Unicode sahi khule
        w = csv.writer(resp)
        w.writerow(header)
        w.writerows(rows)
        return resp
    resp = HttpResponse(
        build_xlsx(d), content_type='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
    resp['Content-Disposition'] = f'attachment; filename="traffic-report-{stamp}.xlsx"'
    return resp


# ---------------------------------------------------------------------------
# "Not Found" keyword actions
# ---------------------------------------------------------------------------

@login_required
@perm_required('manage_products')
def traffic_product_search(request):
    q = (request.GET.get('q') or '').strip()[:100]
    if len(q) < 2:
        return JsonResponse({'results': []})
    qs = Product.objects.filter(is_active=True).filter(
        Q(name__icontains=q) | Q(serial_no__icontains=q) | Q(barcode__icontains=q))[:10]
    return JsonResponse({'results': [
        {'id': p.id, 'name': p.name, 'sku': p.serial_no or p.barcode or ''} for p in qs]})


@login_required
@perm_required('manage_products')
@require_POST
def traffic_keyword_action(request):
    try:
        data = json.loads(request.body or '{}')
    except ValueError:
        data = {}
    kw = normalize_keyword(data.get('keyword'))
    action = data.get('action')
    if not kw or action not in ('alias', 'ignore'):
        return JsonResponse({'success': False, 'message': 'Invalid request'}, status=400)
    if not ShopSearchLog.objects.filter(keyword_norm=kw).exists():
        return JsonResponse({'success': False, 'message': 'Ye keyword search log mein nahi mila'}, status=404)

    if action == 'ignore':
        ShopKeywordAction.objects.update_or_create(
            keyword_norm=kw, defaults={'action': ShopKeywordAction.IGNORED, 'product': None,
                                       'created_by': request.user})
        return JsonResponse({'success': True, 'message': f'"{kw}" ignore list mein chala gaya'})

    try:
        product = Product.objects.get(pk=int(data.get('product_id')), is_active=True)
    except (TypeError, ValueError, Product.DoesNotExist):
        return JsonResponse({'success': False, 'message': 'Product chunein'}, status=400)
    if not ProductAlias.objects.filter(product=product, alias__iexact=kw).exists():
        ProductAlias.objects.create(product=product, alias=kw[:100], created_by=request.user)
    ShopKeywordAction.objects.update_or_create(
        keyword_norm=kw, defaults={'action': ShopKeywordAction.ALIAS, 'product': product,
                                   'created_by': request.user})
    return JsonResponse({'success': True, 'message': f'"{kw}" ab "{product.name}" se judd gaya. '
                                                     f'Shop mein ye search ab is product ko dikhayegi.'})


# ---------------------------------------------------------------------------
# Daily summary email: manual "bhejo" button
# ---------------------------------------------------------------------------

@login_required
@perm_required('view_analytics')
@require_POST
def traffic_send_summary(request):
    to = summary_recipients()
    if not to:
        return JsonResponse({'success': False, 'message': 'SUMMERY_REC secret set nahi hai.'}, status=400)
    yesterday = timezone.localtime(timezone.now()).date() - timedelta(days=1)
    try:
        send_daily_summary(yesterday, to=to)
    except Exception as exc:
        return JsonResponse({'success': False, 'message': f'Email nahi gayi: {exc}'}, status=500)
    return JsonResponse({'success': True, 'message': f'Kal ki summary {len(to)} address par bhej di gayi.'})
