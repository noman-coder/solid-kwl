"""
Vendor Android app ke liye JSON API (token login).

Phase V1: foundation - login / logout / me. Baqi saari vendor API isi file ke helpers par khadi hongi.
Phase V2: push-token (FCM token register/refresh) aur logout par token hatana.
Phase V4: dashboard (aaj/hafta/mahina sale, orders, earnings, stock, 7-din chart, warnings) + store Open/Closed switch.
Phase V5: orders tab - list (Naye / Chal rahe / Mukammal + search + page), action (accept/reject/ready/delivered), poll.
Phase V6: order detail (items + images, customer, payment, status steps, rider, commission), live track (rider ki location),
          assign-rider (list + assign).
Phase V8: products tab - list (search/filter/page), toggle (shop par show/hide), quick-update (rate/discount/naya stock).
Logic wahi hai jo views_vendor_portal.vendor_login ka hai (phone + password, lockout), bas JSON mein.
Token Django ke signing se banta hai (salt 'vendor-api-v1', 30 din; vendor ka password badalne par
purane token khud band ho jate hain).

Header:  Authorization: Bearer <token>
Error format hamesha:  {ok: false, error: '...', code: '...'}   (message == error, app ki asani ke liye)

Usool:
- Har API sirf us vendor ka data de (profile.vendor). Doosre vendor ka order/product kabhi nahi
  (`owned_order_or_404` jaise helpers neeche hain, aglay phases inhi ko use karein).
- Unapproved vendor sirf login + status (me) dekh sakta hai. Baqi sab API `@vendor_api([...])` se
  approved vendor ke liye hain (approval_required=True default).
"""
import json
import logging
from datetime import datetime, time as dtime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from functools import wraps

from django.contrib.auth import authenticate
from django.core import signing
from django.core.exceptions import ObjectDoesNotExist
from django.core.cache import cache
from django.db import transaction
from django.db.models import Case, Count, F, FloatField, OuterRef, Q, Subquery, Sum, Value, When
from django.db.models.functions import Coalesce
from django.http import JsonResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.utils.timezone import now
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from ..models import (DeliveryInfo, Inventory, OrderTracking, Product, RiderCashHandover, RiderProfile, SaleOrder,
                      VendorProfile, VendorPushToken)
from ..vendor_commission import CENT, HUNDRED, commission_percent, vendor_earnings
from . import store_orders
from .views_customer_auth import get_client_ip, normalize_phone
from .views_reviews import vendor_rating
from .views_vendor_portal import (
    LOGIN_LOCK_SECONDS, LOGIN_MAX_ATTEMPTS, ORDER_TABS, _login_key, _stock_warehouse,
)
from .views_vendor_tools import LOW_STOCK_DEFAULT, _analytics_data, _stock_rows, quick_update_product

logger = logging.getLogger(__name__)

TOKEN_SALT = 'vendor-api-v1'
TOKEN_MAX_AGE = 30 * 24 * 3600

PENDING_MSG = 'Aap ke account ki approval baqi hai. Admin approve kar de to dobara try karein.'


# ---------------------------------------------------------------- helpers

def _data(request):
    """JSON body ya form dono chalte hain."""
    ctype = request.META.get('CONTENT_TYPE', '')
    if 'application/json' in ctype:
        try:
            d = json.loads(request.body.decode('utf-8') or '{}')
            return d if isinstance(d, dict) else {}
        except (ValueError, UnicodeDecodeError):
            return {}
    return request.POST


def _err(msg, status=400, code='error'):
    return JsonResponse({'ok': False, 'error': msg, 'message': msg, 'code': code}, status=status)


def _make_token(profile):
    return signing.dumps({'vid': profile.pk, 'pv': (profile.user.password or '')[-12:]}, salt=TOKEN_SALT)


def _profile_from_request(request):
    """Bearer token se VendorProfile; ghalat/expire/purana token ya staff user ho to None."""
    auth = request.META.get('HTTP_AUTHORIZATION', '')
    if not auth.lower().startswith('bearer '):
        return None
    try:
        payload = signing.loads(auth[7:].strip(), salt=TOKEN_SALT, max_age=TOKEN_MAX_AGE)
    except signing.BadSignature:
        return None
    profile = (VendorProfile.objects.select_related('user', 'vendor')
               .filter(pk=payload.get('vid')).first())
    if not profile or not profile.user or not profile.user.is_active:
        return None
    if profile.user.is_staff or profile.user.is_superuser:
        return None
    if (profile.user.password or '')[-12:] != payload.get('pv'):
        return None          # password badal gaya -> purane token band
    return profile


def vendor_api(methods, approval_required=True):
    """csrf_exempt + method check + token check (+ approval check).

    View ko (request, profile, ...) milta hai; vendor = profile.vendor.
    approval_required=False sirf login ke baad 'status dekhne' wali API (me, logout) ke liye.
    """
    def deco(view):
        @csrf_exempt
        @require_http_methods(methods)
        @wraps(view)
        def wrapper(request, *args, **kwargs):
            profile = _profile_from_request(request)
            if profile is None:
                return _err('Dobara login karein', 401, code='auth')
            if approval_required and not profile.is_approved:
                return _err(PENDING_MSG, 403, code='pending')
            return view(request, profile, *args, **kwargs)
        return wrapper
    return deco


def owned_order_or_404(profile, pk):
    """Sirf is vendor ka order; doosre vendor ka order -> Http404 (aglay phases yehi use karein)."""
    return get_object_or_404(SaleOrder, pk=pk, vendor=profile.vendor)


def _media_url(f):
    try:
        return f.url if f else None
    except ValueError:
        return None


def _vendor_json(profile):
    v = profile.vendor
    rating = vendor_rating(v)
    return {
        'id': v.pk,
        'name': profile.business_name,
        'phone': v.contact_number or '',
        'city': profile.city or '',
        'approved': bool(profile.is_approved),
        'commission_percent': float(commission_percent(profile)),
        'rating': rating['avg'],
        'rating_count': rating['count'],
        'store_status': profile.store_status,
        'is_open': bool(profile.is_open_now),
        'location_verified': bool(profile.location_verified),
        'logo': _media_url(profile.logo),
    }


# ---------------------------------------------------------------- endpoints

