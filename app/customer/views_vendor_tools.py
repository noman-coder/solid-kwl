"""
Vendor Tools
============
Vendor ke liye 3 naye kaam (koi purana view/model nahi badla, koi migration nahi):

- vendor_analytics         : bikri ka hisaab (aaj / 7 / 30 / 90 din), top products, kam stock
- vendor_analytics_export  : usi hisaab ki CSV file
- vendor_quick_update      : tamam products ki price / discount / stock ek hi page par

Hisaab SaleOrder (is vendor ke) aur SaleOrderItem se banta hai. Cancelled order shamil nahi.
"Aap ka hissa" andaza hai: sales x (100 - commission%) / 100. Asal payable dashboard par
(batch cost se) dikhta hai.
"""
import csv
import logging
from datetime import datetime, time as dtime, timedelta
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

from django.contrib import messages
from django.core.exceptions import ValidationError
from django.db import transaction
from django.db.models import Count, Sum
from django.db.models.functions import TruncDate
from django.http import HttpResponse
from django.shortcuts import redirect, render
from django.utils import timezone

from ..decorators import vendor_login_required
from ..models import Inventory, Product, SaleOrder, SaleOrderItem
from ..vendor_commission import commission_percent, reprice_open_batches, vendor_share
from .views_vendor_portal import (
    MAX_PRICE, _add_stock, _company_name, _stock_warehouse,
)

logger = logging.getLogger(__name__)

CENT = Decimal('0.01')
RANGES = {'today': ('Aaj', 1), '7': ('7 din', 7), '30': ('30 din', 30), '90': ('90 din', 90)}
DONE_STATUSES = ['delivered', 'invoiced']
OPEN_STATUSES = ['pending', 'confirmed', 'processing', 'ready', 'partially_delivered']
LOW_STOCK_DEFAULT = 10


def _money(value):
    return Decimal(value or 0).quantize(CENT, ROUND_HALF_UP)


def _period(request):
    key = request.GET.get('range', '7')
    if key not in RANGES:
        key = '7'
    days = RANGES[key][1]
    today = timezone.localdate()
    start_date = today - timedelta(days=days - 1)
    start = timezone.make_aware(datetime.combine(start_date, dtime.min))
    return key, days, start_date, today, start


def _analytics_data(vendor, profile, start_date, today, start):
    orders = SaleOrder.objects.filter(vendor=vendor, order_date__gte=start)
    live_orders = orders.exclude(status='cancelled')
    items = SaleOrderItem.objects.filter(order__in=live_orders)

    total_orders = orders.count()
    cancelled = orders.filter(status='cancelled').count()
    done = orders.filter(status__in=DONE_STATUSES).count()
    open_orders = orders.filter(status__in=OPEN_STATUSES).count()

    sales = _money(items.aggregate(s=Sum('total_amt'))['s'])
    units = items.aggregate(u=Sum('qty'))['u'] or 0
    live_count = total_orders - cancelled
    avg_order = _money(sales / live_count) if live_count else Decimal('0.00')
    pct = commission_percent(profile)
    est_share = _money(sales * (Decimal('100') - pct) / Decimal('100'))
    cancel_rate = round(cancelled * 100 / total_orders, 1) if total_orders else 0

    # din ba din bikri (khali din 0 ke sath, taake chart barabar rahe)
    per_day = {
        row['d']: row for row in
        items.annotate(d=TruncDate('order__order_date'))
        .values('d').annotate(total=Sum('total_amt'), n=Count('order', distinct=True))
    }
    days = []
    cursor = start_date
    while cursor <= today:
        row = per_day.get(cursor)
        days.append({'date': cursor, 'total': _money(row['total']) if row else Decimal('0.00'),
                     'orders': row['n'] if row else 0})
        cursor += timedelta(days=1)
    peak = max((d['total'] for d in days), default=Decimal('0')) or Decimal('1')
    for d in days:
        d['pct'] = int(d['total'] * 100 / peak) if d['total'] else 0

    top = list(
        items.values('product_id', 'product__name')
        .annotate(qty=Sum('qty'), total=Sum('total_amt'))
        .order_by('-total')[:10]
    )
    top_peak = max((_money(t['total']) for t in top), default=Decimal('1')) or Decimal('1')
    for t in top:
        t['total'] = _money(t['total'])
        t['pct'] = int(t['total'] * 100 / top_peak)

    return {
        'total_orders': total_orders, 'done': done, 'open_orders': open_orders,
        'cancelled': cancelled, 'cancel_rate': cancel_rate,
        'sales': sales, 'units': units, 'avg_order': avg_order,
        'est_share': est_share, 'commission': pct,
        'days': days, 'top': top,
    }


