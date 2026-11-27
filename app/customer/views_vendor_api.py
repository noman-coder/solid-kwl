"""
Vendor Android app ke liye JSON API (token login).

Phase V1: foundation - login / logout / me. Baqi saari vendor API isi file ke helpers par khadi hongi.
Phase V2: push-token (FCM token register/refresh) aur logout par token hatana.
Phase V4: dashboard (aaj/hafta/mahina sale, orders, earnings, stock, 7-din chart, warnings) + store Open/Closed switch.
Phase V5: orders tab - list (Naye / Chal rahe / Mukammal + search + page), action (accept/reject/ready/delivered), poll.
Phase V6: order detail (items + images, customer, payment, status steps, rider, commission), live track (rider ki location),
          assign-rider (list + assign).
Phase V8: products tab - list (search/filter/page), toggle (shop par show/hide), quick-update (rate/discount/naya stock).
Phase V9-A: product add/edit - form-data (category/brand/unit list + limits + edit ke liye maujooda values),
          add (POST products/), edit (POST products/<id>/), naya category/brand/unit (POST masters/<kind>/).
          Validation web wali `_clean_product_form` / `_validate_image` hi hai. Photo optional hai (V9-B: app camera/gallery se bhejti hai).
Phase V10: stock tools - stock list (kam / khatam), stock adjust (add / minus + wajah, bulk), per-product threshold, stock history.
          Stock add/minus ki logic `vendor_stock.py` (add: `_add_stock`, minus: FIFO); history `VendorStockLog` (migration 0062).
Phase V11: sales tab - sales (summary, COD/online, profit, chart, top/slow), statement (din wise), orders (drill-down),
          export (CSV / PDF). Numbers web ke `_analytics_data` se; profit ke liye Product.purchase_rate (migration 0063,
          khali ho to profit 'N/A'). Add/edit product ab optional `purchase_rate` bhi leta hai.
Phase V12: rider cash - list (pending + history + jod) aur confirm / reject. Logic `rider_cash_service` ki hai (web wali wahi),
          confirm par RiderSettlement(cash_in) banti hai; reject par raqam rider ke paas hi rehti hai. Koi migration nahi.
Phase V13-B: offers - product par waqt-wala discount (start-end date). List / create / edit / toggle / delete + product picker.
          Product ki price kabhi nahi badalti: customer ko dikhate waqt offer upar se lagta hai (`offers.py`), khatam hote hi
          price khud pehli jaisi. Nayi table `ProductOffer` (migration 0064, sirf additive).
Phase V13: coupons - list (+ summary), create, edit, toggle (chalu / band), delete. Validation web wali `_clean_vendor_coupon`
          hi hai (coupon engine `coupons.evaluate` checkout par wahi chalta hai). Istemal ho chuka coupon delete nahi hota,
          sirf band hota hai (hisaab ka record bacha rahe). Koi migration nahi. (Offers - V13-B - alag sub-step.)
Phase V14: reviews - list (rating ka khulasa, 5-1 star bars, filter: sab / jawab nahi diya / jawab diya, star, page) aur reply
          (jawab dein / badlein / hatayein). Logic web ki `views_extras.save_vendor_reply` hi hai; customer ka naam privacy ke liye
          'Hadi A.' jaisa. Naye review par push pehle se (V2 `notify_new_review`). Koi migration nahi.
Phase V15: store settings - GET/POST `store/` (section-wise save: basic / timing / delivery / branding) aur `store/location/`
          (blue-tick location verify). Validation web ki `vendor_store_settings` / `vendor_location_verify` wali hi hai
          (`_parse_time`, `_parse_money`, `_areas_from_post`, `_validate_image`, `parse_coords`). Koi migration nahi.
Phase V16: profile (GET/POST: owner naam, email, city, address + support / privacy links), password badalna (naya token milta hai,
          doosre phone khud logout, un ke push token bhi hat jate hain) aur account delete (web `delete_account_vendor` wali hi
          rules + wipe: `views_account_deletion.wipe_vendor_account`). Koi migration nahi.
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
import csv
import io
import json
import logging
import re
from datetime import datetime, time as dtime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from functools import wraps

from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.core import signing
from django.core.exceptions import ObjectDoesNotExist, ValidationError
from django.core.validators import validate_email
from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.db.models import Case, Count, F, FloatField, OuterRef, Q, Subquery, Sum, Value, When
from django.db.models.functions import Coalesce, TruncDate
from django.http import HttpResponse, JsonResponse, QueryDict
from django.shortcuts import get_object_or_404
from django.urls import reverse
from django.utils import timezone
from django.utils.timezone import now
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from ..models import (Brand, Category, CompanyInfo, Coupon, CouponRedemption, DeliveryArea, DeliveryInfo, Inventory, OrderTracking,
                      Product, RiderCashHandover, RiderProfile, SaleOrder, SaleOrderItem, StoreCategory, Unit,
                      VendorProfile, VendorPushToken, VendorStockLog, ProductOffer, OrderReview)
from ..vendor_commission import CENT, HUNDRED, commission_percent, vendor_earnings
from . import offers as offers_engine, store_orders, vendor_stock
from .views_customer_auth import get_client_ip, normalize_phone
from .views_account_deletion import (LOCK_SECONDS as DELETE_LOCK_SECONDS, MAX_PASSWORD_TRIES as DELETE_MAX_TRIES,
                                     vendor_has_active_orders, wipe_vendor_account)
from .views_coupons import MAX_VENDOR_COUPONS, _clean_vendor_coupon
from .views_extras import MAX_REPLY_LEN, save_vendor_reply
from .whatsapp_link import build_whatsapp_link
from .geo import max_accuracy_m, parse_coords
from .views_reviews import _reviewer_name, vendor_rating
from .views_vendor_portal import (
    LOGIN_LOCK_SECONDS, LOGIN_MAX_ATTEMPTS, MASTER_MODELS, MAX_IMAGE_BYTES, MAX_PRICE, ORDER_TABS,
    _apply_product_edit, _areas_from_post, _auto_approve_products, _clean_product_form, _err_text, _login_key,
    _parse_money, _parse_time, _save_new_product, _stock_warehouse, _validate_image, create_master_entry,
)
from .views_vendor_tools import (DONE_STATUSES, LOW_STOCK_DEFAULT, OPEN_STATUSES, _analytics_data, _csv_safe, _stock_rows,
                                 quick_update_product)

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
        'needs_photo': not bool(p.image),               # Phase V9-B: card par "Photo lagayein"
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


@vendor_api(['GET', 'POST'])
def api_products(request, profile):
    """GET /api/vendor/products/?q=&status=approved|pending|rejected&stock=low|out&page=1
    (POST /api/vendor/products/ = naya product, dekhein `_product_create`)

    q: naam ya barcode. stock=low -> kam stock (>0 aur threshold tak), stock=out -> khatam. Page 20 ka; `has_more`.
    Ghalat status/stock value chupchap ignore (sab dikhao).
    """
    if request.method == 'POST':
        return _product_create(request, profile)
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


def _stock_now(product, warehouse):
    if not warehouse:
        return 0.0
    return float(Inventory.objects.filter(product=product, warehouse=warehouse)
                 .values_list('stock', flat=True).first() or 0)


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
        stock_before = _stock_now(product, warehouse)
        status, errs = quick_update_product(product, price_raw, discount_raw, _raw(it.get('add')) or '0',
                                            pct, vendor, warehouse)
        if status == 'changed':                    # Phase V10: stock add hua ho to history mein bhi likho
            added = vendor_stock.parse_qty(_raw(it.get('add')) or '0')
            if added:
                vendor_stock.log_quick_update_add(profile, product, added, stock_before,
                                                  _stock_now(product, warehouse))
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


# ================================================================
# Phase V9-A: product add / edit (+ form-data, naya category/brand/unit)
# ================================================================

_FORM_KEYS = ('name', 'description', 'category', 'brand', 'unit', 'price', 'discount_percentage', 'stock')
_REQUEST_KEY_RE = re.compile(r'^[A-Za-z0-9_-]{8,64}$')
NAME_MIN, NAME_MAX, DESC_MAX, MAX_DISCOUNT, MAX_STOCK = 3, 100, 2000, 90, 1_000_000


def _validation_err(errors, status=400):
    """Form ki ghaltiyan: error/message mein pehli, `errors` mein sab (app ek hi baar mein sab dikha sake)."""
    errors = [e for e in errors if e] or ['Form mein ghalti hai']
    return JsonResponse({'ok': False, 'error': errors[0], 'message': errors[0], 'code': 'validation',
                         'errors': errors}, status=status)


def _current_form_value(product, key):
    """Edit mein jo field bheji hi nahi gayi uski maujooda value (web form wali string shakl mein)."""
    if key == 'name':
        return product.name or ''
    if key == 'description':
        return product.description or ''
    if key in ('category', 'brand', 'unit'):
        return str(getattr(product, key + '_id') or '')
    if key == 'price':
        base = product.original_price if product.original_price and product.original_price > 0 else product.price
        return str(base)
    if key == 'discount_percentage':
        return str(product.discount_percentage or 0)
    return '0'                                        # stock: edit mein "naya stock add" hota hai


def _form_post(d, product=None):
    """JSON/multipart body ko web form jaisi string dict banao (`_clean_product_form` ke `post` ke liye).

    `discount` bhi `discount_percentage` ki jagah chalta hai. Edit (`product` diya ho) mein jo key bheji hi na
    ho wo maujooda value rehti hai (partial update / sirf photo badalna); bheji hui khali key ghalti shumar hogi.
    """
    out = {}
    for k in _FORM_KEYS:
        src = k
        if k == 'discount_percentage' and k not in d and 'discount' in d:
            src = 'discount'
        if src in d:
            out[k] = _raw(d.get(src))
        elif product is not None:
            out[k] = _current_form_value(product, k)
        else:
            out[k] = ''
    return out


def _parse_purchase_rate(d):
    """Optional `purchase_rate` (vendor ka kharid rate). Returns (given, value, error).

    given=False -> key bheji hi nahi (kuch na badlo). Khali string/None -> value None (rate hata do).
    Warna 0 se bara aur MAX_PRICE tak.
    """
    if 'purchase_rate' not in d:
        return False, None, None
    raw = _raw(d.get('purchase_rate'))
    if raw == '':
        return True, None, None
    try:
        v = Decimal(raw)
        if v <= 0 or v > MAX_PRICE:
            raise ArithmeticError
        return True, v.quantize(Decimal('0.01')), None
    except Exception:
        return True, None, 'Purchase rate sahi likhein (0 se zyada) ya khali chhor dein'



def _named(qs):
    return [{'id': o.pk, 'name': o.name} for o in qs.only('id', 'name').order_by('name')]


def _form_product_json(p, profile):
    """Edit form ke liye: product ki maujooda values (form ke field naamon mein)."""
    wh = _stock_warehouse()
    inv = Inventory.objects.filter(product=p, warehouse=wh).first() if wh else None
    base = p.original_price if p.original_price and p.original_price > 0 else p.price
    return {
        'id': p.pk,
        'name': p.name,
        'description': p.description or '',
        'category': p.category_id,
        'brand': p.brand_id,
        'unit': p.unit_id,
        'price': _money(base),
        'discount_percentage': _money(p.discount_percentage),
        'current_stock': _qty(inv.stock if inv else 0),
        'barcode': p.barcode or '',
        'purchase_rate': _money(p.purchase_rate) if p.purchase_rate is not None else None,
        'image': _media_url(p.image),
        'has_image': bool(p.image),
        'approval_status': p.approval_status,
        'rejection_reason': (p.rejection_reason or '') if p.approval_status == 'rejected' else '',
        'is_active': bool(p.is_active),
    }


@vendor_api(['GET'])
def api_product_form_data(request, profile):
    """GET /api/vendor/products/form-data/[?product=<id>]

    Form ke dropdown (categories, brands, units - web `_form_context` wali), limits, commission % aur
    auto-approve ka haal. `product` dein to us (apne) product ki maujooda values bhi (edit form ke liye);
    doosre vendor ka ya maujood na ho to 404.
    """
    out = {
        'ok': True,
        'categories': _named(Category.objects.all()),
        'brands': _named(Brand.objects.all()),
        'units': _named(Unit.objects.all()),
        'commission_percent': _money(commission_percent(profile)),
        'auto_approve': bool(_auto_approve_products()),
        'can_add': bool(_stock_warehouse()),
        'limits': {
            'name_min': NAME_MIN, 'name_max': NAME_MAX, 'description_max': DESC_MAX,
            'max_price': float(MAX_PRICE), 'purchase_rate_optional': True, 'max_discount': MAX_DISCOUNT, 'max_stock': MAX_STOCK,
            'max_image_mb': MAX_IMAGE_BYTES // (1024 * 1024), 'master_name_min': 2, 'master_name_max': 100,
        },
    }
    raw = request.GET.get('product')
    if raw not in (None, ''):
        try:
            pid = int(raw)
        except (TypeError, ValueError):
            pid = None
        product = Product.objects.filter(pk=pid, vendor=profile.vendor).select_related('category').first() \
            if pid else None
        if product is None:
            return _err('Ye product nahi mila.', 404, code='not_found')
        out['product'] = _form_product_json(product, profile)
    return JsonResponse(out)


def _product_create(request, profile):
    """POST /api/vendor/products/   (JSON ya multipart; `image` file optional)

    Fields: name, description, category (id), brand (id), unit (id), price (discount se pehle ka rate),
    discount_percentage (ya `discount`), stock, image (file, optional), request_key (optional - double tap /
    retry par dobara product na bane).
    Validation + save web wala (`_clean_product_form`, `_save_new_product`). Auto-approve ho to live, warna pending.
    Bina photo wala product auto-approve par bhi pending rehta hai (`needs_photo`) jab tak photo na aaye.
    """
    vendor = profile.vendor
    if not _stock_warehouse():
        return _err('Shop mein warehouse set nahi hai, admin se rabta karein.', 409, code='no_warehouse')
    d = _data(request)

    rk = str(d.get('request_key') or '')
    rk = rk if _REQUEST_KEY_RE.match(rk) else ''
    done_key = lock_key = ''
    if rk:
        done_key = f'vendor_prod_add:{vendor.pk}:{rk}'
        lock_key = done_key + ':lock'
        prev = cache.get(done_key)
        if prev:
            fresh = _fresh_product(vendor, prev)
            if fresh is not None:
                return JsonResponse({'ok': True, 'message': 'Ye product pehle hi save ho chuka hai.', 'duplicate': True,
                                     'product': _product_json(fresh), 'counts': _product_counts(vendor),
                                     'needs_photo': not bool(fresh.image),
                                     'live': fresh.approval_status == 'approved'})
        if not cache.add(lock_key, 1, 30):
            return _err('Product save ho raha hai, thora intezar karein.', 409, code='in_progress')

    try:
        data, errors = _clean_product_form(request, editing=False, post=_form_post(d), files=request.FILES,
                                           require_image=False)
        pr_given, pr_value, pr_err = _parse_purchase_rate(d)
        if pr_err:
            errors = list(errors) + [pr_err]
        if errors:
            return _validation_err(errors)
        no_photo = data['image'] is None
        photo_failed = False
        try:
            product = _save_new_product(request, profile, _stock_warehouse(), data, user=profile.user,
                                        force_pending=no_photo)
        except ValidationError as exc:
            return _validation_err([_err_text(exc)])
        except Exception:
            logger.exception('Vendor API product add error')
            product = None
            if not no_photo:
                # Phase V9-B: photo ki storage/upload fail ho to product na toote - bina photo ke save karo,
                # vendor ko batao ke photo dobara lagayein (edit se).
                try:
                    data['image'] = None
                    product = _save_new_product(request, profile, _stock_warehouse(), data, user=profile.user,
                                                force_pending=True)
                    no_photo = True
                    photo_failed = True
                except Exception:
                    logger.exception('Vendor API product add retry (without photo) error')
            if product is None:
                return _err('Product save nahi ho saka, dobara koshish karein.', 500, code='server')
        if pr_given and pr_value is not None:
            Product.objects.filter(pk=product.pk, vendor=vendor).update(purchase_rate=pr_value)
        if done_key:
            cache.set(done_key, product.pk, 600)
    finally:
        if lock_key:
            cache.delete(lock_key)

    live = product.approval_status == 'approved'
    if live:
        msg = 'Product shop par list ho gaya!'
    elif photo_failed:
        msg = 'Product save ho gaya, lekin photo upload nahi ho saki. Product par "Photo lagayein" se dobara lagayein.'
    elif no_photo:
        msg = 'Product save ho gaya. Photo lagane ke baad hi ye shop par aa sakega.'
    else:
        msg = 'Product jama ho gaya. Admin approval ke baad shop par nazar aayega.'
    return JsonResponse({'ok': True, 'message': msg, 'live': live, 'needs_photo': no_photo,
                         'photo_failed': photo_failed,
                         'product': _product_json(_fresh_product(vendor, product.pk)),
                         'counts': _product_counts(vendor)})


@vendor_api(['POST'])
def api_product_edit(request, profile, pk):
    """POST /api/vendor/products/<id>/   (JSON ya multipart)

    Web edit jaisa: price = discount se pehle ka rate, `stock` = naya stock JO ADD karna hai (0/khali = koi nahi).
    Jo field bheji hi na jaye wo waisi hi rehti hai (sirf photo badalna ho to sirf `image` bhejein).
    Naam/description/category/brand/photo badle to (auto-approve na ho) product dobara admin review mein jata hai;
    rejected product edit par dobara pending ho jata hai (`resubmitted`). Doosre vendor ka product -> 404.
    `request_key` (optional): retry / double tap par wohi tabdeeli (stock samet) dobara lagu nahi hoti (`duplicate`).
    """
    vendor = profile.vendor
    product = Product.objects.filter(pk=pk, vendor=vendor).first()
    if product is None:
        return _err('Ye product nahi mila.', 404, code='not_found')
    d = _data(request)

    # Phase V9-B: photo upload lambi request hai - jawab raste mein kho jaye to retry par stock dobara jama na ho
    # (edit mein stock "add" hota hai). App edit par bhi `request_key` bhejti hai.
    rk = str(d.get('request_key') or '')
    rk = rk if _REQUEST_KEY_RE.match(rk) else ''
    done_key = lock_key = ''
    if rk:
        done_key = f'vendor_prod_edit:{vendor.pk}:{pk}:{rk}'
        lock_key = done_key + ':lock'
        if cache.get(done_key):
            fresh = _fresh_product(vendor, pk)
            if fresh is not None:
                return JsonResponse({'ok': True, 'message': 'Ye tabdeeli pehle hi lag chuki hai.', 'duplicate': True,
                                     'resubmitted': False, 'live': fresh.approval_status == 'approved',
                                     'needs_photo': not bool(fresh.image), 'product': _product_json(fresh),
                                     'counts': _product_counts(vendor)})
        if not cache.add(lock_key, 1, 30):
            return _err('Update ho raha hai, thora intezar karein.', 409, code='in_progress')

    try:
        data, errors = _clean_product_form(request, editing=True, post=_form_post(d, product), files=request.FILES,
                                           require_image=False)
        pr_given, pr_value, pr_err = _parse_purchase_rate(d)
        if pr_err:
            errors = list(errors) + [pr_err]
        if errors:
            return _validation_err(errors)
        had_photo = bool(product.image)
        new_photo = data['image'] is not None
        try:
            with transaction.atomic():
                locked = Product.objects.select_for_update().filter(pk=pk, vendor=vendor).first()
                if locked is None:
                    return _err('Ye product nahi mila.', 404, code='not_found')
                resubmitted = _apply_product_edit(profile, locked, data, _stock_warehouse())
                if pr_given:
                    Product.objects.filter(pk=locked.pk, vendor=vendor).update(purchase_rate=pr_value)
        except ValidationError as exc:
            return _validation_err([_err_text(exc)])
        except Exception:
            logger.exception('Vendor API product edit error')
            if new_photo:
                return _err('Photo upload nahi ho saki, dobara koshish karein. Baqi data waisa hi hai.', 500,
                            code='server')
            return _err('Update nahi ho saka, dobara koshish karein.', 500, code='server')
        fresh = _fresh_product(vendor, pk)
        live = fresh.approval_status == 'approved'
        if resubmitted:
            msg = ('Photo badal gayi. Product dobara admin review ke liye gaya hai.' if new_photo
                   else 'Update ho gaya. Tabdeeli dobara admin review ke liye gayi hai.')
        elif new_photo and not had_photo:
            msg = ('Photo lag gayi, product live ho gaya!' if live
                   else 'Photo lag gayi. Admin approval ke baad product shop par nazar aayega.')
        elif new_photo:
            msg = 'Photo badal gayi.'
        else:
            msg = 'Product update ho gaya.'
        if done_key:
            cache.set(done_key, 1, 600)
        return JsonResponse({'ok': True, 'message': msg, 'resubmitted': resubmitted, 'live': live,
                             'needs_photo': not bool(fresh.image), 'product': _product_json(fresh),
                             'counts': _product_counts(vendor)})
    finally:
        if lock_key:
            cache.delete(lock_key)


@vendor_api(['POST'])
def api_create_master(request, profile, kind):
    """POST /api/vendor/masters/<category|brand|unit>/   body: {name}

    "+" button: naya Category/Brand/Unit (web `create_master_entry`). Wohi naam pehle se ho to wohi wapas
    (`existed: true`). Ghalat kind -> 404.
    """
    if kind not in MASTER_MODELS:
        return _err('Ye cheez nahi mili.', 404, code='not_found')
    payload, status = create_master_entry(profile.user_id, kind, _data(request).get('name', ''))
    if not payload.get('success'):
        msg = payload.get('message') or 'Save nahi ho saka.'
        return _err(msg, status if status != 200 else 400, code='validation')
    return JsonResponse({'ok': True, 'kind': kind, 'id': payload['id'], 'name': payload['name'],
                         'existed': bool(payload.get('existed')),
                         'message': 'Pehle se maujood hai, wohi chun liya.' if payload.get('existed')
                         else 'Naya naam jod diya.'})


# ================================================================
# Phase V10: stock & inventory tools
# ================================================================

STOCK_PAGE_SIZE = 30
STOCK_FILTERS = ('need', 'low', 'out', 'all')       # need = kam + khatam (default)
STOCK_ADJUST_MAX_ITEMS = 50
STOCK_THRESHOLD_MAX = 1_000_000
STOCK_HISTORY_PAGE_SIZE = 30


def _stock_reasons():
    return {k: [{'code': c, 'label': l} for c, l in v.items()] for k, v in vendor_stock.REASONS.items()}


def _stock_product_json(p, reserved=0.0):
    """Product ka card + stock ki tafseel (maujooda, reserved, bechne layak)."""
    j = _product_json(p)
    stock = float(getattr(p, 'stk', 0) or 0)
    j['reserved'] = _qty(reserved)
    j['available'] = _qty(max(stock - float(reserved or 0), 0))
    return j


def _reserved_map(ids):
    wh = _stock_warehouse()
    if not wh or not ids:
        return {}
    return {r['product_id']: r['reserved_stock'] for r in
            Inventory.objects.filter(warehouse=wh, product_id__in=ids).values('product_id', 'reserved_stock')}


def _stock_summary(vendor):
    c = _product_counts(vendor)
    return {'low': c['low'], 'out': c['out'], 'ok': max(c['approved'] - c['low'] - c['out'], 0),
            'approved': c['approved'], 'default_threshold': LOW_STOCK_DEFAULT}


@vendor_api(['GET'])
def api_stock(request, profile):
    """GET /api/vendor/stock/?filter=need|low|out|all&q=&page=1

    Sirf approved products (stock unhi ka matlab rakhta hai). filter: need (kam + khatam, default) | low | out | all.
    q: naam ya barcode (barcode scan isi se). Sab se kam stock pehle. Page 30 ka, `has_more`.
    `summary`: kam / khatam / theek ginti + default threshold. `reasons`: add/minus ki wajah ki list.
    """
    vendor = profile.vendor
    flt = request.GET.get('filter', 'need')
    if flt not in STOCK_FILTERS:
        flt = 'need'
    q = (request.GET.get('q') or '').strip()[:60]
    page = _parse_page(request.GET.get('page'))

    qs = _product_qs(vendor).filter(approval_status='approved')
    if q:
        qs = qs.filter(Q(name__icontains=q) | Q(barcode__icontains=q))
    if flt == 'out':
        qs = qs.filter(stk__lte=0)
    elif flt == 'low':
        qs = qs.filter(stk__gt=0, stk__lte=F('thr'))
    elif flt == 'need':
        qs = qs.filter(stk__lte=F('thr'))
    qs = qs.order_by('stk', 'name', 'pk')

    start = (page - 1) * STOCK_PAGE_SIZE
    rows = list(qs[start:start + STOCK_PAGE_SIZE + 1])
    has_more = len(rows) > STOCK_PAGE_SIZE
    rows = rows[:STOCK_PAGE_SIZE]
    reserved = _reserved_map([p.pk for p in rows])
    return JsonResponse({
        'ok': True,
        'generated_at': now().isoformat(),
        'filter': flt,
        'q': q,
        'page': page,
        'has_more': has_more,
        'summary': _stock_summary(vendor),
        'reasons': _stock_reasons(),
        'products': [_stock_product_json(p, reserved.get(p.pk, 0)) for p in rows],
    })


def _adjust_items(d):
    """Body: {items:[{id, mode, qty, reason?, note?}]} ya ek product ka seedha {id, mode, qty, ...}."""
    items = d.get('items')
    if items is None and d.get('id') is not None:
        items = [d]
    return items if isinstance(items, list) else None


@vendor_api(['POST'])
def api_stock_adjust(request, profile):
    """POST /api/vendor/stock/adjust/

    Body: {items: [{id, mode: 'add'|'minus', qty, reason, note?}], request_key?}  (ek product ho to seedha
    {id, mode, qty, ...} bhi chalta hai). Har product alag transaction: ek ghalat ho to baqi phir bhi lagte hain;
    `results` mein har ek ka nateeja. Negative stock nahi banta. `request_key` (8-64 akshar) wahi dobara bhejein
    to stock dobara nahi badalta (net toot kar retry). Har kamyab tabdeeli `VendorStockLog` mein.
    """
    vendor = profile.vendor
    d = _data(request)
    items = _adjust_items(d)
    if not items:
        return _err('Koi product nahi bheja.', 400, code='no_items')
    if len(items) > STOCK_ADJUST_MAX_ITEMS:
        return _err(f'Ek baar mein {STOCK_ADJUST_MAX_ITEMS} se zyada products nahi.', 400, code='too_many')

    base_key = str(d.get('request_key') or '').strip()
    if base_key and not _REQUEST_KEY_RE.match(base_key):
        base_key = ''
    warehouse = _stock_warehouse()
    results, changed, errors, seen = [], 0, [], set()
    for i, it in enumerate(items):
        if not isinstance(it, dict):
            continue
        try:
            pid = int(it.get('id'))
        except (TypeError, ValueError):
            continue
        if pid in seen:
            continue
        seen.add(pid)
        key = str(it.get('request_key') or '').strip()
        if not _REQUEST_KEY_RE.match(key):
            key = f'{base_key}-{pid}'[:64] if base_key else ''
        mode = str(it.get('mode') or '').strip().lower()
        status, res = vendor_stock.adjust_stock(
            profile, pid, mode, it.get('qty'), it.get('reason'), it.get('note'), key, warehouse)
        row = {'id': pid, 'status': status}
        if status == 'error':
            row['error'] = res['error']
            row['code'] = res.get('code', 'error')
            errors.append(res['error'])
        else:
            row.update(before=res['before'], after=res['after'], qty=res['qty'], kind=res['kind'])
            if status == 'ok':
                changed += 1
        results.append(row)

    if not results:
        return _err('Koi product nahi bheja.', 400, code='no_items')
    ids = [r['id'] for r in results]
    fresh = {p.pk: p for p in _product_qs(vendor).filter(pk__in=ids)}
    reserved = _reserved_map(ids)
    for r in results:
        if r['id'] in fresh:
            r['product'] = _stock_product_json(fresh[r['id']], reserved.get(r['id'], 0))

    done = [r for r in results if r['status'] in ('ok', 'same')]
    if done and not errors:
        msg = 'Stock update ho gaya.' if len(done) == 1 else f'{len(done)} products ka stock update ho gaya.'
    elif done:
        msg = f'{len(done)} update hue, {len(errors)} mein masla.'
    else:
        msg = errors[0] if errors else 'Koi tabdeeli nahi mili.'
    out = {'ok': bool(done) or not errors, 'message': msg, 'changed': changed, 'results': results,
           'summary': _stock_summary(vendor), 'counts': _product_counts(vendor)}
    if not out['ok']:
        out['error'] = msg
        return JsonResponse(out, status=400)
    return JsonResponse(out)


@vendor_api(['POST'])
def api_stock_threshold(request, profile):
    """POST /api/vendor/stock/threshold/   body: {id, threshold}

    Is product ka \"kam stock\" ka nishan (is se kam ya barabar = kam; push alert bhi isi par). 1 se 1,000,000.
    Sirf apna product; sirf yahi ek column badalta hai (product dobara save nahi hota).
    """
    vendor = profile.vendor
    d = _data(request)
    try:
        pid = int(d.get('id'))
    except (TypeError, ValueError):
        return _err('Product chunein.', 400, code='bad_id')
    try:
        thr = float(str(d.get('threshold')).strip())
    except (TypeError, ValueError):
        return _err('Hadd sahi likhein.', 400, code='bad_threshold')
    if not (1 <= thr <= STOCK_THRESHOLD_MAX) or thr != thr:
        return _err(f'Hadd 1 se {STOCK_THRESHOLD_MAX:,} ke beech honi chahiye.', 400, code='bad_threshold')
    thr = round(thr, 3)
    with transaction.atomic():
        product = Product.objects.select_for_update().filter(pk=pid, vendor=vendor).first()
        if product is None:
            return _err('Ye product nahi mila.', 404, code='not_found')
        Product.objects.filter(pk=product.pk).update(low_stock_threshold=thr)
    fresh = _product_qs(vendor).filter(pk=pid).first()
    reserved = _reserved_map([pid])
    return JsonResponse({'ok': True, 'message': 'Kam stock ki hadd badal gayi.',
                         'product': _stock_product_json(fresh, reserved.get(pid, 0)),
                         'summary': _stock_summary(vendor)})


@vendor_api(['GET'])
def api_stock_history(request, profile):
    """GET /api/vendor/stock/history/?product=<id>&page=1

    Stock ki tabdeeliyon ka record (naya pehle): kitna tha -> kitna hua, wajah, kab. `product` na ho to
    poore store ka. Sirf apni entries."""
    page = _parse_page(request.GET.get('page'))
    qs = VendorStockLog.objects.filter(profile=profile).select_related('product')
    raw = request.GET.get('product')
    if raw:
        try:
            qs = qs.filter(product_id=int(raw))
        except (TypeError, ValueError):
            return _err('Product sahi nahi.', 400, code='bad_id')
    start = (page - 1) * STOCK_HISTORY_PAGE_SIZE
    rows = list(qs[start:start + STOCK_HISTORY_PAGE_SIZE + 1])
    has_more = len(rows) > STOCK_HISTORY_PAGE_SIZE
    rows = rows[:STOCK_HISTORY_PAGE_SIZE]
    labels = {**vendor_stock.ADD_REASONS, **vendor_stock.MINUS_REASONS}
    return JsonResponse({
        'ok': True, 'page': page, 'has_more': has_more,
        'logs': [{
            'id': r.pk, 'product_id': r.product_id, 'product': r.product.name,
            'kind': r.kind, 'qty': _qty(r.qty), 'before': _qty(r.before), 'after': _qty(r.after),
            'reason': r.reason, 'reason_label': labels.get(r.reason, ''), 'note': r.note,
            'source': r.source, 'at': _iso(r.created_at),
        } for r in rows],
    })


# ================================================================ Phase V11: Sales, cash & profit
#
# Numbers web `vendor_analytics` (`_analytics_data`) se aate hain: sale = cancelled ke baghair orders ke items ka total,
# commission = sale - (sale x (100-%)/100). Statement sirf mukammal (delivered/invoiced) orders ka hai.

SALES_PERIODS = {'today': ('Aaj', 1), 'week': ('7 din', 7), 'month': ('30 din', 30)}
SALES_MAX_DAYS = 366
SALES_DRILL_GROUPS = ('sales', 'all', 'done', 'open', 'cancelled')
SALES_EXPORT_MAX_ROWS = 5000
SALES_SLOW_ITEMS = 5
_DATE_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')


def _parse_date(raw):
    raw = (raw or '').strip()
    if not _DATE_RE.match(raw):
        return None
    try:
        return datetime.strptime(raw, '%Y-%m-%d').date()
    except ValueError:
        return None


def _sales_range(request):
    """?period=today|week|month|custom&from=YYYY-MM-DD&to=YYYY-MM-DD -> (range dict, None) ya (None, error response).

    Ghalat/khali period -> 'week'. custom mein aaj se aagay ki tareekh aaj par ruk jati hai; zyada se zyada 366 din.
    `end` exclusive hai (aakhri din ke agle din ka 00:00).
    """
    key = (request.GET.get('period') or 'week').strip().lower()
    today = timezone.localdate()
    if key == 'custom':
        f = _parse_date(request.GET.get('from'))
        t = _parse_date(request.GET.get('to'))
        if not f or not t:
            return None, _err('Shuru aur aakhri tareekh sahi likhein (YYYY-MM-DD).', 400, code='validation')
        if t > today:
            t = today
        if f > t:
            return None, _err('Shuru ki tareekh aakhri tareekh se pehle honi chahiye.', 400, code='validation')
        if (t - f).days + 1 > SALES_MAX_DAYS:
            return None, _err('Zyada se zyada 1 saal (366 din) ka hisaab ek baar mein dekh sakte hain.', 400,
                              code='validation')
        label = 'Chuni hui muddat'
    else:
        if key not in SALES_PERIODS:
            key = 'week'
        label, days = SALES_PERIODS[key]
        f, t = today - timedelta(days=days - 1), today
    start = timezone.make_aware(datetime.combine(f, dtime.min))
    end = timezone.make_aware(datetime.combine(t + timedelta(days=1), dtime.min))
    return {'key': key, 'label': label, 'from': f, 'to': t, 'start': start, 'end': end,
            'days': (t - f).days + 1, 'today': today}, None


def _period_json(r):
    return {'key': r['key'], 'label': r['label'], 'from': r['from'].isoformat(), 'to': r['to'].isoformat(),
            'days': r['days']}


def _pay_group(method):
    """'cod' ya 'online' (_order_json wala usool: khali ya cod -> COD, baqi sab online)."""
    return 'cod' if (method or 'cod').strip().lower() in ('', 'cod') else 'online'


def _q2(v):
    return Decimal(v or 0).quantize(CENT, ROUND_HALF_UP)


def _share_json(sales, pct):
    """sale -> {sales, commission, net} (commission % ke hisab se, 2 decimal)."""
    sales = _q2(sales)
    commission = _q2(sales * Decimal(pct) / HUNDRED)
    return {'sales': _money(sales), 'commission': _money(commission), 'net': _money(sales - commission)}


def _profit_json(vendor, items, pct):
    """Profit sirf un items par jin ke product par purchase_rate bhara ho. Koi na ho to available=False (app 'N/A').

    gross = sale - (qty x purchase_rate); commission = us sale par commission %; net = gross - commission.
    """
    cost = covered_sales = Decimal('0')
    covered = 0
    rows = (items.filter(product__purchase_rate__isnull=False)
            .values_list('qty', 'total_amt', 'product__purchase_rate').iterator())
    for qty, total, rate in rows:
        covered += 1
        covered_sales += Decimal(total or 0)
        cost += Decimal(str(qty or 0)) * Decimal(rate)
    prods = Product.objects.filter(vendor=vendor, approval_status='approved')
    base = {'products_total': prods.count(),
            'products_with_rate': prods.filter(purchase_rate__isnull=False).count(),
            'items_covered': covered}
    if covered == 0:
        return dict(base, available=False, covered_sales=None, cost=None, gross=None, commission=None,
                    net=None, margin_percent=None)
    covered_sales, cost = _q2(covered_sales), _q2(cost)
    gross = covered_sales - cost
    commission = _q2(covered_sales * Decimal(pct) / HUNDRED)
    net = gross - commission
    margin = round(float(net * HUNDRED / covered_sales), 1) if covered_sales else None
    return dict(base, available=True, covered_sales=_money(covered_sales), cost=_money(cost), gross=_money(gross),
                commission=_money(commission), net=_money(net), margin_percent=margin)


def _slow_products(vendor, sold):
    """Approved + active products jo kam bike (0 bikri walay pehle). sold = {product_id: qty}."""
    rows = list(Product.objects.filter(vendor=vendor, approval_status='approved', is_active=True)
                .order_by().values_list('id', 'name'))
    rows.sort(key=lambda r: (float(sold.get(r[0]) or 0), r[1].lower()))
    return [{'product_id': pid, 'name': name, 'qty': _qty(sold.get(pid) or 0)}
            for pid, name in rows[:SALES_SLOW_ITEMS]]


@vendor_api(['GET'])
def api_sales(request, profile):
    """GET /api/vendor/sales/?period=today|week|month|custom&from=&to=

    Summary (sale, orders, avg, commission, net), COD vs Online, profit (purchase rate wale products par),
    din wise chart, top 10 aur kam chalne wale products. Sirf is vendor ka data.
    """
    r, bad = _sales_range(request)
    if bad:
        return bad
    vendor = profile.vendor
    data = _analytics_data(vendor, profile, r['from'], r['to'], r['start'], end=r['end'])
    pct = commission_percent(profile)
    sales = data['sales']
    commission = _q2(sales - data['est_share'])

    live = (SaleOrder.objects.filter(vendor=vendor, order_date__gte=r['start'], order_date__lt=r['end'])
            .exclude(status='cancelled'))
    items = SaleOrderItem.objects.filter(order__in=live)

    pay = {'cod': {'orders': 0, 'sales': Decimal('0')}, 'online': {'orders': 0, 'sales': Decimal('0')}}
    for row in (items.order_by().values('order__payment_method')
                .annotate(total=Sum('total_amt'), n=Count('order', distinct=True))):
        g = pay[_pay_group(row['order__payment_method'])]
        g['orders'] += row['n']
        g['sales'] += Decimal(row['total'] or 0)
    payments = {k: dict(_share_json(v['sales'], pct), orders=v['orders']) for k, v in pay.items()}

    sold = dict(items.order_by().values_list('product_id').annotate(q=Sum('qty')))
    top = [{'product_id': t['product_id'], 'name': t['product__name'] or '', 'qty': _qty(t['qty']),
            'sales': _money(t['total']), 'pct': t['pct']} for t in data['top']]

    return JsonResponse({
        'ok': True,
        'generated_at': now().isoformat(),
        'period': _period_json(r),
        'commission_percent': _money(pct),
        'summary': {
            'orders': data['total_orders'], 'done': data['done'], 'open': data['open_orders'],
            'cancelled': data['cancelled'], 'cancel_rate': data['cancel_rate'],
            'sales': _money(sales), 'units': _qty(data['units']), 'avg_order': _money(data['avg_order']),
            'commission': _money(commission), 'net': _money(data['est_share']),
        },
        'payments': payments,
        'profit': _profit_json(vendor, items, pct),
        'chart': [{'date': d['date'].isoformat(), 'label': d['date'].strftime('%d %b'),
                   'sales': _money(d['total']), 'orders': d['orders']} for d in data['days']],
        'top': top,
        'slow': _slow_products(vendor, sold),
        'lifetime': _lifetime_json(vendor),
    })


def _lifetime_json(vendor):
    e = vendor_earnings(vendor)
    return {'units': _qty(e['units']), 'sales': _money(e['sales']), 'commission': _money(e['commission']),
            'payable': _money(e['payable'])}


@vendor_api(['GET'])
def api_sales_statement(request, profile):
    """GET /api/vendor/sales/statement/?period=...  Din wise kamayi (sirf mukammal orders: delivered/invoiced).

    Har din: orders, sale, commission, vendor ko milne wali raqam. Naya din pehle. `lifetime` = ab tak ka poora hisaab.
    """
    r, bad = _sales_range(request)
    if bad:
        return bad
    vendor = profile.vendor
    pct = commission_percent(profile)
    items = SaleOrderItem.objects.filter(order__vendor=vendor, order__status__in=DONE_STATUSES,
                                         order__order_date__gte=r['start'], order__order_date__lt=r['end'])
    rows = (items.annotate(d=TruncDate('order__order_date')).order_by().values('d')
            .annotate(total=Sum('total_amt'), n=Count('order', distinct=True)))
    days = []
    tot_sales = Decimal('0')
    tot_orders = 0
    for row in sorted(rows, key=lambda x: x['d'], reverse=True):
        tot_sales += Decimal(row['total'] or 0)
        tot_orders += row['n']
        days.append(dict(_share_json(row['total'], pct), date=row['d'].isoformat(), orders=row['n']))
    return JsonResponse({
        'ok': True,
        'generated_at': now().isoformat(),
        'period': _period_json(r),
        'commission_percent': _money(pct),
        'note': 'Sirf mukammal (delivered) orders. Commission/net commission % ke hisab se.',
        'total': dict(_share_json(tot_sales, pct), orders=tot_orders),
        'days': days,
        'lifetime': _lifetime_json(vendor),
    })


@vendor_api(['GET'])
def api_sales_orders(request, profile):
    """GET /api/vendor/sales/orders/?period=...&group=sales|all|done|open|cancelled&day=YYYY-MM-DD&payment=cod|online&page=

    Sales ke number par tap karne par us hisaab ke orders (drill-down). Order ka JSON `orders` list wala hi hai.
    group: sales (cancelled ke baghair - sale wala hisaab, default), all, done, open, cancelled.
    """
    r, bad = _sales_range(request)
    if bad:
        return bad
    vendor = profile.vendor
    group = (request.GET.get('group') or 'sales').strip().lower()
    if group not in SALES_DRILL_GROUPS:
        group = 'sales'
    qs = SaleOrder.objects.filter(vendor=vendor, order_date__gte=r['start'], order_date__lt=r['end'])
    if group == 'sales':
        qs = qs.exclude(status='cancelled')
    elif group == 'done':
        qs = qs.filter(status__in=DONE_STATUSES)
    elif group == 'open':
        qs = qs.filter(status__in=OPEN_STATUSES)
    elif group == 'cancelled':
        qs = qs.filter(status='cancelled')

    raw_day = (request.GET.get('day') or '').strip()
    day = None
    if raw_day:
        day = _parse_date(raw_day)
        if not day:
            return _err('Din ki tareekh sahi likhein (YYYY-MM-DD).', 400, code='validation')
        d0 = timezone.make_aware(datetime.combine(day, dtime.min))
        qs = qs.filter(order_date__gte=d0, order_date__lt=d0 + timedelta(days=1))

    payment = (request.GET.get('payment') or '').strip().lower()
    cod_q = Q(payment_method__iexact='cod') | Q(payment_method='')
    if payment == 'cod':
        qs = qs.filter(cod_q)
    elif payment == 'online':
        qs = qs.exclude(cod_q)
    else:
        payment = ''

    page = _parse_page(request.GET.get('page'))
    total = qs.count()
    qs = (qs.select_related('customer', 'delivery_info__rider').prefetch_related('items__product')
          .order_by('-order_date', '-pk'))
    start = (page - 1) * ORDERS_PAGE_SIZE
    rows = list(qs[start:start + ORDERS_PAGE_SIZE + 1])
    has_more = len(rows) > ORDERS_PAGE_SIZE
    rows = rows[:ORDERS_PAGE_SIZE]
    return JsonResponse({
        'ok': True, 'period': _period_json(r), 'group': group, 'day': day.isoformat() if day else '',
        'payment': payment, 'page': page, 'has_more': has_more, 'count': total,
        'orders': [_order_json(o) for o in rows],
    })


def _export_rows(vendor, r, pct):
    """Export ke liye (order, items_total, commission, net) - cancelled order par commission/net 0."""
    qs = (SaleOrder.objects.filter(vendor=vendor, order_date__gte=r['start'], order_date__lt=r['end'])
          .select_related('customer').prefetch_related('items').order_by('-order_date', '-pk'))
    out = []
    for o in qs[:SALES_EXPORT_MAX_ROWS]:
        items = list(o.items.all())
        total = _q2(sum((i.total_amt for i in items), Decimal('0')))
        if o.status == 'cancelled':
            comm = net = Decimal('0.00')
        else:
            comm = _q2(total * pct / HUNDRED)
            net = total - comm
        out.append((o, len(items), total, comm, net))
    return out


@vendor_api(['GET'])
def api_sales_export(request, profile):
    """GET /api/vendor/sales/export/?period=...&format=csv|pdf  -> file (app se share: WhatsApp / email).

    CSV: web export jaisi (+ payment, commission, net). PDF: summary + orders ki list (max 5000 orders).
    """
    r, bad = _sales_range(request)
    if bad:
        return bad
    vendor = profile.vendor
    pct = commission_percent(profile)
    fmt = (request.GET.get('format') or 'csv').strip().lower()
    rows = _export_rows(vendor, r, pct)
    name = f"sales_{r['from']}_{r['to']}"

    if fmt == 'pdf':
        try:
            body = _sales_pdf(profile, r, pct, rows)
        except Exception:
            logger.exception('Vendor sales pdf error')
            return _err('PDF nahi ban saki, CSV try karein.', 500, code='server')
        resp = HttpResponse(body, content_type='application/pdf')
        resp['Content-Disposition'] = f'attachment; filename="{name}.pdf"'
        return resp

    resp = HttpResponse(content_type='text/csv; charset=utf-8')
    resp['Content-Disposition'] = f'attachment; filename="{name}.csv"'
    resp.write('\ufeff')            # Excel mein UTF-8 theek khule
    w = csv.writer(resp)
    w.writerow(['Order No', 'Date', 'Customer', 'Status', 'Payment', 'Items', 'Total (Rs.)',
                'Commission (Rs.)', 'Net (Rs.)'])
    for o, n, total, comm, net in rows:
        w.writerow([_csv_safe(o.order_no), timezone.localtime(o.order_date).strftime('%Y-%m-%d %H:%M'),
                    _csv_safe(o.customer.name), o.get_status_display(),
                    'COD' if _pay_group(o.payment_method) == 'cod' else 'Online', n,
                    f'{total:.2f}', f'{comm:.2f}', f'{net:.2f}'])
    return resp


def _sales_pdf(profile, r, pct, rows):
    """Chhota PDF (reportlab, requirements mein pehle se). Sirf English/ASCII text (default font)."""
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

    def safe(t):
        return (str(t or '').encode('latin-1', 'replace').decode('latin-1')
                .replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))

    live = [x for x in rows if x[0].status != 'cancelled']
    sales = sum((x[2] for x in live), Decimal('0'))
    comm = sum((x[3] for x in live), Decimal('0'))
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, leftMargin=28, rightMargin=28, topMargin=28, bottomMargin=28)
    st = getSampleStyleSheet()
    els = [Paragraph(safe(f'Sales Report - {profile.business_name or "Store"}'), st['Title']),
           Paragraph(f"{r['from']}  to  {r['to']}", st['Normal']), Spacer(1, 10)]
    summary = [['Orders (live)', str(len(live))], ['Sales (Rs.)', f'{sales:,.2f}'],
               [f'Commission {pct}% (Rs.)', f'{comm:,.2f}'], ['Net earning (Rs.)', f'{sales - comm:,.2f}']]
    t = Table(summary, colWidths=[200, 120])
    t.setStyle(TableStyle([('GRID', (0, 0), (-1, -1), 0.4, colors.grey), ('ALIGN', (1, 0), (1, -1), 'RIGHT')]))
    els += [t, Spacer(1, 14)]
    data = [['Order', 'Date', 'Customer', 'Status', 'Pay', 'Total', 'Net']]
    for o, n, total, c, net in rows:
        data.append([safe(o.order_no), timezone.localtime(o.order_date).strftime('%d-%m-%y %H:%M'),
                     safe((o.customer.name or '')[:18]), safe(o.get_status_display()),
                     'COD' if _pay_group(o.payment_method) == 'cod' else 'Online', f'{total:,.0f}', f'{net:,.0f}'])
    t = Table(data, repeatRows=1)
    t.setStyle(TableStyle([('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#0F766E')),
                           ('TEXTCOLOR', (0, 0), (-1, 0), colors.white), ('FONTSIZE', (0, 0), (-1, -1), 8),
                           ('GRID', (0, 0), (-1, -1), 0.3, colors.lightgrey),
                           ('ALIGN', (5, 0), (-1, -1), 'RIGHT')]))
    els.append(t)
    doc.build(els)
    return buf.getvalue()


# ================================================================ Phase V12: Rider cash handover
#
# Rider COD cash vendor ko deta hai -> vendor app se confirm / reject karta hai. Logic web wali `rider_cash_service`
# (confirm_handover / reject_handover) hi hai: transaction.atomic + select_for_update, double confirm par sirf ek
# settlement, confirm ke baghair rider ka balance nahi badalta. Yahan sirf JSON + ownership check hai.

CASH_HISTORY_PAGE_SIZE = 20
CASH_PENDING_MAX = 100
CASH_ACTIONS = ('confirm', 'reject')


def _cash_summary(vendor):
    """Ek hi query mein: pending ginti + raqam, confirm ho chuka jod, reject ginti."""
    agg = RiderCashHandover.objects.filter(receiver='vendor', vendor=vendor).aggregate(
        p_n=Count('id', filter=Q(status='pending')), p_amt=Sum('amount', filter=Q(status='pending')),
        c_n=Count('id', filter=Q(status='confirmed')), c_amt=Sum('amount', filter=Q(status='confirmed')),
        r_n=Count('id', filter=Q(status='rejected')))
    return {
        'pending_count': agg['p_n'] or 0, 'pending_amount': _money(agg['p_amt']),
        'confirmed_count': agg['c_n'] or 0, 'confirmed_total': _money(agg['c_amt']),
        'rejected_count': agg['r_n'] or 0,
    }


def _cash_json(h):
    orders = []
    for d in h.orders.all():
        so = d.sale_order if d.sale_order_id else None
        orders.append({'id': d.sale_order_id or 0, 'order_no': so.order_no if so else '',
                       'cash': _money(d.cash_collected)})
    rider = h.rider
    return {
        'id': h.pk, 'status': h.status, 'amount': _money(h.amount), 'note': h.note,
        'reject_reason': h.reject_reason,
        'rider': {'id': rider.pk, 'name': rider.name, 'phone': rider.phone or ''},
        'orders': orders,
        'created_at': _iso(h.created_at), 'decided_at': _iso(h.decided_at),
    }


def _cash_qs(vendor):
    """Sirf is vendor ke (receiver='vendor') handovers."""
    return (RiderCashHandover.objects.filter(receiver='vendor', vendor=vendor)
            .select_related('rider').prefetch_related('orders__sale_order'))


@vendor_api(['GET'])
def api_rider_cash(request, profile):
    """GET /api/vendor/rider-cash/?page=1

    summary + pending (page 1 par, sab, naya pehle) + history (confirm / reject, naya pehle, 20 ek page).
    Sirf apne handovers; doosre vendor ya admin ke kabhi nahi."""
    vendor = profile.vendor
    page = _parse_page(request.GET.get('page'))
    qs = _cash_qs(vendor)
    pending = []
    if page == 1:
        pending = [_cash_json(h) for h in qs.filter(status='pending').order_by('-created_at')[:CASH_PENDING_MAX]]
    start = (page - 1) * CASH_HISTORY_PAGE_SIZE
    rows = list(qs.exclude(status='pending').order_by('-created_at')[start:start + CASH_HISTORY_PAGE_SIZE + 1])
    has_more = len(rows) > CASH_HISTORY_PAGE_SIZE
    rows = rows[:CASH_HISTORY_PAGE_SIZE]
    return JsonResponse({
        'ok': True, 'page': page, 'has_more': has_more,
        'summary': _cash_summary(vendor),
        'pending': pending,
        'history': [_cash_json(h) for h in rows],
    })


@vendor_api(['POST'])
def api_rider_cash_action(request, profile, pk, action):
    """POST /api/vendor/rider-cash/<id>/<confirm|reject>/

    body: {amount?: 1500, reason?: '...'}
      amount (optional): jo raqam vendor ne screen par dekhi; handover ki raqam isse alag ho to 409 `changed`
                         (galat raqam confirm na ho).
      reason: reject par zaroori (max 200).
    Doosre vendor ka / admin ka handover -> 404. Pehle hi confirm / reject ho chuka -> 409 `handover`."""
    from .rider_cash_service import HandoverError, confirm_handover, reject_handover
    if action not in CASH_ACTIONS:
        return _err('Ghalat action.', 400, code='bad_action')
    vendor = profile.vendor
    if not RiderCashHandover.objects.filter(pk=pk, receiver='vendor', vendor=vendor).exists():
        return _err('Handover nahi mila.', 404, code='not_found')
    d = _data(request)

    raw_amt = d.get('amount')
    if raw_amt not in (None, ''):
        try:
            seen = Decimal(str(raw_amt).strip().replace(',', '')).quantize(CENT, ROUND_HALF_UP)
        except Exception:
            return _err('Raqam sahi nahi.', 400, code='validation')
        cur = RiderCashHandover.objects.filter(pk=pk).values_list('amount', flat=True).first()
        if cur is None or seen != Decimal(cur).quantize(CENT, ROUND_HALF_UP):
            return _err('Raqam badal chuki hai. List taza karke dobara dekhein.', 409, code='changed')

    try:
        if action == 'confirm':
            done = confirm_handover(pk, profile.user, vendor=vendor)
            msg = f'Rider {done.rider.name} se Rs. {done.amount:,.0f} cash mil gaya (confirm).'
        else:
            reason = str(d.get('reason') or '').strip()
            if not reason:
                return _err('Reject karne ki wajah likhein.', 400, code='validation')
            done = reject_handover(pk, profile.user, reason, vendor=vendor)
            msg = f'Handover reject kar diya. Rider {done.rider.name} ko wajah bhej di.'
    except HandoverError as exc:
        return _err(str(exc), 409, code='handover')

    fresh = _cash_qs(vendor).get(pk=pk)
    return JsonResponse({'ok': True, 'message': msg, 'handover': _cash_json(fresh),
                         'summary': _cash_summary(vendor)})


# ================================================================
# Phase V13: coupons
# GET/POST /api/vendor/coupons/   POST .../<id>/   POST .../<id>/toggle/   POST .../<id>/delete/
# Naya business logic nahi: validation web wali `_clean_vendor_coupon`; checkout par `coupons.evaluate` wahi chalta hai.
# ================================================================

COUPON_TRUE = (True, 1, '1', 'true', 'True', 'TRUE', 'on', 'yes')


def _coupon_form(d):
    """JSON body ko `_clean_vendor_coupon` ke form (sab text) mein badlo. Web form jaisa hi: first_order_only='on'."""
    def txt(key):
        v = d.get(key)
        return '' if v is None or isinstance(v, (dict, list)) else str(v).strip()

    form = {k: txt(k) for k in ('code', 'title', 'discount_type', 'value', 'max_discount', 'min_order', 'usage_limit',
                                'per_customer_limit', 'valid_from', 'valid_until')}
    form['first_order_only'] = 'on' if d.get('first_order_only') in COUPON_TRUE else ''
    return form


def _local_ymd(dt):
    return timezone.localtime(dt).date().isoformat() if dt else ''


def _coupon_share_text(c, store):
    lines = [f'🎁 {store} par coupon: {c.code}']
    lines.append(f'{c.title} ({c.short_label})' if c.title else c.short_label)
    if c.min_order and c.min_order > 0:
        lines.append(f'Kam az kam Rs. {c.min_order:,.0f} ka order')
    if c.first_order_only:
        lines.append('Sirf pehle order par')
    if c.valid_until:
        lines.append(f'{_local_ymd(c.valid_until)} tak')
    lines.append('Checkout par code likh kar discount lein.')
    return '\n'.join(lines)


def _coupon_json(c, used, given, store=''):
    """`used` = cancelled orders ke baghair istemal; `given` = ab tak diya gaya discount + delivery maaf (Rs.)."""
    remaining = None if c.usage_limit is None else max(0, c.usage_limit - used)
    return {
        'id': c.pk, 'code': c.code, 'title': c.title or '', 'label': c.short_label,
        'discount_type': c.discount_type, 'value': _money(c.value),
        'max_discount': _money(c.max_discount) if c.max_discount is not None else None,
        'min_order': _money(c.min_order),
        'usage_limit': c.usage_limit, 'per_customer_limit': c.per_customer_limit,
        'first_order_only': bool(c.first_order_only),
        'valid_from': _local_ymd(c.valid_from), 'valid_until': _local_ymd(c.valid_until),
        'is_active': bool(c.is_active), 'status': c.status,
        'used': used, 'remaining': remaining, 'given': _money(given),
        'core_locked': used > 0,     # istemal ke baad type / value / code badalna band
        'created_at': _iso(c.created_at),
        'share_text': _coupon_share_text(c, store),
    }


def _coupon_usage(vendor, ids=None):
    """{coupon_id: (used, given)} - cancelled order wali redemption ginti mein nahi (Coupon.live_redemptions jaisa)."""
    qs = CouponRedemption.objects.filter(coupon__vendor=vendor).exclude(sale_order__status='cancelled')
    if ids is not None:
        qs = qs.filter(coupon_id__in=ids)
    rows = qs.values('coupon_id').annotate(n=Count('id'), d=Sum('discount_amount'), w=Sum('delivery_waived'))
    return {r['coupon_id']: (r['n'] or 0, Decimal(r['d'] or 0) + Decimal(r['w'] or 0)) for r in rows}


def _coupon_summary(coupons, usage):
    s = {'total': len(coupons), 'max': MAX_VENDOR_COUPONS, 'active': 0, 'scheduled': 0, 'expired': 0, 'paused': 0,
         'used_total': 0, 'given_total': 0.0}
    given = Decimal('0')
    for c in coupons:
        st = c.status
        key = 'expired' if st in ('expired', 'used_up') else st
        if key in s:
            s[key] += 1
        n, g = usage.get(c.pk, (0, Decimal('0')))
        s['used_total'] += n
        given += g
    s['given_total'] = _money(given)
    return s


def _coupons_payload(profile):
    vendor = profile.vendor
    coupons = list(Coupon.objects.filter(vendor=vendor).order_by('-created_at', '-pk'))
    usage = _coupon_usage(vendor)
    store = store_orders.store_name(vendor.pk)
    return {
        'summary': _coupon_summary(coupons, usage),
        'coupons': [_coupon_json(c, *usage.get(c.pk, (0, Decimal('0'))), store=store) for c in coupons],
    }


def _one_coupon_json(profile, c):
    usage = _coupon_usage(profile.vendor, [c.pk])
    return _coupon_json(c, *usage.get(c.pk, (0, Decimal('0'))), store=store_orders.store_name(profile.vendor.pk))


def _owned_coupon(profile, pk, lock=False):
    qs = Coupon.objects.filter(pk=pk, vendor=profile.vendor)
    return (qs.select_for_update() if lock else qs).first()


def _coupon_not_found():
    return _err('Coupon nahi mila.', 404, code='not_found')


@vendor_api(['GET', 'POST'])
def api_coupons(request, profile):
    """GET  /api/vendor/coupons/   -> {summary, coupons[]} (sirf apne coupons, naya pehle; zyada se zyada 50)
    POST /api/vendor/coupons/   -> naya coupon.

    POST body: code, title?, discount_type (percent | fixed | free_delivery), value, max_discount? (percent par),
    min_order?, usage_limit?, per_customer_limit? (0 = be-had, default 1), first_order_only?, valid_from?, valid_until?
    (YYYY-MM-DD), request_key? (8-64 akshar: double tap / retry par dobara coupon na bane).
    Validation web wali `_clean_vendor_coupon` (percent max 70, code unique, tareekhein)."""
    vendor = profile.vendor
    if request.method == 'GET':
        return JsonResponse({'ok': True, **_coupons_payload(profile)})

    d = _data(request)
    rk = str(d.get('request_key') or '')
    rk = rk if _REQUEST_KEY_RE.match(rk) else ''
    done_key = lock_key = ''
    if rk:
        done_key = f'vendor_coupon_add:{vendor.pk}:{rk}'
        lock_key = done_key + ':lock'
        prev = cache.get(done_key)
        if prev:
            fresh = _owned_coupon(profile, prev)
            if fresh is not None:
                return JsonResponse({'ok': True, 'message': 'Yeh coupon pehle hi ban chuka hai.', 'duplicate': True,
                                     'coupon': _one_coupon_json(profile, fresh), **_coupons_payload(profile)})
        if not cache.add(lock_key, 1, 30):
            return _err('Coupon ban raha hai, thora intezar karein.', 409, code='in_progress')

    try:
        if Coupon.objects.filter(vendor=vendor).count() >= MAX_VENDOR_COUPONS:
            return _err(f'Zyada se zyada {MAX_VENDOR_COUPONS} coupons ho sakte hain. Purane delete karein.', 400,
                        code='limit')
        data, errors = _clean_vendor_coupon(_coupon_form(d))
        if errors:
            return _validation_err(errors)
        try:
            with transaction.atomic():
                c = Coupon.objects.create(vendor=vendor, created_by=profile.user, **data)
        except IntegrityError:
            return _validation_err(['Yeh code pehle se maujood hai, doosra code chunein'])
        except Exception:
            logger.exception('Vendor API coupon create error')
            return _err('Coupon nahi bana, dobara koshish karein.', 500, code='server')
        if done_key:
            cache.set(done_key, c.pk, 600)
    finally:
        if lock_key:
            cache.delete(lock_key)

    return JsonResponse({'ok': True, 'message': f'Coupon {c.code} ban gaya.', 'coupon': _one_coupon_json(profile, c),
                         **_coupons_payload(profile)})


@vendor_api(['POST'])
def api_coupon_edit(request, profile, pk):
    """POST /api/vendor/coupons/<id>/   (body create jaisi; `code` kabhi nahi badalta)

    Istemal ho chuke coupon par type / value / max_discount nahi badalte (customer ko jo vada kiya wahi rahe);
    baqi (title, min order, limits, tareekhein) badal sakte hain. `usage_limit` ab tak ke istemal se kam nahi ho sakta."""
    d = _data(request)
    with transaction.atomic():
        c = _owned_coupon(profile, pk, lock=True)
        if c is None:
            return _coupon_not_found()
        used_any = c.redemptions.exists()
        form = _coupon_form(d)
        form['code'] = c.code
        if used_any:
            form['discount_type'] = c.discount_type
            form['value'] = format(c.value, 'f')
            form['max_discount'] = '' if c.max_discount is None else format(c.max_discount, 'f')
        data, errors = _clean_vendor_coupon(form, exclude_pk=c.pk)
        if not errors and data['usage_limit'] is not None:
            live = c.live_redemptions().count()
            if data['usage_limit'] < live:
                errors.append(f'Kul istemal {live} se kam nahi ho sakta (itni dafa chal chuka hai)')
        if errors:
            return _validation_err(errors)
        data.pop('code', None)
        for k, v in data.items():
            setattr(c, k, v)
        c.save(update_fields=list(data.keys()))
    return JsonResponse({'ok': True, 'message': f'Coupon {c.code} update ho gaya.',
                         'coupon': _one_coupon_json(profile, c), **_coupons_payload(profile)})


@vendor_api(['POST'])
def api_coupon_toggle(request, profile, pk):
    """POST /api/vendor/coupons/<id>/toggle/   body: {active?: true|false}
    `active` dein to wahi set hota hai (retry / double tap par ulta nahi hota); na dein to ulta kar deta hai."""
    d = _data(request)
    with transaction.atomic():
        c = _owned_coupon(profile, pk, lock=True)
        if c is None:
            return _coupon_not_found()
        if 'active' in d and d.get('active') not in (None, ''):
            want = d.get('active') in COUPON_TRUE
        else:
            want = not c.is_active
        if c.is_active != want:
            c.is_active = want
            c.save(update_fields=['is_active'])
    return JsonResponse({'ok': True, 'message': f"{c.code} {'chalu' if c.is_active else 'band'} kar diya.",
                         'coupon': _one_coupon_json(profile, c), **_coupons_payload(profile)})


@vendor_api(['POST'])
def api_coupon_delete(request, profile, pk):
    """POST /api/vendor/coupons/<id>/delete/
    Istemal ho chuka coupon delete nahi hota (hisaab ka record na jaye): sirf band hota hai -> `deleted: false`.
    Coupon row lock karke check hota hai, taake isi waqt koi order redeem kare to uska record cascade mein na urre."""
    with transaction.atomic():
        c = _owned_coupon(profile, pk, lock=True)
        if c is None:
            return _coupon_not_found()
        code = c.code
        if c.redemptions.exists():
            if c.is_active:
                c.is_active = False
                c.save(update_fields=['is_active'])
            deleted = False
            msg = f'{code} istemal ho chuka hai, is liye delete nahi hua - band kar diya.'
        else:
            c.delete()
            deleted = True
            msg = f'{code} delete ho gaya.'
    payload = {'ok': True, 'message': msg, 'deleted': deleted, 'id': pk, **_coupons_payload(profile)}
    if not deleted:
        payload['coupon'] = _one_coupon_json(profile, _owned_coupon(profile, pk))
    return JsonResponse(payload)


# ================================================================
# Phase V13-B: offers (product par waqt-wala discount)
# GET/POST /api/vendor/offers/   GET .../offers/products/   POST .../<id>/   POST .../<id>/toggle/   POST .../<id>/delete/
# Product ki price / discount kabhi nahi badalti. Asar = max(product ka apna discount, offer %), sirf start-end ke andar.
# ================================================================

def _offer_not_found():
    return _err('Offer nahi mila.', 404, code='not_found')


def _owned_offer(profile, pk, lock=False):
    qs = ProductOffer.objects.filter(pk=pk, profile=profile).select_related('product', 'product__category')
    if lock:
        qs = qs.select_for_update(of=('self',))
    return qs.first()


def _parse_ymd(v):
    try:
        return datetime.strptime(str(v or '').strip(), '%Y-%m-%d').date()
    except ValueError:
        return None


def _offer_ends_on(o):
    """Aakhri din (shamil), local date."""
    return timezone.localtime(o.ends_at - timedelta(seconds=1)).date()


def _offer_share_text(o, store):
    regular, offer_price = offers_engine.prices(o.product, o.discount_percent)
    pct = f'{o.discount_percent:g}'
    return '\n'.join([
        f'🔥 {store} par offer: {o.product.name}',
        f'{pct}% off - Rs. {offer_price:,.0f} (pehle Rs. {offers_engine.base_price(o.product):,.0f})',
        f'{_offer_ends_on(o).isoformat()} tak.',
    ])


def _offer_json(o, store='', now_=None):
    p = o.product
    now_ = now_ or timezone.now()
    state = offers_engine.offer_state(o, now_)
    regular, offer_price = offers_engine.prices(p, o.discount_percent)
    days_left = None
    if state in ('live', 'scheduled'):
        days_left = max(0, (_offer_ends_on(o) - timezone.localtime(now_).date()).days + 1)
    return {
        'id': o.pk,
        'product': {'id': p.pk, 'name': p.name, 'image': _media_url(p.image),
                    'category': p.category.name if p.category_id else ''},
        'discount_percent': _money(o.discount_percent),
        'base_price': _money(offers_engine.base_price(p)),
        'regular_price': _money(regular),
        'offer_price': _money(offer_price),
        'product_discount': _money(p.discount_percentage),
        'effective': offer_price < regular,      # false: product ka apna discount offer se bara/barabar hai (offer ka asar nahi)
        'starts_on': timezone.localtime(o.starts_at).date().isoformat(),
        'ends_on': _offer_ends_on(o).isoformat(),
        'is_active': bool(o.is_active),
        'state': state,
        'days_left': days_left,
        'max_percent': _money(offers_engine.max_allowed_percent(o.profile, p)),
        'created_at': _iso(o.created_at),
        'share_text': _offer_share_text(o, store),
    }


def _offers_payload(profile):
    now_ = timezone.now()
    store = store_orders.store_name(profile.vendor.pk)
    rows = list(ProductOffer.objects.filter(profile=profile).select_related('product', 'product__category', 'profile')
                .order_by('-created_at', '-pk')[:offers_engine.MAX_VENDOR_OFFERS])
    summary = {'total': len(rows), 'max': offers_engine.MAX_VENDOR_OFFERS, 'live': 0, 'scheduled': 0, 'paused': 0, 'ended': 0}
    out = []
    for o in rows:
        j = _offer_json(o, store, now_)
        summary[j['state']] += 1
        out.append(j)
    return {'summary': summary, 'offers': out,
            'limits': {'min_percent': _money(offers_engine.MIN_OFFER_PERCENT),
                       'max_percent': _money(offers_engine.MAX_OFFER_PERCENT),
                       'max_days': offers_engine.MAX_OFFER_DAYS}}


def _one_offer_json(profile, o):
    fresh = _owned_offer(profile, o.pk)
    return _offer_json(fresh, store_orders.store_name(profile.vendor.pk)) if fresh else None


def _offer_overlap(product, starts_at, ends_at, exclude_pk=None):
    """Is product par isi dauran koi aur (chalu, abhi khatam nahi) offer?"""
    qs = ProductOffer.objects.filter(product=product, is_active=True, starts_at__lt=ends_at,
                                     ends_at__gt=max(timezone.now(), starts_at))
    if exclude_pk:
        qs = qs.exclude(pk=exclude_pk)
    return qs.exists()


def _clean_offer(profile, product, d, existing=None):
    """-> (pct, starts_at, ends_at, errors). Create aur edit dono ke liye."""
    errors = []
    try:
        pct = Decimal(str(d.get('discount_percent')).strip())
        if not pct.is_finite():
            raise ValueError
    except Exception:
        return None, None, None, ['Discount % sahi likhein (maslan 15).']
    pct = pct.quantize(Decimal('0.01'))
    cap = offers_engine.max_allowed_percent(profile, product)
    if pct < offers_engine.MIN_OFFER_PERCENT:
        errors.append(f'Discount kam az kam {offers_engine.MIN_OFFER_PERCENT:g}% hona chahiye.')
    elif pct > cap:
        if cap < offers_engine.MIN_OFFER_PERCENT:
            errors.append('Is product par offer nahi ban sakta (commission ki hadd ke baad gunjaish nahi).')
        else:
            errors.append(f'Is product par zyada se zyada {cap:g}% offer ho sakta hai.')

    today = timezone.localtime(timezone.now()).date()
    start = _parse_ymd(d.get('starts_on')) if str(d.get('starts_on') or '').strip() else (
        timezone.localtime(existing.starts_at).date() if existing else today)
    end = _parse_ymd(d.get('ends_on'))
    if start is None:
        errors.append('Shuru ki tareekh sahi nahi (YYYY-MM-DD).')
    if end is None:
        errors.append('Khatam hone ki tareekh sahi nahi (YYYY-MM-DD).')
    if errors:
        return None, None, None, errors
    if end < start:
        return None, None, None, ['Khatam ki tareekh shuru se pehle nahi ho sakti.']
    if (end - start).days + 1 > offers_engine.MAX_OFFER_DAYS:
        return None, None, None, [f'Offer zyada se zyada {offers_engine.MAX_OFFER_DAYS} din ka ho sakta hai.']
    if end < today:
        return None, None, None, ['Khatam ki tareekh guzar chuki hai.']
    if existing is None and start < today:
        return None, None, None, ['Shuru ki tareekh aaj ya baad ki rakhein.']
    if existing is not None and timezone.localtime(existing.starts_at).date() != start:
        if existing.starts_at <= timezone.now():
            return None, None, None, ['Chalu offer ki shuruaat nahi badal sakte. Sirf discount ya khatam ki tareekh badlein.']
        if start < today:
            return None, None, None, ['Shuru ki tareekh aaj ya baad ki rakhein.']
    starts_at, ends_at = offers_engine.window_from_dates(start, end)
    if existing is not None and timezone.localtime(existing.starts_at).date() == start:
        starts_at = existing.starts_at
    return pct, starts_at, ends_at, []


@vendor_api(['GET'])
def api_offer_products(request, profile):
    """GET /api/vendor/offers/products/?q=   -> offer ke liye products (sirf approved + chalu), `max_percent` ke saath."""
    q = str(request.GET.get('q') or '').strip()[:60]
    qs = Product.objects.filter(vendor=profile.vendor, approval_status='approved', is_active=True).select_related('category')
    if q:
        qs = qs.filter(Q(name__icontains=q) | Q(barcode__icontains=q))
    rows = list(qs.order_by('name')[:50])
    now_ = timezone.now()
    busy = set(ProductOffer.objects.filter(product__in=rows, is_active=True, ends_at__gt=now_)
               .values_list('product_id', flat=True))
    out = []
    for p in rows:
        out.append({
            'id': p.pk, 'name': p.name, 'image': _media_url(p.image),
            'category': p.category.name if p.category_id else '',
            'base_price': _money(offers_engine.base_price(p)),
            'regular_price': _money(offers_engine.prices(p, 0)[0]),
            'product_discount': _money(p.discount_percentage),
            'max_percent': _money(offers_engine.max_allowed_percent(profile, p)),
            'has_offer': p.pk in busy,
        })
    return JsonResponse({'ok': True, 'products': out})


@vendor_api(['GET', 'POST'])
def api_offers(request, profile):
    """GET  /api/vendor/offers/   -> {summary, offers[], limits} (sirf apne, naya pehle)
    POST /api/vendor/offers/   -> naya offer: product_id, discount_percent, starts_on? (YYYY-MM-DD, default aaj),
    ends_on (YYYY-MM-DD, shamil), request_key? (8-64 akshar: double tap / retry par dobara offer na bane).
    Offer sirf approved product par; us din tak jis din ends_on hai. Product ki asli price nahi badalti."""
    vendor = profile.vendor
    if request.method == 'GET':
        return JsonResponse({'ok': True, **_offers_payload(profile)})

    d = _data(request)
    rk = str(d.get('request_key') or '')
    rk = rk if _REQUEST_KEY_RE.match(rk) else ''
    done_key = lock_key = ''
    if rk:
        done_key = f'vendor_offer_add:{vendor.pk}:{rk}'
        lock_key = done_key + ':lock'
        prev = cache.get(done_key)
        if prev:
            fresh = _owned_offer(profile, prev)
            if fresh is not None:
                return JsonResponse({'ok': True, 'message': 'Yeh offer pehle hi ban chuka hai.', 'duplicate': True,
                                     'offer': _one_offer_json(profile, fresh), **_offers_payload(profile)})
        if not cache.add(lock_key, 1, 30):
            return _err('Offer ban raha hai, thora intezar karein.', 409, code='in_progress')

    try:
        try:
            pid = int(d.get('product_id'))
        except (TypeError, ValueError):
            return _validation_err(['Product chunein.'])
        if ProductOffer.objects.filter(profile=profile).count() >= offers_engine.MAX_VENDOR_OFFERS:
            return _err(f'Zyada se zyada {offers_engine.MAX_VENDOR_OFFERS} offers ho sakte hain. Purane delete karein.', 400,
                        code='limit')
        try:
            with transaction.atomic():
                product = Product.objects.select_for_update().filter(pk=pid, vendor=vendor).first()
                if product is None:
                    return _err('Product nahi mila.', 404, code='not_found')
                if product.approval_status != 'approved' or not product.is_active:
                    return _validation_err(['Offer sirf approved aur chalu product par lag sakta hai.'])
                pct, starts_at, ends_at, errors = _clean_offer(profile, product, d)
                if errors:
                    return _validation_err(errors)
                if _offer_overlap(product, starts_at, ends_at):
                    return _err('Is product par isi dauran pehle se offer hai. Pehle usay badlein ya band karein.', 409,
                                code='overlap')
                o = ProductOffer.objects.create(product=product, profile=profile, discount_percent=pct,
                                                starts_at=starts_at, ends_at=ends_at, request_key=rk)
        except Exception:
            logger.exception('Vendor API offer create error')
            return _err('Offer nahi bana, dobara koshish karein.', 500, code='server')
        if done_key:
            cache.set(done_key, o.pk, 600)
    finally:
        if lock_key:
            cache.delete(lock_key)

    return JsonResponse({'ok': True, 'message': 'Offer ban gaya.', 'offer': _one_offer_json(profile, o),
                         **_offers_payload(profile)})


@vendor_api(['POST'])
def api_offer_edit(request, profile, pk):
    """POST /api/vendor/offers/<id>/   body: discount_percent, ends_on, starts_on? (product nahi badalta).
    Khatam offer nahi badalta. Chalu offer ki shuruaat nahi badalti."""
    d = _data(request)
    with transaction.atomic():
        o = _owned_offer(profile, pk, lock=True)
        if o is None:
            return _offer_not_found()
        if o.ends_at <= timezone.now():
            return _err('Khatam offer badal nahi sakte. Naya offer banayein.', 409, code='ended')
        product = o.product
        pct, starts_at, ends_at, errors = _clean_offer(profile, product, d, existing=o)
        if errors:
            return _validation_err(errors)
        if o.is_active and _offer_overlap(product, starts_at, ends_at, exclude_pk=o.pk):
            return _err('Is product par isi dauran doosra offer hai.', 409, code='overlap')
        o.discount_percent, o.starts_at, o.ends_at = pct, starts_at, ends_at
        o.save(update_fields=['discount_percent', 'starts_at', 'ends_at', 'updated_at'])
    return JsonResponse({'ok': True, 'message': 'Offer update ho gaya.', 'offer': _one_offer_json(profile, o),
                         **_offers_payload(profile)})


@vendor_api(['POST'])
def api_offer_toggle(request, profile, pk):
    """POST /api/vendor/offers/<id>/toggle/   body: {active?: true|false}   (na ho to ulta)."""
    d = _data(request)
    with transaction.atomic():
        o = _owned_offer(profile, pk, lock=True)
        if o is None:
            return _offer_not_found()
        want = (not o.is_active) if 'active' not in d else (d.get('active') in COUPON_TRUE)
        if want and o.ends_at <= timezone.now():
            return _err('Khatam offer dobara chalu nahi ho sakta. Naya offer banayein.', 409, code='ended')
        if want and _offer_overlap(o.product, o.starts_at, o.ends_at, exclude_pk=o.pk):
            return _err('Is product par isi dauran doosra offer chalu hai.', 409, code='overlap')
        if o.is_active != want:
            o.is_active = want
            o.save(update_fields=['is_active', 'updated_at'])
    return JsonResponse({'ok': True, 'message': 'Offer chalu ho gaya.' if want else 'Offer band ho gaya.',
                         'offer': _one_offer_json(profile, o), **_offers_payload(profile)})


@vendor_api(['POST'])
def api_offer_delete(request, profile, pk):
    """POST /api/vendor/offers/<id>/delete/   Offer ka hisaab kahin nahi jata (orders mein price pehle hi likhi hoti hai), isliye asli delete."""
    with transaction.atomic():
        o = _owned_offer(profile, pk, lock=True)
        if o is None:
            return _offer_not_found()
        o.delete()
    return JsonResponse({'ok': True, 'message': 'Offer delete ho gaya.', 'deleted': True, 'id': pk,
                         **_offers_payload(profile)})



# ================================================================
# Phase V14 - Reviews & ratings
# Naya business logic nahi: OrderReview (customer ki rating) aur jawab save karne ki logic web portal wali hi hai.
# ================================================================

REVIEWS_PAGE_SIZE = 20
REVIEW_FILTERS = ('all', 'unanswered', 'replied')


def _rated_reviews(vendor):
    """Sirf wo reviews jin mein store ko star diye gaye (rider-only rating is vendor ki nahi)."""
    return OrderReview.objects.filter(vendor=vendor, vendor_rating__isnull=False)


def _reviews_summary(vendor):
    """{avg, count, replied, unanswered, bars[5..1]} - filter se alag, hamesha poore reviews ka hisaab."""
    base = _rated_reviews(vendor)
    stars = {r['vendor_rating']: r['n'] for r in base.order_by().values('vendor_rating').annotate(n=Count('id'))}
    count = sum(stars.values())
    unanswered = base.filter(vendor_reply='').count()
    avg = round(sum(k * v for k, v in stars.items()) / count, 1) if count else None
    return {
        'avg': avg,
        'count': count,
        'replied': count - unanswered,
        'unanswered': unanswered,
        'bars': [{'stars': i, 'count': stars.get(i, 0), 'pct': round(stars.get(i, 0) * 100 / count) if count else 0}
                 for i in (5, 4, 3, 2, 1)],
    }


def _review_json(rv):
    return {
        'id': rv.pk,
        'order_id': rv.sale_order_id,
        'order_no': rv.sale_order.order_no,
        'stars': int(rv.vendor_rating or 0),
        'comment': rv.vendor_comment or '',
        'name': _reviewer_name(rv.sale_order),
        'created_at': _iso(rv.created_at),
        'reply': rv.vendor_reply or '',
        'replied_at': _iso(rv.vendor_replied_at),
    }


@vendor_api(['GET'])
def api_reviews(request, profile):
    """GET /api/vendor/reviews/?filter=all|unanswered|replied&stars=1..5&page=1

    -> {summary: {avg, count, replied, unanswered, bars[]}, reviews[] (naya pehle, 20 ka page), has_more, max_reply_len}
    Sirf is vendor ke reviews. Summary / bars filter se alag (hamesha poore). Customer ka naam 'Hadi A.' (privacy).
    Ghalat filter -> 'all', ghalat stars -> sab stars.
    """
    vendor = profile.vendor
    flt = request.GET.get('filter', 'all')
    if flt not in REVIEW_FILTERS:
        flt = 'all'
    try:
        stars = int(request.GET.get('stars') or 0)
    except (TypeError, ValueError):
        stars = 0
    if not 1 <= stars <= 5:
        stars = 0
    page = _parse_page(request.GET.get('page'))

    qs = _rated_reviews(vendor)
    if flt == 'unanswered':
        qs = qs.filter(vendor_reply='')
    elif flt == 'replied':
        qs = qs.exclude(vendor_reply='')
    if stars:
        qs = qs.filter(vendor_rating=stars)
    qs = qs.select_related('sale_order__customer').order_by('-created_at', '-pk')
    start = (page - 1) * REVIEWS_PAGE_SIZE
    rows = list(qs[start:start + REVIEWS_PAGE_SIZE + 1])
    has_more = len(rows) > REVIEWS_PAGE_SIZE
    rows = rows[:REVIEWS_PAGE_SIZE]

    return JsonResponse({
        'ok': True,
        'generated_at': now().isoformat(),
        'filter': flt,
        'stars': stars,
        'page': page,
        'has_more': has_more,
        'summary': _reviews_summary(vendor),
        'reviews': [_review_json(rv) for rv in rows],
        'max_reply_len': MAX_REPLY_LEN,
    })


@vendor_api(['POST'])
def api_review_reply(request, profile, pk):
    """POST /api/vendor/reviews/<id>/reply/   body: {reply: '...'}

    Jawab dein ya badlein; khali `reply` = jawab hata dein. Zyada se zyada 300 akshar (is se lamba -> 400, chupke kaat nahi dete).
    Doosre vendor ka review (ya jis mein store ki rating hi nahi) -> 404.
    """
    raw = _data(request).get('reply')
    if raw is not None and not isinstance(raw, str):
        return _err('Jawab sirf text ho sakta hai.', 400, code='validation')
    text = (raw or '').strip()
    if len(text) > MAX_REPLY_LEN:
        return _err(f'Jawab zyada se zyada {MAX_REPLY_LEN} akshar ka ho sakta hai (abhi {len(text)}).', 400, code='too_long')
    with transaction.atomic():
        rv = _rated_reviews(profile.vendor).select_for_update().filter(pk=pk).first()
        if rv is None:
            return _err('Review nahi mila.', 404, code='not_found')
        saved = save_vendor_reply(rv, text)
    return JsonResponse({
        'ok': True,
        'message': 'Jawab save ho gaya.' if saved else 'Jawab hata diya.',
        'review': _review_json(rv),
        'summary': _reviews_summary(profile.vendor),
    })


# ================================================================
# Phase V15 - Store settings (basic / timing / delivery / branding) + location verify (blue tick)
# Naya business logic nahi: validation web ke `vendor_store_settings` / `vendor_location_verify` wali hi hai
# (`_parse_time`, `_parse_money`, `_areas_from_post`, `_validate_image`, `parse_coords`). Har section alag save hota hai
# (ek section ki ghalti doosre ko nahi roakti). Sirf apna profile badalta hai (token se). Koi migration nahi.
# ================================================================

STORE_SECTIONS = ('basic', 'timing', 'delivery', 'branding')
STORE_STATUSES = ('open', 'busy', 'closed')
STORE_DESC_MAX = 1000
DELIVERY_MINUTES = (5, 600)
STORE_MONEY_MAX = Decimal('99999.99')


def _store_text(v):
    """JSON value -> text (None -> ''); number ho to text; list/dict/bool ghalat (None wapas = ghalat)."""
    if v is None:
        return ''
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return v.strip()
    return None


def _area_groups(profile):
    """Admin ki list: [{city, areas: [{label, selected}]}] + vendor ke apne likhe (list mein na hone wale) areas."""
    chosen = VendorProfile.clean_areas(profile.delivery_areas)
    chosen_l = {a.lower() for a in chosen}
    groups = DeliveryArea.grouped()
    listed = {a.label.lower() for _, items in groups for a in items}
    return (
        [{'city': city, 'areas': [{'label': a.label, 'selected': a.label.lower() in chosen_l} for a in items]}
         for city, items in groups],
        [a for a in chosen if a.lower() not in listed],
        chosen,
    )


def _location_json(profile):
    return {
        'verified': bool(profile.location_verified),
        'has_location': bool(profile.has_location),
        'latitude': profile.latitude,
        'longitude': profile.longitude,
        'accuracy_m': profile.location_accuracy_m,
        'verified_at': _iso(profile.location_verified_at),
        'max_accuracy_m': int(max_accuracy_m()),
    }


def _store_settings_json(profile):
    groups, extra, chosen = _area_groups(profile)
    cat = profile.store_category
    return {
        'name': profile.business_name,
        'city': profile.city or '',
        'description': profile.store_description or '',
        'category': ({'id': cat.pk, 'name': cat.name} if cat else None),
        'status': profile.store_status,
        'opens_at': _hhmm(profile.opens_at),
        'closes_at': _hhmm(profile.closes_at),
        'min_order_amount': _money(profile.min_order_amount),
        'delivery_fee': _money(profile.delivery_fee),
        'delivery_time_min': profile.delivery_time_min,
        'delivery_time_max': profile.delivery_time_max,
        'areas': chosen,
        'area_groups': groups,
        'areas_extra': extra,
        'logo': _media_url(profile.logo),
        'cover': _media_url(profile.cover_image),
        'location': _location_json(profile),
    }


def _store_response(profile, message):
    return JsonResponse({
        'ok': True,
        'message': message,
        'settings': _store_settings_json(profile),
        'store': _store_json(profile),
        'vendor': _vendor_json(profile),
    })


def _store_form_error(errors):
    return JsonResponse({'ok': False, 'error': errors[0], 'message': errors[0], 'code': 'validation',
                         'errors': errors}, status=400)


def _store_minutes(d, key, current, label, errors):
    raw = d.get(key)
    if raw is None or raw == '':
        return current
    if isinstance(raw, bool) or not isinstance(raw, (int, str)):
        errors.append(f'{label} minutes mein likhein.')
        return current
    try:
        v = int(str(raw).strip())
    except ValueError:
        errors.append(f'{label} minutes mein likhein.')
        return current
    lo, hi = DELIVERY_MINUTES
    if not lo <= v <= hi:
        errors.append(f'{label} {lo} se {hi} minute ke beech likhein.')
        return current
    return v


def _store_money(d, key, current, label, errors):
    if key not in d:
        return current
    text = _store_text(d.get(key))
    if text is None:
        errors.append(f'{label} sahi likhein')
        return current
    return _parse_money(text, label, errors, maximum=STORE_MONEY_MAX)


def _apply_basic(profile, d, request, errors):
    fields = []
    if 'status' in d:
        status = _store_text(d.get('status'))
        if status not in STORE_STATUSES:
            errors.append('Store status open, busy ya closed hona chahiye.')
        else:
            profile.store_status = status
            fields.append('store_status')
    if 'description' in d:
        text = d.get('description')
        text = '' if text is None else text
        if not isinstance(text, str):
            errors.append('Store ki tafseel sirf text ho sakti hai.')
        elif len(text.strip()) > STORE_DESC_MAX:
            errors.append(f'Store ki tafseel zyada se zyada {STORE_DESC_MAX} akshar ki ho sakti hai (abhi {len(text.strip())}).')
        else:
            profile.store_description = text.strip()
            fields.append('store_description')
    if 'store_category' in d:
        raw = _store_text(d.get('store_category'))
        if raw in ('', '0'):
            profile.store_category = None
            fields.append('store_category')
        else:
            cat = StoreCategory.objects.filter(pk=raw, is_active=True).first() if raw and raw.isdigit() else None
            if cat is None:
                errors.append('Store category sahi chunein.')
            else:
                profile.store_category = cat
                fields.append('store_category')
    return fields


def _apply_timing(profile, d, request, errors):
    opens_raw, closes_raw = _store_text(d.get('opens_at')), _store_text(d.get('closes_at'))
    if opens_raw is None or closes_raw is None:
        errors.append('Opening/closing time sahi likhein.')
        return []
    try:
        opens_at, closes_at = _parse_time(opens_raw), _parse_time(closes_raw)
    except (ValueError, TypeError):
        errors.append('Opening/closing time sahi likhein (jaise 09:00).')
        return []
    if bool(opens_at) != bool(closes_at):
        errors.append('Opening aur closing dono time likhein (ya dono khali chhoden).')
        return []
    profile.opens_at, profile.closes_at = opens_at, closes_at
    return ['opens_at', 'closes_at']


def _apply_delivery(profile, d, request, errors):
    fields = []
    min_order = _store_money(d, 'min_order_amount', profile.min_order_amount, 'Minimum order', errors)
    fee = _store_money(d, 'delivery_fee', profile.delivery_fee, 'Delivery fee', errors)
    t_min = _store_minutes(d, 'delivery_time_min', profile.delivery_time_min, 'Delivery time (kam se kam)', errors)
    t_max = _store_minutes(d, 'delivery_time_max', profile.delivery_time_max, 'Delivery time (zyada se zyada)', errors)
    if t_min > t_max:
        errors.append('Delivery time: kam se kam, zyada se zyada se chhota ya barabar hona chahiye.')
    if 'areas' in d or 'areas_extra' in d:
        picks, extra = d.get('areas'), d.get('areas_extra')
        picks = [] if picks is None else picks
        extra = '' if extra is None else extra
        if not isinstance(picks, list) or not all(isinstance(a, str) for a in picks) or not isinstance(extra, str):
            errors.append('Delivery areas ki list sahi nahi.')
        else:
            q = QueryDict(mutable=True)
            q['areas_mode'] = 'pick'
            q.setlist('delivery_areas_pick', picks)
            q['delivery_areas_extra'] = extra
            raw_areas = _areas_from_post(q)           # sirf admin ki list wale + vendor ke apne likhe areas (web jaisa)
            too_many = len([x for x in raw_areas.replace('\n', ',').replace(';', ',').split(',') if x.strip()])
            if too_many > VendorProfile.MAX_AREAS:
                errors.append(f'Zyada se zyada {VendorProfile.MAX_AREAS} areas likh sakte hain.')
            else:
                profile.delivery_areas = ', '.join(VendorProfile.clean_areas(raw_areas))
                fields.append('delivery_areas')
    if errors:
        return []
    profile.min_order_amount, profile.delivery_fee = min_order, fee
    profile.delivery_time_min, profile.delivery_time_max = t_min, t_max
    return fields + ['min_order_amount', 'delivery_fee', 'delivery_time_min', 'delivery_time_max']


def _apply_branding(profile, d, request, errors):
    fields = []
    logo, cover = request.FILES.get('logo'), request.FILES.get('cover_image')
    for f in (logo, cover):
        if f:
            err = _validate_image(f)
            if err:
                errors.append(err)
    if errors:
        return []
    flag = lambda k: str(d.get(k, '')).strip().lower() in ('1', 'true', 'yes', 'on')
    if logo:
        profile.logo = logo
        fields.append('logo')
    elif flag('remove_logo'):
        profile.logo = None
        fields.append('logo')
    if cover:
        profile.cover_image = cover
        fields.append('cover_image')
    elif flag('remove_cover'):
        profile.cover_image = None
        fields.append('cover_image')
    if not fields:
        errors.append('Koi nayi photo chunein ya hatane ka nishan lagayein.')
    return fields


_STORE_APPLY = {'basic': _apply_basic, 'timing': _apply_timing, 'delivery': _apply_delivery, 'branding': _apply_branding}
_STORE_DONE = {
    'basic': 'Store ki bunyadi maloomat save ho gayin.',
    'timing': 'Store ka waqt save ho gaya.',
    'delivery': 'Delivery ki settings save ho gayin.',
    'branding': 'Logo / banner save ho gaya.',
}


@vendor_api(['GET', 'POST'])
def api_store(request, profile):
    """GET  /api/vendor/store/   -> poori store settings (+ category list, limits).
    POST /api/vendor/store/   body: {section: basic|timing|delivery|branding, ...us section ke fields}

    basic    : status (open|busy|closed), description (<=1000), store_category (id ya khali)
    timing   : opens_at, closes_at ('HH:MM'; dono khali = hamesha khula; raat paar wala time bhi theek)
    delivery : min_order_amount, delivery_fee, delivery_time_min, delivery_time_max (5-600), areas [labels], areas_extra 'text'
    branding : multipart - logo, cover_image (file), remove_logo / remove_cover (1)
    Jo field na bheji jaye wo badalti nahi. Har section alag save; ghalti par kuch bhi save nahi hota (400 + errors).
    """
    if request.method == 'GET':
        return JsonResponse({
            'ok': True,
            'generated_at': now().isoformat(),
            'settings': _store_settings_json(profile),
            'store': _store_json(profile),
            'categories': [{'id': c.pk, 'name': c.name} for c in StoreCategory.objects.filter(is_active=True)],
            'limits': {
                'description_max': STORE_DESC_MAX,
                'max_areas': VendorProfile.MAX_AREAS,
                'minutes_min': DELIVERY_MINUTES[0],
                'minutes_max': DELIVERY_MINUTES[1],
                'money_max': float(STORE_MONEY_MAX),
                'image_max_mb': MAX_IMAGE_BYTES // (1024 * 1024),
            },
        })

    d = _data(request)
    section = _store_text(d.get('section')) if hasattr(d, 'get') else ''
    if section not in STORE_SECTIONS:
        return _err('Section sahi nahi (basic, timing, delivery ya branding).', 400, code='validation')
    errors = []
    with transaction.atomic():
        locked = VendorProfile.objects.select_for_update().select_related('user', 'vendor', 'store_category').get(pk=profile.pk)
        fields = _STORE_APPLY[section](locked, d, request, errors)
        if errors:
            return _store_form_error(errors)
        if fields:
            locked.save(update_fields=sorted(set(fields)))
            logger.info('Vendor %s store settings (%s) saved (app)', locked.pk, section)
    return _store_response(locked, _STORE_DONE[section])


@vendor_api(['POST'])
def api_store_location(request, profile):
    """POST /api/vendor/store/location/   body: {lat, lng, accuracy, consent: true}

    Store ki location verify (blue tick). Rules web `vendor_location_verify` jaise: vendor ka ittefaq (consent) zaroori,
    sahi coordinates, GPS ghalti `max_accuracy_m` (default 500 m) se zyada na ho. Sirf location wale naye columns badalte hain.
    """
    d = _data(request)
    consent = d.get('consent') if hasattr(d, 'get') else None
    if str(consent).strip().lower() not in ('1', 'true', 'yes', 'on'):
        return _err('Location lene se pehle aap ka ittefaq (agree) zaroori hai.', 400, code='consent')
    lat, lng, acc, err = parse_coords(request)
    if err:
        return _err(err, 400, code='validation')
    if acc is not None and acc > max_accuracy_m():
        return _err('Location sahi tarah nahi aayi (ghalti %d meter). Store ke andar phone ka GPS/Location on kar '
                    'ke dobara koshish karein.' % acc, 400, code='accuracy')
    with transaction.atomic():
        locked = VendorProfile.objects.select_for_update().select_related('user', 'vendor', 'store_category').get(pk=profile.pk)
        locked.latitude, locked.longitude, locked.location_accuracy_m = lat, lng, acc
        locked.location_consent_at = now()
        locked.location_verified = True
        locked.location_verified_at = now()
        locked.save(update_fields=['latitude', 'longitude', 'location_accuracy_m', 'location_consent_at',
                                   'location_verified', 'location_verified_at'])
        logger.info('Vendor %s store location verified (app)', locked.pk)
    return _store_response(locked, 'Aap ke store ki location verify ho gayi. Ab store naam ke saath blue tick nazar aayega.')


# ================================================================
# Phase V16 - Profile, password, account delete, help
# Naya business logic nahi: account delete web `delete_account_vendor` ke rules par (shared `wipe_vendor_account`),
# password lockout web login / rider API jaisa. Koi migration nahi.
# ================================================================

PROFILE_NAME_MIN, PROFILE_NAME_MAX = 3, 100
PROFILE_CITY_MAX = 100
PROFILE_ADDRESS_MIN, PROFILE_ADDRESS_MAX = 10, 500
PROFILE_EMAIL_MAX = 100
PASSWORD_MIN, PASSWORD_MAX = 6, 128


def _owner_name(user):
    return ' '.join(p for p in (user.first_name, user.last_name) if p).strip()


def _open_orders_count(vendor):
    from .views_account_deletion import ACTIVE_ORDER_STATUSES
    return SaleOrder.objects.filter(vendor=vendor, status__in=ACTIVE_ORDER_STATUSES).count()


def _support_json(request, profile):
    """Madad: company ka phone / email, WhatsApp link, privacy policy + account delete ke public pages."""
    company = None
    try:
        company = CompanyInfo.objects.first()
    except Exception:
        company = None
    text = (f"Assalam o Alaikum! Main {profile.business_name} ka vendor hoon "
            f"(phone {profile.vendor.contact_number or ''}). Mujhe madad chahiye.")
    try:
        wa = build_whatsapp_link(company, text) if company else ''
    except Exception:
        wa = ''
    return {
        'name': (getattr(company, 'name', '') or '') if company else '',
        'phone': (getattr(company, 'contact_number', '') or '') if company else '',
        'email': (getattr(company, 'email', '') or '') if company else '',
        'whatsapp_url': wa,
        'privacy_url': request.build_absolute_uri(reverse('privacy_policy')),
        'delete_url': request.build_absolute_uri(reverse('delete_account_info')),
    }


def _profile_full_json(request, profile):
    user, v = profile.user, profile.vendor
    open_orders = _open_orders_count(v)
    return {
        'store_name': profile.business_name,
        'owner_name': _owner_name(user),
        'phone': v.contact_number or '',          # login ID hai - yahan se badalta nahi
        'email': user.email or '',
        'city': profile.city or '',
        'address': v.address or '',
        'approved': bool(profile.is_approved),
        'commission_percent': float(commission_percent(profile)),
        'joined': _iso(profile.created_at),
        'last_login': _iso(profile.last_login_at),
        'logo': _media_url(profile.logo),
        'open_orders': open_orders,
        'can_delete': open_orders == 0,
    }


def _profile_response(request, profile, message=''):
    out = {'ok': True, 'profile': _profile_full_json(request, profile), 'vendor': _vendor_json(profile),
           'support': _support_json(request, profile)}
    if message:
        out['message'] = message
    return JsonResponse(out)


@vendor_api(['GET', 'POST'])
def api_profile(request, profile):
    """GET/POST /api/vendor/profile/

    GET : profile + madad (support phone / WhatsApp / privacy policy / account delete page).
    POST: owner_name, email, city, address mein se jo bheje wohi badalta hai (baqi waise hi). Phone login ID hai aur store ka
          naam hisaab ke records se juda hai - dono yahan se nahi badalte. Ghalti par 400 `errors` ki list ke saath, kuch save nahi hota.
    """
    if request.method == 'GET':
        return _profile_response(request, profile)

    d = _data(request)
    errors = []
    new = {}

    if 'owner_name' in d:
        name = _store_text(d.get('owner_name'))
        name = ' '.join((name or '').split())
        if len(name) < PROFILE_NAME_MIN:
            errors.append(f'Apna poora naam likhein (kam az kam {PROFILE_NAME_MIN} harf).')
        elif len(name) > PROFILE_NAME_MAX:
            errors.append(f'Naam zyada se zyada {PROFILE_NAME_MAX} harf ka ho sakta hai.')
        else:
            new['owner_name'] = name
    if 'email' in d:
        email = (_store_text(d.get('email')) or '').strip()
        try:
            if not email or len(email) > PROFILE_EMAIL_MAX:
                raise ValidationError('x')
            validate_email(email)
        except ValidationError:
            errors.append('Sahi email address likhein.')
        else:
            if User.objects.filter(email__iexact=email).exclude(pk=profile.user_id).exists():
                errors.append('Ye email pehle se kisi aur account par hai.')
            else:
                new['email'] = email
    if 'city' in d:
        city = ' '.join((_store_text(d.get('city')) or '').split())
        if not city:
            errors.append('City likhein.')
        elif len(city) > PROFILE_CITY_MAX:
            errors.append(f'City zyada se zyada {PROFILE_CITY_MAX} harf ki ho sakti hai.')
        else:
            new['city'] = city
    if 'address' in d:
        address = (_store_text(d.get('address')) or '').strip()
        if len(address) < PROFILE_ADDRESS_MIN:
            errors.append(f'Poora address likhein (kam az kam {PROFILE_ADDRESS_MIN} harf).')
        elif len(address) > PROFILE_ADDRESS_MAX:
            errors.append(f'Address zyada se zyada {PROFILE_ADDRESS_MAX} harf ka ho sakta hai.')
        else:
            new['address'] = address
    if errors:
        return _validation_err(errors)
    if not new:
        return _err('Kuch badalne ko nahi diya (naam, email, city ya address).')

    with transaction.atomic():
        locked = (VendorProfile.objects.select_for_update()
                  .select_related('user', 'vendor').get(pk=profile.pk))
        user, vendor = locked.user, locked.vendor
        if 'owner_name' in new:
            parts = new['owner_name'].split()
            user.first_name, user.last_name = parts[0][:150], ' '.join(parts[1:])[:150]
        if 'email' in new:
            user.email = new['email']
        if 'owner_name' in new or 'email' in new:
            user.save(update_fields=[f for f, k in (('first_name', 'owner_name'), ('last_name', 'owner_name'),
                                                    ('email', 'email')) if k in new])
        if 'city' in new:
            locked.city = new['city']
            locked.save(update_fields=['city'])
        if 'address' in new:
            vendor.address = new['address']
            vendor.save(update_fields=['address'])
    return _profile_response(request, locked, 'Profile update ho gaya.')


@vendor_api(['POST'])
def api_password(request, profile):
    """POST /api/vendor/password/   body: {old_password, new_password, push_token?}

    Naya token wapis milta hai (is phone ke liye). Token mein password ka hissa hota hai, is liye doosre phone ke purane
    token khud band ho jate hain (unka agla call 401 -> login screen). Un phones ke push token bhi server se hat jate hain
    (logout hue phone par alert na aaye); is phone ka `push_token` bheja ho to wo rehta hai.
    Lockout: 5 galat purane password -> 10 minute (web login jaisa).
    """
    d = _data(request)
    old, new = d.get('old_password') or '', d.get('new_password') or ''
    if not old or not new or not isinstance(old, str) or not isinstance(new, str):
        return _err('Purana aur naya password dono likhein.')
    key = f'vendor_api_pw:{profile.pk}'
    if cache.get(key, 0) >= LOGIN_MAX_ATTEMPTS:
        return _err('Bohat zyada koshishen. 10 minute baad dobara try karein.', 429, code='locked')
    user = profile.user
    if not user.check_password(old):
        cache.set(key, cache.get(key, 0) + 1, LOGIN_LOCK_SECONDS)
        return _err('Purana password ghalat hai.', 401, code='bad_password')
    if len(new) < PASSWORD_MIN:
        return _err(f'Naya password kam az kam {PASSWORD_MIN} harf ka ho.')
    if len(new) > PASSWORD_MAX:
        return _err('Naya password bohat lamba hai.')
    if new == old:
        return _err('Naya password purane se alag ho.')
    keep = str(d.get('push_token') or '').strip()
    with transaction.atomic():
        user.set_password(new)
        user.save(update_fields=['password'])
        others = VendorPushToken.objects.filter(profile=profile)
        if keep:
            others = others.exclude(token=keep)
        others.delete()
    cache.delete(key)
    return JsonResponse({'ok': True, 'message': 'Password badal gaya. Doosre phones par dobara login karna hoga.',
                         'token': _make_token(profile)})


@vendor_api(['POST'])
def api_account_delete(request, profile):
    """POST /api/vendor/account/delete/   body: {password, confirm: true}

    Rules web `delete_account_vendor` jaise: password dobara (5 galat -> 10 minute, web ke saath ek hi counter), tick
    (confirm), koi order chal raha ho to nahi. Phir store + personal data saaf, products chhup jate hain, login band
    (profile row hisaab ke liye rehti hai), push token hat jate hain. Ye wapas nahi hota.
    """
    d = _data(request)
    user = profile.user
    tries_key = f'delete_account:{user.pk}'          # web wala hi counter
    if cache.get(tries_key, 0) >= DELETE_MAX_TRIES:
        return _err('Bohat zyada ghalat koshishen. 10 minute baad dobara try karein.', 429, code='locked')
    if str(d.get('confirm')).strip().lower() not in ('1', 'true', 'yes', 'on'):
        return _err('Account delete karne ke liye tasdeeq (confirm) zaroori hai.', 400, code='confirm')
    password = d.get('password') or ''
    if not password or not isinstance(password, str) or not user.check_password(password):
        cache.set(tries_key, cache.get(tries_key, 0) + 1, DELETE_LOCK_SECONDS)
        return _err('Password ghalat hai. Account delete nahi hua.', 401, code='bad_password')
    cache.delete(tries_key)
    try:
        with transaction.atomic():
            locked = VendorProfile.objects.select_for_update().select_related('user', 'vendor').get(pk=profile.pk)
            if vendor_has_active_orders(locked.vendor):
                return _err('Abhi aap ke store ke orders chal rahe hain. Pehle unhein mukammal ya reject karein, phir '
                            'account delete karein.', 409, code='open_orders')
            wipe_vendor_account(locked.user)
    except Exception:
        logger.exception('Vendor app account delete failed')
        return _err('Kuch masla aa gaya. Account delete nahi hua - support se rabta karein.', 500, code='error')
    logger.info('Vendor %s account deleted (app)', profile.pk)
    return JsonResponse({'ok': True, 'message': 'Aap ka vendor account aur store ka data hata diya gaya hai.'})