@csrf_exempt
@require_http_methods(['POST'])
def api_login(request):
    d = _data(request)
    phone_raw = str(d.get('phone') or '').strip()[:20]
    password = d.get('password') or ''
    if not phone_raw or not password or not isinstance(password, str):
        return _err('Phone aur password dono likhein')

    phone = normalize_phone(phone_raw)
    key = _login_key(phone, get_client_ip(request) or '')      # web login wala hi lockout
    if cache.get(key, 0) >= LOGIN_MAX_ATTEMPTS:
        return _err('Bohat zyada koshishen. 10 minute baad dobara try karein.', 429, code='locked')

    profile = (VendorProfile.objects.select_related('user', 'vendor')
               .filter(vendor__contact_number=phone).first())
    user = None
    if profile and profile.user and not (profile.user.is_staff or profile.user.is_superuser):
        user = authenticate(request, username=profile.user.username, password=password)
    if not user:
        cache.set(key, cache.get(key, 0) + 1, LOGIN_LOCK_SECONDS)
        return _err('Phone ya password ghalat hai', 401, code='bad_login')

    cache.delete(key)
    profile.last_login_at = now()
    profile.save(update_fields=['last_login_at'])
    out = {'ok': True, 'token': _make_token(profile), 'vendor': _vendor_json(profile)}
    if not profile.is_approved:
        out['message'] = PENDING_MSG          # token milta hai taake app 'approval baqi' screen dikha sake
    return JsonResponse(out)


@vendor_api(['POST'], approval_required=False)
def api_logout(request, profile):
    """Token stateless hai (app apna token mita deti hai). Is phone ka push token server se bhi hat jata hai,
    taake logout ke baad is phone par vendor ke alert na aayein."""
    d = _data(request)
    tok = str(d.get('push_token') or d.get('token') or '').strip()
    if tok:
        VendorPushToken.objects.filter(profile=profile, token=tok).delete()
    return JsonResponse({'ok': True})


MAX_PUSH_TOKENS = 5     # ek vendor ke zyada se zyada itne phone


@vendor_api(['POST'])
def api_push_token(request, profile):
    """App apna FCM token yahan register karti hai (login ke baad aur token badalne par).

    Body: {token, platform?, device?}. Token ek hi vendor ka hota hai: kisi aur vendor ne isi phone par
    login kiya to token naye vendor ka ho jata hai (purane vendor ko is phone par alert nahi jayega).
    """
    d = _data(request)
    token = str(d.get('token') or '').strip()
    if not (20 <= len(token) <= 255) or any(c.isspace() for c in token):
        return _err('Push token ghalat hai.')
    platform = (str(d.get('platform') or 'android').strip() or 'android')[:20]
    defaults = {'profile': profile, 'platform': platform}
    device = str(d.get('device') or '').strip()[:100]
    if device:
        defaults['device'] = device
    with transaction.atomic():
        VendorPushToken.objects.update_or_create(token=token, defaults=defaults)
        keep = list(VendorPushToken.objects.filter(profile=profile).order_by('-updated_at', '-pk')
                    .values_list('pk', flat=True)[:MAX_PUSH_TOKENS])
        VendorPushToken.objects.filter(profile=profile).exclude(pk__in=keep).delete()
    return JsonResponse({'ok': True})


@vendor_api(['GET'], approval_required=False)
def api_me(request, profile):
    out = {'ok': True, 'vendor': _vendor_json(profile)}
    if not profile.is_approved:
        out['message'] = PENDING_MSG
    return JsonResponse(out)


# ================================================================
# Phase V4 - Dashboard tab
# Naya business logic nahi: hisaab wahi hai jo web portal (vendor_dashboard / vendor_analytics) ka hai.
# ================================================================

DASH_DAYS = 30            # mahina = pichle 30 din (web analytics ka '30 din' wala range)
DASH_LOW_ITEMS = 5        # dashboard par zyada se zyada itne kam-stock products ke naam


def _money(v):
    return round(float(Decimal(v or 0)), 2)


def _hhmm(t):
    return t.strftime('%H:%M') if t else ''


def _store_json(profile):
    """Store Open/Closed ki poori tasveer.

    switch_on  : vendor ne store khula rakha hai (status closed nahi)
    is_open    : customer abhi order de sakta hai (switch + timing + approval, web jaisa `is_open_now`)
    within_hours: timing ke andar? (timing set na ho to hamesha True)
    """
    return {
        'status': profile.store_status,
        'switch_on': profile.store_status != 'closed',
        'is_open': bool(profile.is_open_now),
        'within_hours': bool(profile.is_within_hours),
        'opens_at': _hhmm(profile.opens_at),
        'closes_at': _hhmm(profile.closes_at),
        'location_verified': bool(profile.location_verified),
    }


def _span(days, n):
    """Aakhri n din (aaj tak) ka total sale aur orders (cancelled ke baghair)."""
    rows = days[-n:]
    return {'sales': _money(sum((d['total'] for d in rows), Decimal('0'))),
            'orders': sum(d['orders'] for d in rows)}


def _dash_warnings(profile, store, new_orders, cash, stock, products):
    """App mein dikhane ke liye saaf warnings: {code, level (info/warn/error), text}."""
    w = []
    if store['status'] == 'closed':
        w.append({'code': 'store_closed', 'level': 'error',
                  'text': 'Aap ka store band hai - customer order nahi de sakta. Upar switch se store khol dein.'})
    elif not store['within_hours']:
        w.append({'code': 'outside_hours', 'level': 'warn',
                  'text': f"Abhi store ke timing ({store['opens_at']} - {store['closes_at']}) se bahar hai, "
                          'customer ko store band dikhega.'})
    elif store['status'] == 'busy':
        w.append({'code': 'store_busy', 'level': 'info',
                  'text': 'Store "Busy" hai - orders milte hain par customer ko der ka bataya jata hai.'})
    if new_orders:
        w.append({'code': 'new_orders', 'level': 'warn',
                  'text': f'{new_orders} naya order aap ke jawab ka intezar kar raha hai.' if new_orders == 1
                          else f'{new_orders} naye orders aap ke jawab ka intezar kar rahe hain.'})
    if cash['count']:
        w.append({'code': 'rider_cash', 'level': 'warn',
                  'text': f"Rider ne Rs. {cash['amount']:,.0f} cash handover kiya hai - confirm karna baqi hai."})
    if stock['out']:
        w.append({'code': 'out_of_stock', 'level': 'error',
                  'text': f"{stock['out']} product ka stock khatam hai." if stock['out'] == 1
                          else f"{stock['out']} products ka stock khatam hai."})
    if stock['low']:
        w.append({'code': 'low_stock', 'level': 'warn',
                  'text': f"{stock['low']} product ka stock kam hai." if stock['low'] == 1
                          else f"{stock['low']} products ka stock kam hai."})
    if products['rejected']:
        w.append({'code': 'rejected_products', 'level': 'warn',
                  'text': f"{products['rejected']} product reject hua - wajah dekh kar theek karke dobara bhejein."
                          if products['rejected'] == 1 else
                          f"{products['rejected']} products reject hue - wajah dekh kar theek karke dobara bhejein."})
    if products['pending']:
        w.append({'code': 'pending_products', 'level': 'info',
                  'text': f"{products['pending']} product admin approval ka intezar kar raha hai."
                          if products['pending'] == 1 else
                          f"{products['pending']} products admin approval ka intezar kar rahe hain."})
    if not profile.location_verified:
        w.append({'code': 'location_unverified', 'level': 'info',
                  'text': 'Store ki location verify nahi hui - verify karne par store naam ke saath blue tick aata hai.'})
    return w