def _stock_rows(vendor, warehouse):
    stock = {}
    if warehouse:
        stock = {r['product_id']: r['stock'] for r in
                 Inventory.objects.filter(product__vendor=vendor, warehouse=warehouse)
                 .values('product_id', 'stock')}
    rows = []
    for p in Product.objects.filter(vendor=vendor).select_related('unit').order_by('name'):
        qty = stock.get(p.id, 0) or 0
        rows.append({'product': p, 'stock': qty,
                     'low': p.approval_status == 'approved' and qty <= (p.low_stock_threshold or LOW_STOCK_DEFAULT)})
    return rows


@vendor_login_required
def vendor_analytics(request):
    profile = request.user.vendor_profile
    vendor = profile.vendor
    key, days, start_date, today, start = _period(request)
    data = _analytics_data(vendor, profile, start_date, today, start)

    low_stock = [r for r in _stock_rows(vendor, _stock_warehouse()) if r['low']]
    low_stock.sort(key=lambda r: r['stock'])

    return render(request, 'customer_portal/vendor/analytics.html', {
        'page_title': 'Sales Analytics',
        'profile': profile,
        'range_key': key,
        'ranges': [(k, v[0]) for k, v in RANGES.items()],
        'range_label': RANGES[key][0],
        'start_date': start_date, 'today': today,
        'data': data,
        'low_stock': low_stock[:10],
        'low_stock_count': len(low_stock),
        'company_name': _company_name(),
    })


def _csv_safe(value):
    """Excel formula injection se bachao: = + - @ se shuru hone wali text ke aage ' lagao."""
    text = '' if value is None else str(value)
    return "'" + text if text[:1] in ('=', '+', '-', '@') else text


@vendor_login_required
def vendor_analytics_export(request):
    profile = request.user.vendor_profile
    vendor = profile.vendor
    key, days, start_date, today, start = _period(request)

    resp = HttpResponse(content_type='text/csv; charset=utf-8')
    resp['Content-Disposition'] = f'attachment; filename="sales_{start_date}_{today}.csv"'
    resp.write('\ufeff')  # Excel mein Urdu/UTF-8 theek khule
    w = csv.writer(resp)
    w.writerow(['Order No', 'Date', 'Customer', 'Status', 'Items', 'Total (Rs.)'])

    qs = (SaleOrder.objects.filter(vendor=vendor, order_date__gte=start)
          .select_related('customer').prefetch_related('items')
          .order_by('-order_date'))
    for o in qs:
        items = list(o.items.all())
        total = sum((i.total_amt for i in items), Decimal('0'))
        w.writerow([
            _csv_safe(o.order_no),
            timezone.localtime(o.order_date).strftime('%Y-%m-%d %H:%M'),
            _csv_safe(o.customer.name),
            o.get_status_display(),
            len(items),
            f'{total:.2f}',
        ])
    return resp


# ============================================
# QUICK PRICE / STOCK UPDATE
# ============================================

def _dec(raw, lo, hi, label, errors, name):
    try:
        d = Decimal((raw or '').strip())
        if d < lo or d > hi:
            raise InvalidOperation
        return d
    except InvalidOperation:
        errors.append(f'{name}: {label} sahi likhein')
        return None