@vendor_api(['GET'])
def api_dashboard(request, profile):
    """Vendor ka ek nazar mein poora business.

    Sale/orders `_analytics_data` (web 'Analytics' page) se, earnings `vendor_earnings` (web dashboard) se,
    rating `vendor_rating` se, stock `_stock_rows` se aate hain - sirf vendor=profile.vendor ka data.
    Paisay float (2 decimal); chart purana din pehle, aakhri entry aaj.
    """
    vendor = profile.vendor
    today = timezone.localdate()
    start_date = today - timedelta(days=DASH_DAYS - 1)
    start = timezone.make_aware(datetime.combine(start_date, dtime.min))
    data = _analytics_data(vendor, profile, start_date, today, start)
    days = data['days']

    # --- orders: web ke tabs (Naye / Chal rahe / Mukammal) jaisi ginti, aur status wise
    by_status = dict(SaleOrder.objects.filter(vendor=vendor).order_by()
                     .values_list('status').annotate(n=Count('id')))
    tabs = {key: sum(by_status.get(s, 0) for s in statuses) for key, (_, statuses) in ORDER_TABS.items()}
    new_orders = by_status.get('pending', 0)

    # --- products
    pc = dict(Product.objects.filter(vendor=vendor).order_by()
              .values_list('approval_status').annotate(n=Count('id')))
    products = {'approved': pc.get('approved', 0), 'pending': pc.get('pending', 0),
                'rejected': pc.get('rejected', 0)}
    products['total'] = sum(products.values())

    # --- stock (web wali `low` shart: approved aur stock <= threshold)
    rows = _stock_rows(vendor, _stock_warehouse())
    low_rows = [r for r in rows if r['low']]
    out_rows = [r for r in low_rows if r['stock'] <= 0]
    short_rows = [r for r in low_rows if r['stock'] > 0]
    stock = {
        'low': len(short_rows), 'out': len(out_rows),
        'items': [{'id': r['product'].pk, 'name': r['product'].name, 'stock': r['stock'], 'out': r['stock'] <= 0}
                  for r in sorted(low_rows, key=lambda r: (r['stock'], r['product'].name))[:DASH_LOW_ITEMS]],
    }

    # --- rider cash (vendor ke confirm ka intezar)
    agg = (RiderCashHandover.objects.filter(receiver='vendor', vendor=vendor, status='pending')
           .aggregate(n=Count('id'), amt=Sum('amount')))
    cash = {'count': agg['n'] or 0, 'amount': _money(agg['amt'])}

    store = _store_json(profile)
    vendor_data = _vendor_json(profile)
    earn = vendor_earnings(vendor)

    return JsonResponse({
        'ok': True,
        'generated_at': now().isoformat(),
        'vendor': vendor_data,
        'store': store,
        'today': _span(days, 1),
        'week': _span(days, 7),
        'month': _span(days, DASH_DAYS),
        'orders': {'new': tabs['new'], 'active': tabs['active'], 'done': tabs['done'],
                   'by_status': by_status, 'cancelled_30d': data['cancelled']},
        'new_orders': new_orders,
        'earnings': {'units': earn['units'], 'sales': _money(earn['sales']),
                     'commission': _money(earn['commission']), 'payable': _money(earn['payable'])},
        'commission_percent': vendor_data['commission_percent'],
        'rating': {'avg': vendor_data['rating'], 'count': vendor_data['rating_count']},
        'products': products,
        'stock': stock,
        'rider_cash': cash,
        'chart': [{'date': d['date'].isoformat(), 'label': d['date'].strftime('%a'),
                   'sales': _money(d['total']), 'orders': d['orders']} for d in days[-7:]],
        'warnings': _dash_warnings(profile, store, new_orders, cash, stock, products),
    })


_TRUE = (True, 1, '1', 'true', 'yes', 'on', 'open')
_FALSE = (False, 0, '0', 'false', 'no', 'off', 'closed')


@vendor_api(['POST'])
def api_store_open(request, profile):
    """Store Open/Closed switch. Body: {open: true|false}.

    open=true  -> store khul gaya (agar 'busy' tha to busy hi rehta hai: store khula hi hai)
    open=false -> store band (customer is store se order nahi de sakta)
    Sirf `store_status` badalta hai (VendorProfile ka purana field, koi migration nahi).
    """
    d = _data(request)
    raw = d.get('open')
    if isinstance(raw, str):
        raw = raw.strip().lower()
    if raw in _TRUE:
        status = 'busy' if profile.store_status == 'busy' else 'open'
    elif raw in _FALSE:
        status = 'closed'
    else:
        return _err('open ki value true ya false bhejein.')
    if status != profile.store_status:
        VendorProfile.objects.filter(pk=profile.pk).update(store_status=status)
        profile.store_status = status
        logger.info('Vendor %s store_status -> %s (app)', profile.pk, status)
    msg = 'Store khul gaya - ab customer order de sakte hain.' if status != 'closed' \
        else 'Store band kar diya - ab naye orders nahi aayenge.'
    if status != 'closed' and not profile.is_within_hours:
        msg = 'Store khol diya, par abhi timing se bahar hai - customer ko band dikhega.'
    return JsonResponse({'ok': True, 'message': msg, 'store': _store_json(profile),
                         'vendor': _vendor_json(profile)})


# ================================================================
# Phase V5 - Orders tab (list + actions + poll)
# Naya business logic nahi: status badalna `store_orders.apply_vendor_action` se hi hota hai (web jaisa),
# tabs `ORDER_TABS` se. Har order par ownership: vendor=profile.vendor (doosre ka order -> 404 JSON).
# ================================================================

ORDERS_PAGE_SIZE = 20
ORDER_ITEMS_PREVIEW = 3
PREP_OPTIONS = [10, 20, 30, 45]          # app ke chips (server 1-600 minute tak maanta hai)
ORDER_ACTIONS = tuple(store_orders.ACTIONS.keys())      # accept | reject | ready | delivered


def _tab_of_status(status):
    for key, (_, statuses) in ORDER_TABS.items():
        if status in statuses:
            return key
    return 'done'


def _qty(v):
    try:
        q = float(v or 0)
    except (TypeError, ValueError):
        return 0
    return int(q) if q == int(q) else round(q, 3)


def _order_delivery(o):
    """Rider / delivery ki chhoti info (na ho to None). Reverse OneToOne na ho to exception se bachao."""
    try:
        d = o.delivery_info
    except ObjectDoesNotExist:
        return None
    rider = d.rider
    return {
        'type': d.delivery_type,
        'status': d.status,
        'rider_name': (rider.name if rider else d.rider_name) or '',
        'rider_phone': (rider.phone if rider else d.rider_contact) or '',
    }


def _order_allowed_actions(order):
    """Is waqt kaun se actions ho sakte hain (web ke buttons jaisa: status `ACTIONS` ke `allowed_from` mein ho)."""
    return [a for a, (allowed_from, _new) in store_orders.ACTIONS.items() if order.status in allowed_from]


def _order_json(o):
    """Ek order ka JSON. Items `prefetch_related('items__product')` se aane chahiye (N+1 na ho)."""
    items = list(o.items.all())
    method = (o.payment_method or 'cod').strip().lower() or 'cod'
    is_cod = method == 'cod'
    cust = o.customer
    preview = [{'name': (i.product.name if i.product_id else ''), 'qty': _qty(i.qty),
                'price': _money(i.price), 'total': _money(i.total_amt)} for i in items[:ORDER_ITEMS_PREVIEW]]
    return {
        'id': o.pk,
        'order_no': o.order_no,
        'status': o.status,
        'status_label': o.get_status_display(),
        'tab': _tab_of_status(o.status),
        'created_at': o.order_date.isoformat() if o.order_date else '',
        'customer': {'name': cust.name or '', 'phone': cust.contact_number or '', 'address': cust.address or ''},
        'items_count': len(items),
        'items_qty': _qty(sum(float(i.qty or 0) for i in items)),
        'items_preview': preview,
        'items_more': max(0, len(items) - ORDER_ITEMS_PREVIEW),
        'subtotal': _money(o.total_after_discount()),
        'delivery_fee': _money(o.delivery_fee),
        'discount': _money(o.discount_value),
        'total': _money(store_orders.order_payable_total(o)),
        'payment': {'method': method, 'is_cod': is_cod, 'label': 'COD' if is_cod else 'Online'},
        'notes': (o.notes or '').strip(),
        'prep_minutes': o.prep_minutes,
        'reject_reason': o.reject_reason or '',
        'responded_at': o.vendor_responded_at.isoformat() if o.vendor_responded_at else None,
        'delivery': _order_delivery(o),
        'actions': _order_allowed_actions(o),
    }


def _tab_counts(vendor):
    by_status = dict(SaleOrder.objects.filter(vendor=vendor).order_by()
                     .values_list('status').annotate(n=Count('id')))
    return {key: sum(by_status.get(s, 0) for s in statuses) for key, (_, statuses) in ORDER_TABS.items()}


def _parse_page(raw):
    try:
        return max(1, min(int(raw), 10000))
    except (TypeError, ValueError):
        return 1


@vendor_api(['GET'])
def api_orders(request, profile):
    """GET /api/vendor/orders/?tab=new|active|done&page=1&q=

    Web `vendor_orders` jaisa: Naye (purana pehle), Chal rahe / Mukammal (naya pehle). Ghalat tab -> 'new'.
    q: order no, customer ka naam ya phone. Page 20 orders ka; `has_more` se agla page.
    """
    vendor = profile.vendor
    tab = request.GET.get('tab', 'new')
    if tab not in ORDER_TABS:
        tab = 'new'
    page = _parse_page(request.GET.get('page'))
    q = (request.GET.get('q') or '').strip()[:60]

    qs = SaleOrder.objects.filter(vendor=vendor, status__in=ORDER_TABS[tab][1])
    if q:
        qs = qs.filter(Q(order_no__icontains=q) | Q(customer__name__icontains=q)
                       | Q(customer__contact_number__icontains=q))
    qs = (qs.select_related('customer', 'delivery_info__rider').prefetch_related('items__product')
          .order_by('order_date' if tab == 'new' else '-order_date', 'pk'))
    start = (page - 1) * ORDERS_PAGE_SIZE
    rows = list(qs[start:start + ORDERS_PAGE_SIZE + 1])
    has_more = len(rows) > ORDERS_PAGE_SIZE
    rows = rows[:ORDERS_PAGE_SIZE]

    counts = _tab_counts(vendor)
    return JsonResponse({
        'ok': True,
        'generated_at': now().isoformat(),
        'tab': tab,
        'page': page,
        'has_more': has_more,
        'q': q,
        'counts': counts,
        'tabs': [{'key': k, 'label': v[0], 'count': counts[k]} for k, v in ORDER_TABS.items()],
        'orders': [_order_json(o) for o in rows],
        'reject_reasons': [{'code': c, 'label': l} for c, l in store_orders.REJECT_REASONS],
        'prep_options': PREP_OPTIONS,
    })


def _parse_prep(raw):
    """Tayyari ka time (minute). Khali -> None. Ghalat/range se bahar -> OrderActionError (web jaisa message)."""
    if raw is None or isinstance(raw, bool):
        return None
    if isinstance(raw, str):
        raw = raw.strip()
        if not raw:
            return None
    try:
        if isinstance(raw, float):
            if raw != int(raw):
                raise ValueError
            prep = int(raw)
        else:
            prep = int(raw)
    except (TypeError, ValueError, OverflowError):
        raise store_orders.OrderActionError('Tayyari ka time minutes mein likhein.')
    if not 1 <= prep <= 600:
        raise store_orders.OrderActionError('Tayyari ka time 1 se 600 minute ke beech likhein.')
    return prep