@vendor_login_required
def vendor_quick_update(request):
    profile = request.user.vendor_profile
    vendor = profile.vendor

    if not profile.is_approved:
        messages.warning(request, '⏳ Aap ka account abhi approve nahi hua.')
        return redirect('vendor_dashboard')

    warehouse = _stock_warehouse()

    if request.method == 'POST':
        return _quick_update_save(request, profile, vendor, warehouse)

    rows = _stock_rows(vendor, warehouse)
    q = request.GET.get('q', '').strip()[:50]
    if q:
        rows = [r for r in rows if q.lower() in r['product'].name.lower()]
    if request.GET.get('low'):
        rows = [r for r in rows if r['low']]

    return render(request, 'customer_portal/vendor/quick_update.html', {
        'page_title': 'Quick Update',
        'profile': profile,
        'rows': rows,
        'q': q,
        'only_low': bool(request.GET.get('low')),
        'commission': commission_percent(profile),
        'company_name': _company_name(),
    })


def quick_update_product(product, price_raw, discount_raw, add_raw, pct, vendor, warehouse):
    """Ek product ki price / discount / naya stock (web quick-update aur vendor app API ki SHARED logic).

    Return: (status, errors)  status: 'changed' | 'same' | 'error'.
    Validation, batch repricing aur stock add bilkul wahi hai jo web page mein tha.
    Paisa/stock ka kaam transaction.atomic + select_for_update mein hota hai (double tap/do phone safe).
    """
    name = product.name
    row_errors = []
    price = _dec(price_raw, Decimal('0.01'), MAX_PRICE, 'price', row_errors, name)
    discount = _dec(discount_raw or '0', Decimal('0'), Decimal('90'), 'discount (0-90)', row_errors, name)
    add = _dec(add_raw or '0', Decimal('0'), Decimal('1000000'), 'naya stock', row_errors, name)
    if row_errors:
        return 'error', row_errors

    price = price.quantize(CENT)
    add_qty = float(add)
    try:
        with transaction.atomic():
            product = Product.objects.select_for_update().get(pk=product.pk, vendor=vendor)
            same = (price == product.original_price and discount == (product.discount_percentage or 0)
                    and add_qty <= 0)
            if same:
                return 'same', []
            product.original_price = price
            product.price = price
            product.discount_percentage = discount
            product._image_processed = True      # image dobara process na ho
            product.save()
            reprice_open_batches(product, price, discount, pct)
            if add_qty > 0:
                if not warehouse:
                    raise ValidationError('Shop mein warehouse set nahi hai')
                _add_stock(product, warehouse, add_qty, vendor_share(price, discount, pct), price)
        return 'changed', []
    except ValidationError as exc:
        try:
            return 'error', [f'{name}: ' + '; '.join(exc.messages)]
        except Exception:
            return 'error', [f'{name}: update nahi ho saka']
    except Exception:
        logger.exception('Vendor quick update error (product %s)', product.pk)
        return 'error', [f'{name}: update nahi ho saka']


def _quick_update_save(request, profile, vendor, warehouse):
    post = request.POST
    pct = commission_percent(profile)
    ids = []
    for raw in post.getlist('ids'):
        try:
            ids.append(int(raw))
        except (TypeError, ValueError):
            continue
    products = {p.id: p for p in Product.objects.filter(vendor=vendor, pk__in=ids)}

    changed, errors = 0, []
    for pid in ids:
        product = products.get(pid)            # sirf apna product; baaqi chupchap chhor do
        if not product:
            continue
        status, row_errors = quick_update_product(
            product, post.get(f'price_{pid}'), post.get(f'discount_{pid}') or '0',
            post.get(f'add_{pid}') or '0', pct, vendor, warehouse)
        if status == 'error':
            errors.extend(row_errors)
        elif status == 'changed':
            changed += 1

    for e in errors[:10]:
        messages.error(request, f'❌ {e}')
    if changed:
        messages.success(request, f'✅ {changed} product update ho gaye.')
    elif not errors:
        messages.info(request, 'Koi tabdeeli nahi mili.')
    return redirect('vendor_quick_update')