@vendor_api(['POST'])
def api_order_action(request, profile, pk, action):
    """POST /api/vendor/orders/<id>/<action>/   action: accept | reject | ready | delivered

    Body (JSON): accept -> {prep_minutes?}   reject -> {reason_code, reason_note?}
    `transaction.atomic` + `select_for_update`: ek hi order par do phone se action aaye to ek hi chalta hai,
    doosre ko 409 + saaf message (aur order ki taza haalat). Doosre vendor ka order -> 404.
    """
    if action not in store_orders.ACTIONS:
        return _err('Ghalat action.', 400, code='bad_action')
    d = _data(request)
    try:
        with transaction.atomic():
            order = SaleOrder.objects.select_for_update().filter(pk=pk, vendor=profile.vendor).first()
            if order is None:
                return _err('Order nahi mila.', 404, code='not_found')
            prep = _parse_prep(d.get('prep_minutes')) if action == 'accept' else None
            store_orders.apply_vendor_action(
                order, action, user=profile.user, prep_minutes=prep,
                reason_code=str(d.get('reason_code') or ''), reason_note=str(d.get('reason_note') or ''))
    except store_orders.OrderActionError as exc:
        out = {'ok': False, 'error': str(exc), 'message': str(exc), 'code': 'conflict'}
        fresh = (SaleOrder.objects.filter(pk=pk, vendor=profile.vendor)
                 .select_related('customer', 'delivery_info__rider').prefetch_related('items__product').first())
        if fresh is not None:
            out['order'] = _order_json(fresh)
        return JsonResponse(out, status=409)

    done = {
        'accept': f'Order #{order.order_no} qubool kar liya.',
        'reject': f'Order #{order.order_no} reject kar diya. Customer ko wajah bata di gayi.',
        'ready': f'Order #{order.order_no} tayyar hai.',
        'delivered': f'Order #{order.order_no} deliver ho gaya.',
    }[action]
    order = (SaleOrder.objects.filter(pk=order.pk).select_related('customer', 'delivery_info__rider')
             .prefetch_related('items__product').first())
    return JsonResponse({'ok': True, 'message': done, 'order': _order_json(order),
                         'next_tab': _tab_of_status(order.status), 'counts': _tab_counts(profile.vendor)})


@vendor_api(['GET'])
def api_orders_poll(request, profile):
    """Halka: naye (pending) orders ki ginti + sab se naya order id. App khula ho to 20-30 sec mein poochti hai."""
    new = SaleOrder.objects.filter(vendor=profile.vendor, status='pending')
    latest = new.order_by('-id').values_list('id', flat=True).first() or 0
    return JsonResponse({'ok': True, 'new': new.count(), 'latest_id': latest})


# ================================================================
# Phase V6 - Order detail + live tracking + rider assign
# Naya business logic nahi: rider dena `views_rider_portal._assign` se (web `vendor_assign_rider` ke wahi rules),
# location wahi `RiderLiveLocation` jo customer ke map ko milti hai. Har endpoint par ownership:
# vendor=profile.vendor (doosre vendor ka order -> 404 JSON, customer ka phone/location kabhi leak nahi).
# ================================================================

TRACK_STATUSES = ('assigned', 'picked_up', 'in_transit')      # rider_portal.TRACK_STATUSES jaisa (location isi dauran)
STALE_AFTER_SEC = 120                                          # 2 min se purani location = "ruk gayi"
_RANK = {'pending': 0, 'confirmed': 1, 'processing': 1, 'ready': 2,
         'partially_delivered': 4, 'delivered': 4, 'invoiced': 4}


def _owned_order(profile, pk, lock=False):
    qs = SaleOrder.objects.filter(pk=pk, vendor=profile.vendor)
    if lock:
        qs = qs.select_for_update()
    return qs.first()


def _not_found():
    return _err('Order nahi mila.', 404, code='not_found')


def _delivery_of(order):
    return DeliveryInfo.objects.filter(sale_order=order).select_related('rider').first()


def _iso(dt):
    return dt.isoformat() if dt else ''


def _order_steps(order, di):
    """Status stepper: Naya > Qubool > Tayyar > Raste mein > Deliver (reject par: Naya > Reject)."""
    if order.status == 'cancelled':
        return [{'key': 'new', 'label': 'Naya', 'done': True, 'at': _iso(order.order_date)},
                {'key': 'rejected', 'label': 'Reject', 'done': True, 'at': _iso(order.vendor_responded_at),
                 'failed': True}]
    rank = _RANK.get(order.status, 0)
    on_way = bool(di and di.status in ('picked_up', 'in_transit', 'delivered'))
    delivered = rank >= 4 or bool(di and di.status == 'delivered')
    return [
        {'key': 'new', 'label': 'Naya', 'done': True, 'at': _iso(order.order_date)},
        {'key': 'accepted', 'label': 'Qubool', 'done': rank >= 1, 'at': _iso(order.vendor_responded_at) if rank >= 1 else ''},
        {'key': 'ready', 'label': 'Tayyar', 'done': rank >= 2, 'at': ''},
        {'key': 'on_way', 'label': 'Raste mein', 'done': on_way or delivered,
         'at': _iso(di.picked_up_at) if di and (on_way or delivered) else ''},
        {'key': 'delivered', 'label': 'Deliver', 'done': delivered,
         'at': _iso(di.delivered_at) if di and delivered else ''},
    ]


def _commission_json(profile, order):
    """Is order ka andaza: items (discount ke baad) par vendor ka commission %. Asli hisaab bill banne par."""
    base = Decimal(order.total_after_discount() or 0)
    pct = commission_percent(profile)
    comm = (base * pct / HUNDRED).quantize(CENT, ROUND_HALF_UP)
    return {'percent': float(pct), 'base': _money(base), 'amount': _money(comm),
            'vendor_gets': _money(base - comm), 'estimated': True}


def _wa_url(order):
    phone = order.customer.contact_number or ''
    if not phone:
        return ''
    wa_action = {'confirmed': 'accept', 'ready': 'ready', 'delivered': 'delivered', 'cancelled': 'reject'}.get(order.status)
    try:
        text = (store_orders.customer_whatsapp_text(order, wa_action) if wa_action
                else f'Assalam o Alaikum, aap ke order #{order.order_no} ke baare mein.')
        return store_orders.whatsapp_link(phone, text) or ''
    except Exception:           # link banane ki ghalti se detail kabhi na ruke
        logger.exception('vendor api whatsapp link')
        return ''


def _detail_json(profile, order):
    """Poora order: list wale sab keys + full items, steps, timeline, rider, commission, coordinates."""
    out = _order_json(order)
    items = list(order.items.all())
    out['items'] = [{'product_id': i.product_id, 'name': (i.product.name if i.product_id else ''),
                     'qty': _qty(i.qty), 'price': _money(i.price), 'total': _money(i.total_amt),
                     'image': _media_url(i.product.image) if i.product_id else None} for i in items]
    di = _delivery_of(order)
    cust = order.customer
    portal = getattr(cust, 'portal_profile', None) if cust else None
    lat = getattr(portal, 'latitude', None)
    lng = getattr(portal, 'longitude', None)
    out['customer'] = dict(out['customer'], lat=lat, lng=lng)
    out['coupon'] = {'code': order.coupon_code or '', 'discount': _money(order.discount_value)}
    out['commission'] = _commission_json(profile, order)
    out['steps'] = _order_steps(order, di)
    out['timeline'] = [{'status': t.status, 'title': t.title or t.get_status_display(),
                        'description': t.description or '', 'at': _iso(t.timestamp),
                        'rider_name': t.rider_name or ''}
                       for t in OrderTracking.objects.filter(sale_order=order).order_by('timestamp', 'pk')]
    out['rider'] = None
    if di is not None and (di.rider_id or di.rider_name):
        out['rider'] = {'name': (di.rider.name if di.rider else di.rider_name) or '',
                        'phone': (di.rider.phone if di.rider else di.rider_contact) or '',
                        'vehicle': (di.rider.vehicle if di.rider else di.rider_vehicle) or '',
                        'status': di.status, 'assigned_at': _iso(di.assigned_at)}
    out['can_track'] = bool(di and di.rider_id and di.status in TRACK_STATUSES
                            and order.status not in ('cancelled', 'delivered', 'invoiced'))
    out['can_assign_rider'] = _can_assign(order, di)
    out['store_point'] = ([profile.latitude, profile.longitude]
                          if profile.latitude is not None and profile.longitude is not None else None)
    out['whatsapp_url'] = _wa_url(order)
    return out


def _can_assign(order, di):
    return order.status == 'ready' and not (di and di.status in ('picked_up', 'in_transit', 'delivered'))


def _fresh_order(pk, vendor):
    return (SaleOrder.objects.filter(pk=pk, vendor=vendor)
            .select_related('customer', 'customer__portal_profile', 'delivery_info__rider')
            .prefetch_related('items__product').first())


@vendor_api(['GET'])
def api_order_detail(request, profile, pk):
    """GET /api/vendor/orders/<id>/ - order ka poora detail (sirf is vendor ka; warna 404)."""
    order = _fresh_order(pk, profile.vendor)
    if order is None:
        return _not_found()
    return JsonResponse({'ok': True, 'generated_at': now().isoformat(), 'order': _detail_json(profile, order)})


@vendor_api(['GET'])
def api_order_track(request, profile, pk):
    """GET /api/vendor/orders/<id>/track/ - rider ki taza location.

    Sirf jab: order is vendor ka ho, rider assign ho, aur delivery chal rahi ho (assigned/picked_up/in_transit).
    Warna `active: false` + wajah (`reason`) - app map hide kar deti hai.
    """
    order = _owned_order(profile, pk)
    if order is None:
        return _not_found()
    di = _delivery_of(order)
    if order.status in ('cancelled', 'delivered', 'invoiced') or (di and di.status in ('delivered', 'cancelled')):
        return JsonResponse({'ok': True, 'active': False, 'reason': 'finished',
                             'message': 'Order mukammal hai - live tracking band.'})
    if di is None or not di.rider_id:
        return JsonResponse({'ok': True, 'active': False, 'reason': 'no_rider',
                             'message': 'Rider abhi assign nahi hua.'})
    if di.status not in TRACK_STATUSES:
        return JsonResponse({'ok': True, 'active': False, 'reason': 'not_started',
                             'message': 'Delivery abhi shuru nahi hui.'})
    rider = di.rider
    loc = getattr(rider, 'live_location', None)
    cust = order.customer
    portal = getattr(cust, 'portal_profile', None) if cust else None
    out = {
        'ok': True, 'active': True, 'status': di.status,
        'rider': {'name': rider.name, 'phone': rider.phone},
        'store': ([profile.latitude, profile.longitude]
                  if profile.latitude is not None and profile.longitude is not None else None),
        'dest': ([portal.latitude, portal.longitude]
                 if portal and portal.latitude is not None and portal.longitude is not None else None),
        'pos': None, 'age_sec': None, 'stale': True, 'heading': None,
        'updated_at': now().isoformat(),
    }
    if loc:
        age = max(0, int((now() - loc.updated_at).total_seconds()))
        out.update({'pos': [loc.latitude, loc.longitude], 'age_sec': age,
                    'stale': age > STALE_AFTER_SEC, 'heading': loc.heading})
    else:
        out['message'] = 'Rider ki location abhi nahi mili.'
    return JsonResponse(out)


def _riders_json():
    from django.db.models import Count as _Count
    rows = (RiderProfile.objects.filter(is_active=True)
            .annotate(busy=_Count('deliveries', filter=Q(deliveries__status__in=TRACK_STATUSES)))
            .order_by('-is_online', 'busy', 'name'))
    return [{'id': r.pk, 'name': r.name, 'phone': r.phone, 'vehicle': r.vehicle or '',
             'online': bool(r.is_online), 'active_orders': r.busy} for r in rows]


@vendor_api(['GET', 'POST'])
def api_assign_rider(request, profile, pk):
    """GET  /api/vendor/orders/<id>/assign-rider/  -> available riders (online pehle, kam masroof pehle)
       POST {rider_id}                             -> rider dena (web `vendor_assign_rider` ke wahi rules).

    Sirf 'Ready' order par; rider maal utha chuka ho to badal nahi sakte. select_for_update: do phone se
    ek saath dena ho to ek hi chalta hai.
    """
    if request.method == 'GET':
        order = _fresh_order(pk, profile.vendor)
        if order is None:
            return _not_found()
        di = _delivery_of(order)
        return JsonResponse({'ok': True, 'can_assign': _can_assign(order, di),
                             'current_rider_id': di.rider_id if di else None, 'riders': _riders_json()})

    from .views_rider_portal import _assign           # web wali wahi logic (lazy import: circular se bachao)
    d = _data(request)
    try:
        rider_id = int(d.get('rider_id'))
    except (TypeError, ValueError):
        return _err('Rider chunein.', 400, code='bad_rider')
    rider = RiderProfile.objects.filter(pk=rider_id, is_active=True).first()
    if rider is None:
        return _err('Ye rider maujood nahi ya band hai.', 404, code='bad_rider')
    try:
        with transaction.atomic():
            order = _owned_order(profile, pk, lock=True)
            if order is None:
                return _not_found()
            if order.status != 'ready':
                raise store_orders.OrderActionError('Rider sirf "Ready" order par chun sakte hain.')
            di, _ = DeliveryInfo.objects.select_for_update().get_or_create(sale_order=order)
            if di.status in ('picked_up', 'in_transit', 'delivered'):
                raise store_orders.OrderActionError('Rider maal utha chuka hai, ab badal nahi sakte.')
            _assign(order, di, rider, profile.user)
            store_orders._notify(rider.user, f'🏍️ Naya order #{order.order_no}',
                                 f'{store_orders.store_name(order.vendor_id)} se maal uthana hai.',
                                 '/shop/rider/', 'info')
    except store_orders.OrderActionError as exc:
        out = {'ok': False, 'error': str(exc), 'message': str(exc), 'code': 'conflict'}
        fresh = _fresh_order(pk, profile.vendor)
        if fresh is not None:
            out['order'] = _detail_json(profile, fresh)
        return JsonResponse(out, status=409)
    fresh = _fresh_order(pk, profile.vendor)
    return JsonResponse({'ok': True, 'message': f'Order #{fresh.order_no}: rider {rider.name} ko de diya.',
                         'order': _detail_json(profile, fresh), 'counts': _tab_counts(profile.vendor)})


# ================================================================
# Phase V8 - Products tab (list + toggle + quick update)
# Naya business logic nahi: stock/low ki shart web `_stock_rows` wali hai (approved aur stock <= threshold,
# threshold 0/khali ho to 10), quick-update `views_vendor_tools.quick_update_product` (web wali SHARED logic),
# toggle web `vendor_product_toggle` ka rule (sirf approved). Har query vendor=profile.vendor tak mehdood.
# ================================================================

PRODUCTS_PAGE_SIZE = 20
PRODUCT_STATUSES = ('approved', 'pending', 'rejected')
PRODUCT_STOCK_FILTERS = ('low', 'out')
QUICK_UPDATE_MAX_ITEMS = 50


def _product_qs(vendor):
    """Vendor ke products + stock (shop wali warehouse) + threshold, ek hi query mein (N+1 nahi)."""
    wh = _stock_warehouse()
    if wh:
        stock_sq = (Inventory.objects.filter(product=OuterRef('pk'), warehouse=wh)
                    .order_by().values('stock')[:1])
        stk = Coalesce(Subquery(stock_sq, output_field=FloatField()), Value(0.0), output_field=FloatField())
    else:
        stk = Value(0.0, output_field=FloatField())
    thr = Case(When(low_stock_threshold__isnull=True, then=Value(float(LOW_STOCK_DEFAULT))),
               When(low_stock_threshold=0, then=Value(float(LOW_STOCK_DEFAULT))),
               default=F('low_stock_threshold'), output_field=FloatField())
    return (Product.objects.filter(vendor=vendor)
            .select_related('category', 'unit')
            .annotate(stk=stk, thr=thr))


def _stock_state(approval_status, stock, threshold):
    """'out' (khatam) | 'low' (kam) | 'ok'. Sirf approved product par (dashboard jaisa)."""
    if approval_status != 'approved':
        return 'ok'
    if stock <= 0:
        return 'out'
    return 'low' if stock <= threshold else 'ok'


def _product_json(p):
    stock = float(getattr(p, 'stk', 0) or 0)
    thr = float(getattr(p, 'thr', LOW_STOCK_DEFAULT) or LOW_STOCK_DEFAULT)
    approved = p.approval_status == 'approved'
    original = p.original_price if p.original_price and p.original_price > 0 else p.price
    return {
        'id': p.pk,
        'name': p.name,
        'image': _media_url(p.image),
        'category': p.category.name if p.category_id else '',
        'unit': p.unit.name if p.unit_id else '',
        'barcode': p.barcode or '',
        'price': _money(p.price),                       # customer ko jo rate dikhta hai (discount ke baad)
        'original_price': _money(original),             # discount se pehle ka rate (quick edit isi ko badalta hai)
        'discount_percent': _money(p.discount_percentage),
        'stock': _qty(stock),
        'low_threshold': _qty(thr),
        'stock_state': _stock_state(p.approval_status, stock, thr),
        'approval_status': p.approval_status,
        'rejection_reason': (p.rejection_reason or '') if p.approval_status == 'rejected' else '',
        'is_active': bool(p.is_active),
        'visible': bool(approved and p.is_active),      # customer ko nazar aa raha hai?
        'can_toggle': approved,
        'can_edit_price': True,
    }


def _product_counts(vendor):
    """Chips ke badge: sab / approved / pending / rejected / kam stock / khatam (dashboard ke numbers ke barabar)."""
    rows = _product_qs(vendor).values('approval_status', 'stk', 'thr')
    c = {'all': 0, 'approved': 0, 'pending': 0, 'rejected': 0, 'low': 0, 'out': 0}
    for r in rows:
        c['all'] += 1
        c[r['approval_status']] = c.get(r['approval_status'], 0) + 1
        state = _stock_state(r['approval_status'], r['stk'] or 0, r['thr'] or LOW_STOCK_DEFAULT)
        if state in ('low', 'out'):
            c[state] += 1
    return c


@vendor_api(['GET'])
def api_products(request, profile):
    """GET /api/vendor/products/?q=&status=approved|pending|rejected&stock=low|out&page=1

    q: naam ya barcode. stock=low -> kam stock (>0 aur threshold tak), stock=out -> khatam. Page 20 ka; `has_more`.
    Ghalat status/stock value chupchap ignore (sab dikhao).
    """
    vendor = profile.vendor
    q = (request.GET.get('q') or '').strip()[:60]
    status = request.GET.get('status', '')
    stock = request.GET.get('stock', '')
    page = _parse_page(request.GET.get('page'))

    qs = _product_qs(vendor)
    if q:
        qs = qs.filter(Q(name__icontains=q) | Q(barcode__icontains=q))
    if status in PRODUCT_STATUSES:
        qs = qs.filter(approval_status=status)
    if stock == 'out':
        qs = qs.filter(approval_status='approved', stk__lte=0)
    elif stock == 'low':
        qs = qs.filter(approval_status='approved', stk__gt=0, stk__lte=F('thr'))
    else:
        stock = ''
    qs = qs.order_by('stk', 'name', 'pk') if stock else qs.order_by('-pk')

    start = (page - 1) * PRODUCTS_PAGE_SIZE
    rows = list(qs[start:start + PRODUCTS_PAGE_SIZE + 1])
    has_more = len(rows) > PRODUCTS_PAGE_SIZE
    rows = rows[:PRODUCTS_PAGE_SIZE]
    return JsonResponse({
        'ok': True,
        'generated_at': now().isoformat(),
        'page': page,
        'has_more': has_more,
        'q': q,
        'status': status if status in PRODUCT_STATUSES else '',
        'stock': stock,
        'counts': _product_counts(vendor),
        'products': [_product_json(p) for p in rows],
    })


def _fresh_product(vendor, pk):
    return _product_qs(vendor).filter(pk=pk).first()


@vendor_api(['POST'])
def api_product_toggle(request, profile, pk):
    """POST /api/vendor/products/<id>/toggle/   body (optional): {active: true|false}

    Web `vendor_product_toggle` ka rule: sirf approved product shop par show/hide hota hai (delete nahi).
    `active` bheja ho to wahi set hota hai (double tap/do phone se ulta na ho), warna ulta kar deta hai.
    Doosre vendor ka product -> 404.
    """
    vendor = profile.vendor
    d = _data(request)
    raw = d.get('active')
    if isinstance(raw, str):
        raw = raw.strip().lower()
    want = True if raw in _TRUE else False if raw in _FALSE else None

    with transaction.atomic():
        product = Product.objects.select_for_update().filter(pk=pk, vendor=vendor).first()
        if product is None:
            return _err('Ye product nahi mila.', 404, code='not_found')
        if product.approval_status != 'approved':
            return _err('Sirf approved product show/hide ho sakta hai.', 409, code='not_approved')
        new_state = (not product.is_active) if want is None else want
        if new_state != product.is_active:
            Product.objects.filter(pk=product.pk).update(is_active=new_state)
    fresh = _fresh_product(vendor, pk)
    msg = 'Product ab shop par nazar aayega.' if new_state else 'Product shop se chhupa diya.'
    return JsonResponse({'ok': True, 'message': msg, 'product': _product_json(fresh),
                         'counts': _product_counts(vendor)})


def _quick_items(d):
    """Body se items: {items:[{id, price, discount?, add?}]} ya ek product ka seedha {id, price, ...}."""
    items = d.get('items')
    if items is None and d.get('id') is not None:
        items = [d]
    if not isinstance(items, list):
        return None
    return items


def _raw(v):
    """JSON number/string dono ko web form jaisi string banao (Decimal parsing wahi chale)."""
    if v is None:
        return ''
    if isinstance(v, bool):
        return 'x'
    return str(v).strip()


@vendor_api(['POST'])
def api_products_quick_update(request, profile):
    """POST /api/vendor/products/quick-update/

    Body: {items: [{id, price, discount (0-90, optional), add (naya stock, optional)}]}  (ek product ho to seedha
    {id, price, ...} bhi chalta hai). Validation aur kaam bilkul web quick-update wala
    (`quick_update_product`): price > 0, discount 0-90, add 0..1,000,000, batch repricing, transaction.atomic.
    Price na bheji ho to product ki maujooda original price hi rakhi jati hai (sirf stock add karna ho to).
    Har product alag: ek ghalat ho to baqi phir bhi save hote hain; `results` mein har ek ka nateeja.
    """
    vendor = profile.vendor
    d = _data(request)
    items = _quick_items(d)
    if not items:
        return _err('Koi product nahi bheja.', 400, code='no_items')
    if len(items) > QUICK_UPDATE_MAX_ITEMS:
        return _err(f'Ek baar mein {QUICK_UPDATE_MAX_ITEMS} se zyada products nahi.', 400, code='too_many')

    pct = commission_percent(profile)
    warehouse = _stock_warehouse()
    results, changed, errors = [], 0, []
    seen = set()
    for it in items:
        if not isinstance(it, dict):
            continue
        try:
            pid = int(it.get('id'))
        except (TypeError, ValueError):
            continue
        if pid in seen:
            continue
        seen.add(pid)
        product = Product.objects.filter(pk=pid, vendor=vendor).first()
        if product is None:                        # doosre vendor ka / maujood nahi: chupchap error, leak nahi
            results.append({'id': pid, 'status': 'error', 'error': 'Ye product nahi mila.'})
            errors.append('Ye product nahi mila.')
            continue
        price_raw = _raw(it.get('price'))
        if not price_raw:
            price_raw = str(product.original_price if product.original_price and product.original_price > 0
                            else product.price)
        discount_raw = _raw(it['discount']) if 'discount' in it else str(product.discount_percentage or 0)
        status, errs = quick_update_product(product, price_raw, discount_raw, _raw(it.get('add')) or '0',
                                            pct, vendor, warehouse)
        row = {'id': pid, 'status': status}
        if status == 'error':
            row['error'] = errs[0] if errs else 'Update nahi ho saka.'
            errors.extend(errs)
        elif status == 'changed':
            changed += 1
        results.append(row)

    fresh = {p.pk: p for p in _product_qs(vendor).filter(pk__in=[r['id'] for r in results])}
    for r in results:
        if r['id'] in fresh:
            r['product'] = _product_json(fresh[r['id']])

    if changed and not errors:
        msg = f'{changed} product update ho gaya.' if changed == 1 else f'{changed} products update ho gaye.'
    elif changed:
        msg = f'{changed} update hue, {len(errors)} mein masla.'
    elif errors:
        msg = errors[0]
    else:
        msg = 'Koi tabdeeli nahi mili.'
    out = {'ok': bool(changed) or not errors, 'message': msg, 'changed': changed,
           'results': results, 'counts': _product_counts(vendor)}
    if not out['ok']:
        out['error'] = msg
        return JsonResponse(out, status=400)
    return JsonResponse(out)
