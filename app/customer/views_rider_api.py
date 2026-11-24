"""
Rider Android app ke liye JSON API (token login).

Phase 3: dashboard / history / order detail / profile / password API (neeche, file ke aakhir mein).
Phase 1: Cash handover ke liye nayi table RiderCashHandover (migration 0058, additive) aur 3 nayi API
(wallet, cash/handover, cash/handovers). Purani API / JSON keys waise hi hain.
Token Django ke signing se banta hai (30 din chalta hai;
rider ka password badalne par purane token khud band ho jate hain).
Logic wahi hai jo views_rider_portal.py ka hai - bas JSON mein.

Header:  Authorization: Bearer <token>
"""
import json
import logging
from datetime import timedelta
from decimal import Decimal
from functools import wraps

from django.contrib.auth import authenticate
from django.core import signing
from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.db.models import Count, Sum
from django.db.models.functions import Coalesce, TruncDate
from django.http import JsonResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.utils.timezone import now
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from ..models import (DeliveryInfo, OrderReview, OrderTracking, RiderCashHandover, RiderProfile,
                      RiderPushToken, SaleOrder, Vendor, VendorProfile)
from . import store_orders
from .views_customer_auth import get_client_ip, normalize_phone
from .views_rider_portal import (
    ACTIVE_STATUSES, LOGIN_LOCK_SECONDS, LOGIN_MAX_ATTEMPTS, MAX_ACTIVE_ORDERS, TRACK_STATUSES,
    _assign, _offers_qs, _touch, _track, _vendor_user, period_stats, rider_balances,
    save_rider_location,
)
from .views_reviews import rider_rating

logger = logging.getLogger(__name__)

TOKEN_SALT = 'rider-api-v1'
TOKEN_MAX_AGE = 30 * 24 * 3600


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


def _make_token(rider):
    return signing.dumps({'rid': rider.pk, 'pv': (rider.user.password or '')[-12:]}, salt=TOKEN_SALT)


def _rider_from_request(request):
    auth = request.META.get('HTTP_AUTHORIZATION', '')
    if not auth.lower().startswith('bearer '):
        return None
    try:
        payload = signing.loads(auth[7:].strip(), salt=TOKEN_SALT, max_age=TOKEN_MAX_AGE)
    except signing.BadSignature:
        return None
    rider = RiderProfile.objects.select_related('user').filter(pk=payload.get('rid'), is_active=True).first()
    if not rider or (rider.user.password or '')[-12:] != payload.get('pv'):
        return None
    return rider


def rider_api(methods):
    """csrf_exempt + method check + token check. View ko (request, rider, ...) milta hai."""
    def deco(view):
        @csrf_exempt
        @require_http_methods(methods)
        @wraps(view)
        def wrapper(request, *args, **kwargs):
            rider = _rider_from_request(request)
            if rider is None:
                return JsonResponse({'ok': False, 'error': 'auth', 'message': 'Dobara login karein'}, status=401)
            return view(request, rider, *args, **kwargs)
        return wrapper
    return deco


def _money(v):
    return float(Decimal(v or 0))


def _profile(rider):
    b = rider_balances(rider)
    t = period_stats(rider, timezone.localdate())
    return {
        'id': rider.pk, 'name': rider.name, 'phone': rider.phone, 'vehicle': rider.vehicle,
        'online': rider.is_online, 'fee': _money(rider.per_delivery_fee),
        'today_deliveries': t['deliveries'], 'today_earned': _money(t['earned']),
        'cash_in_hand': _money(b['cash_in_hand']), 'due': _money(b['due']),
    }


def _store_info(order):
    vp = VendorProfile.objects.filter(vendor_id=order.vendor_id).first() if order.vendor_id else None
    ven = order.vendor if order.vendor_id else None
    return {
        'name': store_orders.store_name(order.vendor_id),
        'address': getattr(ven, 'address', '') or '',
        'phone': getattr(ven, 'contact_number', '') or '',
        'lat': vp.latitude if vp else None, 'lng': vp.longitude if vp else None,
    }


def _order_json(order, status=None):
    cust = order.customer
    cp = getattr(cust, 'portal_profile', None)
    return {
        'id': order.pk, 'order_no': order.order_no, 'status': status or order.status,
        'vendor_id': order.vendor_id,
        'store': _store_info(order),
        'customer': {
            'name': getattr(cust, 'name', '') or '',
            'phone': getattr(cust, 'contact_number', '') or '',
            'address': getattr(cust, 'address', '') or '',
            'lat': getattr(cp, 'latitude', None), 'lng': getattr(cp, 'longitude', None),
        },
        'items': [{'name': i.product.name, 'qty': i.qty} for i in order.items.all()],
        'total': _money(store_orders.order_payable_total(order)),
        'is_cod': (order.payment_method or 'cod') == 'cod',
    }


def _err(msg, code=400):
    return JsonResponse({'ok': False, 'message': msg}, status=code)


# ---------------------------------------------------------------- endpoints

@csrf_exempt
@require_http_methods(['POST'])
def api_login(request):
    d = _data(request)
    phone_raw = (d.get('phone') or '').strip()[:20]
    password = d.get('password') or ''
    if not phone_raw or not password:
        return _err('Phone aur password dono likhein')
    phone = normalize_phone(phone_raw)
    key = f"rider_api_login:{phone}:{get_client_ip(request) or ''}"
    if cache.get(key, 0) >= LOGIN_MAX_ATTEMPTS:
        return _err('Bohat zyada koshishen. 10 minute baad dobara try karein.', 429)
    rider = RiderProfile.objects.select_related('user').filter(phone=phone, is_active=True).first()
    user = authenticate(request, username=rider.user.username, password=password) if rider else None
    if not user:
        cache.set(key, cache.get(key, 0) + 1, LOGIN_LOCK_SECONDS)
        return _err('Phone ya password ghalat hai', 401)
    cache.delete(key)
    rider.last_login_at = now()
    rider.save(update_fields=['last_login_at'])
    return JsonResponse({'ok': True, 'token': _make_token(rider), 'rider': _profile(rider)})


@rider_api(['POST'])
def api_logout(request, rider):
    RiderProfile.objects.filter(pk=rider.pk).update(is_online=False)
    # is phone ka push token hata do (logout ke baad notification nahi aani chahiye)
    tok = str(_data(request).get('push_token') or '').strip()
    if tok:
        RiderPushToken.objects.filter(rider=rider, token=tok).delete()
    return JsonResponse({'ok': True})


MAX_PUSH_TOKENS = 5     # ek rider ke zyada se zyada itne phone


@rider_api(['POST'])
def api_push_token(request, rider):
    """App apna FCM token yahan register karti hai (login ke baad aur token badalne par)."""
    d = _data(request)
    token = str(d.get('token') or '').strip()
    if not (20 <= len(token) <= 255):
        return _err('Push token ghalat hai.')
    platform = (str(d.get('platform') or 'android').strip() or 'android')[:20]
    # token ek hi rider ka: kisi aur rider ne isi phone par login kiya to token naye rider ka ho jata hai
    RiderPushToken.objects.update_or_create(token=token, defaults={'rider': rider, 'platform': platform})
    keep = list(RiderPushToken.objects.filter(rider=rider).order_by('-updated_at')
                .values_list('pk', flat=True)[:MAX_PUSH_TOKENS])
    RiderPushToken.objects.filter(rider=rider).exclude(pk__in=keep).delete()
    return JsonResponse({'ok': True})


@rider_api(['GET'])
def api_me(request, rider):
    _touch(rider)
    return JsonResponse({'ok': True, 'rider': _profile(rider), 'max_active': MAX_ACTIVE_ORDERS})


@rider_api(['POST'])
def api_online(request, rider):
    d = _data(request)
    want = d.get('online')
    if want is None:
        want = not rider.is_online
    else:
        want = str(want).lower() in ('1', 'true', 'yes', 'on')
    rider.is_online = want
    rider.last_seen_at = now()
    rider.save(update_fields=['is_online', 'last_seen_at'])
    return JsonResponse({'ok': True, 'online': rider.is_online})


@rider_api(['GET'])
def api_orders(request, rider):
    """Offers (agar online) + mere active orders. App har ~12s ye poll karti hai."""
    _touch(rider)
    mine_qs = (DeliveryInfo.objects.filter(rider=rider, status__in=ACTIVE_STATUSES, sale_order__isnull=False)
               .select_related('sale_order', 'sale_order__customer', 'sale_order__vendor')
               .prefetch_related('sale_order__items__product').order_by('assigned_at'))
    mine = [dict(_order_json(d.sale_order, status=d.status), delivery_status=d.status) for d in mine_qs]
    offers = []
    if rider.is_online:
        for o in _offers_qs():
            offers.append(dict(_order_json(o), fee=_money(rider.per_delivery_fee)))
    return JsonResponse({
        'ok': True, 'online': rider.is_online, 'offers': offers, 'mine': mine,
        'tracking': any(m['delivery_status'] in TRACK_STATUSES for m in mine),   # Phase 3: accept ke baad se
        'profile': _profile(rider),
    })


@rider_api(['POST'])
def api_accept(request, rider, pk):
    if not rider.is_online:
        return _err('Pehle online hon.')
    if DeliveryInfo.objects.filter(rider=rider, status__in=ACTIVE_STATUSES).count() >= MAX_ACTIVE_ORDERS:
        return _err(f'Aap ke paas pehle se {MAX_ACTIVE_ORDERS} orders hain. Pehle unhein poora karein.')
    try:
        with transaction.atomic():
            order = SaleOrder.objects.select_for_update().filter(pk=pk, status='ready').first()
            if not order:
                raise store_orders.OrderActionError('Ye order ab available nahi.')
            di, _ = DeliveryInfo.objects.select_for_update().get_or_create(sale_order=order)
            if di.rider_id and di.status != 'cancelled':
                raise store_orders.OrderActionError('Ye order kisi aur rider ne le liya.')
            _assign(order, di, rider, rider.user)
    except store_orders.OrderActionError as exc:
        return _err(str(exc), 409)
    return JsonResponse({'ok': True, 'message': f'Order #{order.order_no} aap ka ho gaya.'})


@rider_api(['POST'])
def api_order_action(request, rider, pk, action):
    """action: pickup | deliver (web wale rider_order_action jaisa)"""
    if action not in ('pickup', 'deliver'):
        return _err('Ghalat action.')
    user = rider.user
    try:
        with transaction.atomic():
            order = get_object_or_404(SaleOrder.objects.select_for_update(), pk=pk)
            di = get_object_or_404(DeliveryInfo, sale_order=order, rider=rider)
            cust = store_orders._customer_user(order)
            shop = store_orders.store_name(order.vendor_id)

            if action == 'pickup':
                if di.status != 'assigned' or order.status != 'ready':
                    raise store_orders.OrderActionError('Ye order ab "maal lene" ke liye tayyar nahi.')
                di.status = 'picked_up'
                di.picked_up_at = now()
                di.save()
                _track(order, 'out_for_delivery', 'Out for Delivery',
                       f'Rider {rider.name} ne {shop} se maal le liya.', user, rider)
                store_orders._notify(cust, f'🛵 Order #{order.order_no} raaste mein hai',
                                     f'Rider {rider.name} ({rider.phone}) aap ka order le kar nikal chuka hai.',
                                     f'/shop/order/{order.id}/', 'info')
                msg = f'Order #{order.order_no}: maal le liya. Ab customer ke paas jayein.'
            else:
                if di.status not in ('picked_up', 'in_transit') or order.status != 'ready':
                    raise store_orders.OrderActionError('Pehle "Maal le liya" dabayein.')
                total = store_orders.order_payable_total(order)
                is_cod = (order.payment_method or 'cod') == 'cod'
                di.status = 'delivered'
                di.delivered_at = now()
                di.rider_fee = rider.per_delivery_fee
                di.cash_collected = total if is_cod else Decimal('0')
                di.delivery_notes = (f'COD cash rider ne liya: Rs. {total:,.0f}' if is_cod
                                     else 'Online payment - cash nahi liya')
                di.save()
                store_orders.apply_vendor_action(order, 'delivered', user=user)
                _track(order, 'delivered', 'Delivered',
                       f'Rider {rider.name} ne order deliver kar diya.', user, rider)
                store_orders._notify(_vendor_user(order), f'🎉 Order #{order.order_no} deliver ho gaya',
                                     f'Rider {rider.name} ne deliver kar diya.'
                                     + (f' COD Rs. {total:,.0f} rider ke paas hai.' if is_cod else ''),
                                     '/shop/vendor/orders/?tab=done', 'success')
                msg = f'Order #{order.order_no} deliver ho gaya. Kamai: Rs. {rider.per_delivery_fee:,.0f}.'
                if is_cod:
                    msg += f' Customer se Rs. {total:,.0f} cash liya.'
    except store_orders.OrderActionError as exc:
        return _err(str(exc), 409)
    return JsonResponse({'ok': True, 'message': msg})


@rider_api(['POST'])
def api_location(request, rider):
    code, data = save_rider_location(rider, _data(request))
    return JsonResponse(data, status=code)


# ================================================================
# PHASE 1: CASH HANDOVER (rider -> admin / vendor, receiver confirm karega - Phase 2)
# ================================================================

def _cash_limit():
    """Rider ke paas cash ki hadd (Rs.). Abhi settings se; admin se badalna baad ke phase mein."""
    return Decimal(str(getattr(settings, 'RIDER_CASH_LIMIT', 5000)))


def _iso(dt):
    return timezone.localtime(dt).isoformat() if dt else None


def _pending_total(rider):
    return Decimal(rider.handovers.filter(status='pending').aggregate(t=Sum('amount'))['t'] or 0)


def _cash_state(rider):
    """cash_in_hand, pending handovers aur ab bhi handover ke qabil raqam."""
    b = rider_balances(rider)
    pending = _pending_total(rider)
    available = max(Decimal('0'), b['cash_in_hand'] - pending)
    return b, pending, available


def _cash_vendor_rows(rider):
    """Rider ke delivered COD orders ka vendor-wise cash (vendor_id None = shop ka apna order)."""
    rows = (DeliveryInfo.objects.filter(rider=rider, status='delivered', cash_collected__gt=0,
                                        sale_order__isnull=False)
            .values('sale_order__vendor_id').annotate(total=Sum('cash_collected'), n=Count('id')))
    return {r['sale_order__vendor_id']: r for r in rows}


def _handover_json(h):
    return {
        'id': h.pk, 'receiver': h.receiver,
        'vendor_id': h.vendor_id,
        'vendor_name': store_orders.store_name(h.vendor_id) if h.vendor_id else '',
        'amount': _money(h.amount), 'note': h.note, 'status': h.status,
        'reject_reason': h.reject_reason,
        'created_at': _iso(h.created_at), 'decided_at': _iso(h.decided_at),
    }


def _parse_amount(raw):
    """Raqam ko Decimal (2 decimal) banao. Ghalat ho to None."""
    try:
        amt = Decimal(str(raw).strip().replace(',', ''))
    except Exception:
        return None
    if not amt.is_finite():
        return None
    amt = amt.quantize(Decimal('0.01'))
    if amt <= 0 or amt >= Decimal('10000000000'):
        return None
    return amt


@rider_api(['GET'])
def api_wallet(request, rider):
    """Cash in hand, kamai (due), vendor-wise cash breakup, settlements aur handovers."""
    b, pending, available = _cash_state(rider)
    rows = _cash_vendor_rows(rider)
    hand = {}
    for h in rider.handovers.filter(receiver='vendor', status__in=('pending', 'confirmed')):
        d = hand.setdefault(h.vendor_id, {'confirmed': Decimal('0'), 'pending': Decimal('0')})
        d[h.status] += h.amount
    vendor_wise = []
    for vid, r in rows.items():
        d = hand.get(vid, {'confirmed': Decimal('0'), 'pending': Decimal('0')})
        vendor_wise.append({
            'vendor_id': vid, 'name': store_orders.store_name(vid),
            'orders': r['n'], 'collected': _money(r['total']),
            'handed_to_vendor': _money(d['confirmed']), 'pending_to_vendor': _money(d['pending']),
            'balance': _money(max(Decimal('0'), Decimal(r['total']) - d['confirmed'] - d['pending'])),
        })
    vendor_wise.sort(key=lambda x: -x['balance'])
    limit = _cash_limit()
    return JsonResponse({
        'ok': True,
        'cash_in_hand': _money(b['cash_in_hand']),
        'pending_handover': _money(pending),
        'available_to_handover': _money(available),
        'cash_collected': _money(b['cash_collected']),
        'cash_deposited': _money(b['cash_deposited']),
        'earned': _money(b['earned']), 'paid_out': _money(b['paid_out']), 'due': _money(b['due']),
        'cash_limit': _money(limit), 'limit_reached': b['cash_in_hand'] >= limit,
        # rider kin vendors ko cash de sakta hai (sirf jin ke COD orders deliver kiye)
        'vendors': [{'vendor_id': v['vendor_id'], 'name': v['name']} for v in vendor_wise
                    if v['vendor_id']],
        'vendor_wise': vendor_wise,
        'settlements': [{'id': s.pk, 'kind': s.kind, 'amount': _money(s.amount), 'note': s.note,
                         'created_at': _iso(s.created_at)} for s in rider.settlements.all()[:20]],
        'handovers': [_handover_json(h) for h in rider.handovers.select_related('vendor')[:10]],
    })


@rider_api(['GET'])
def api_handovers(request, rider):
    """Rider ke handovers + status. Optional ?status=pending|confirmed|rejected"""
    qs = rider.handovers.select_related('vendor')
    st = (request.GET.get('status') or '').strip()
    if st in ('pending', 'confirmed', 'rejected'):
        qs = qs.filter(status=st)
    return JsonResponse({'ok': True, 'handovers': [_handover_json(h) for h in qs[:50]]})


@rider_api(['POST'])
def api_cash_handover(request, rider):
    """Cash handover banao (status pending). Receiver confirm Phase 2 mein.
    body: receiver (admin|vendor), vendor_id (vendor par zaroori), amount, note, order_ids (optional)"""
    d = _data(request)
    receiver = (d.get('receiver') or '').strip().lower()
    if receiver not in ('admin', 'vendor'):
        return _err('Receiver Admin ya Vendor chunein.')
    amount = _parse_amount(d.get('amount'))
    if amount is None:
        return _err('Raqam sahi likhein (0 se zyada).')
    note = (d.get('note') or '').strip()[:200]

    vendor = None
    if receiver == 'vendor':
        try:
            vid = int(d.get('vendor_id'))
        except (TypeError, ValueError):
            return _err('Vendor chunein.')
        # sirf wahi vendor jis ke COD orders rider ne deliver kiye hain
        if vid not in _cash_vendor_rows(rider) or not vid:
            return _err('Ye vendor aap ke orders ka nahi hai.')
        vendor = Vendor.objects.filter(pk=vid).first()
        if not vendor:
            return _err('Vendor nahi mila.')

    # optional: kin orders ka cash hai
    order_ids = d.get('order_ids') or []
    if isinstance(order_ids, str):
        order_ids = [x for x in order_ids.split(',') if x.strip()]
    if not isinstance(order_ids, (list, tuple)):
        return _err('order_ids ghalat hain.')
    try:
        order_ids = sorted({int(x) for x in order_ids})[:100]
    except (TypeError, ValueError):
        return _err('order_ids ghalat hain.')
    deliveries = []
    if order_ids:
        deliveries = list(DeliveryInfo.objects.filter(
            pk__in=order_ids, rider=rider, status='delivered', cash_collected__gt=0,
            sale_order__isnull=False).select_related('sale_order'))
        if len(deliveries) != len(order_ids):
            return _err('Kuch orders aap ke delivered COD orders mein nahi hain.')
        if vendor and any(x.sale_order.vendor_id != vendor.pk for x in deliveries):
            return _err('Chune hue orders is vendor ke nahi hain.')
        if amount > sum((x.cash_collected for x in deliveries), Decimal('0')):
            return _err('Raqam chune hue orders ke cash se zyada hai.')

    with transaction.atomic():
        # rider ki row lock: do taap (double tap) ek doosre se aage-peeche chalenge
        locked = RiderProfile.objects.select_for_update().get(pk=rider.pk)
        b, pending, available = _cash_state(locked)
        if amount > available:
            return _err(f'Aap sirf Rs. {available:,.0f} handover kar sakte hain '
                        f'(cash in hand Rs. {b["cash_in_hand"]:,.0f}, pending Rs. {pending:,.0f}).', 409)
        # double submit: bilkul wahi handover 15 second ke andar dobara
        recent = timezone.now() - timedelta(seconds=15)
        if locked.handovers.filter(status='pending', receiver=receiver, vendor=vendor,
                                   amount=amount, created_at__gte=recent).exists():
            return _err('Ye handover abhi bhej diya gaya hai. Neeche list mein dekhein.', 409)
        h = RiderCashHandover.objects.create(rider=locked, receiver=receiver, vendor=vendor,
                                             amount=amount, note=note)
        if deliveries:
            h.orders.set(deliveries)

    # notification (transaction ke baad; fail ho to bhi handover bana rehta hai)
    title = f'💵 Rider {rider.name} ne Rs. {amount:,.0f} cash diya'
    msg = f'Rider {rider.name} ({rider.phone}) ne Rs. {amount:,.0f} cash handover bheja hai. Confirm karein.'
    if receiver == 'admin':
        store_orders.notify_admins(title, msg, f'/shop/rider/manage/{rider.pk}/', 'info')
    else:
        vp = VendorProfile.objects.filter(vendor_id=vendor.pk).select_related('user').first()
        store_orders._notify(vp.user if vp else None, title, msg, '/shop/vendor/rider-cash/', 'info')

    return JsonResponse({'ok': True, 'handover': _handover_json(h),
                         'message': f'Rs. {amount:,.0f} ka handover bhej diya. Receiver ke confirm ka intezar.'})


# ================================================================
# PHASE 3: DASHBOARD / HISTORY / ORDER DETAIL / PROFILE / PASSWORD
# (sab naye endpoints; purane endpoints ka format nahi badla)
# ================================================================

def _day_label(d):
    return d.strftime('%a')


def _chart_7days(rider, today):
    """Pichle 7 din (aaj tak) ki deliveries + kamai. Purana din pehle."""
    start = today - timedelta(days=6)
    rows = (DeliveryInfo.objects.filter(rider=rider, status='delivered', delivered_at__date__gte=start)
            .annotate(day=TruncDate('delivered_at'))
            .values('day').annotate(n=Count('id'), earned=Sum('rider_fee')))
    by_day = {r['day']: r for r in rows}
    out = []
    for i in range(7):
        d = start + timedelta(days=i)
        r = by_day.get(d)
        out.append({'date': d.isoformat(), 'label': _day_label(d),
                    'deliveries': r['n'] if r else 0, 'earned': _money(r['earned']) if r else 0.0})
    return out


def _warnings(rider, b, pending):
    """App mein dikhane ke liye saaf warnings (code + Roman Urdu text)."""
    w = []
    limit = _cash_limit()
    if b['cash_in_hand'] >= limit:
        w.append({'code': 'cash_limit', 'level': 'error',
                  'text': f'Aap ke paas Rs. {b["cash_in_hand"]:,.0f} cash hai (hadd Rs. {limit:,.0f}). '
                          'Naya order lene se pehle cash handover karein.'})
    elif b['cash_in_hand'] >= limit * Decimal('0.8'):
        w.append({'code': 'cash_near_limit', 'level': 'warn',
                  'text': f'Cash Rs. {b["cash_in_hand"]:,.0f} ho gaya hai. Hadd Rs. {limit:,.0f} hai - jaldi handover karein.'})
    if pending > 0:
        w.append({'code': 'handover_pending', 'level': 'info',
                  'text': f'Rs. {pending:,.0f} ka handover receiver ke confirm ka intezar kar raha hai.'})
    rejected = rider.handovers.filter(status='rejected').order_by('-decided_at', '-pk').first()
    if rejected and rejected.decided_at and rejected.decided_at >= timezone.now() - timedelta(days=2):
        w.append({'code': 'handover_rejected', 'level': 'warn',
                  'text': f'Rs. {rejected.amount:,.0f} ka handover reject hua: {rejected.reject_reason or "wajah nahi likhi"}'})
    if not rider.is_online:
        w.append({'code': 'offline', 'level': 'info', 'text': 'Aap offline hain - naye orders nahi aayenge.'})
    return w


@rider_api(['GET'])
def api_dashboard(request, rider):
    """Aaj / hafta / mahina stats, cash, due, rating, active count, 7-din chart, warnings."""
    _touch(rider)
    today = timezone.localdate()
    b, pending, available = _cash_state(rider)
    t, w, m = (period_stats(rider, today), period_stats(rider, today - timedelta(days=6)),
               period_stats(rider, today.replace(day=1)))
    active = DeliveryInfo.objects.filter(rider=rider, status__in=ACTIVE_STATUSES, sale_order__isnull=False).count()
    offers = _offers_qs().count() if rider.is_online else 0
    rating = rider_rating(rider)
    limit = _cash_limit()
    return JsonResponse({
        'ok': True, 'online': rider.is_online,
        'rider': {'id': rider.pk, 'name': rider.name, 'phone': rider.phone, 'vehicle': rider.vehicle},
        'today': {'deliveries': t['deliveries'], 'earned': _money(t['earned'])},
        'week': {'deliveries': w['deliveries'], 'earned': _money(w['earned'])},
        'month': {'deliveries': m['deliveries'], 'earned': _money(m['earned'])},
        'total_deliveries': b['deliveries'],
        'cash_in_hand': _money(b['cash_in_hand']), 'pending_handover': _money(pending),
        'available_to_handover': _money(available),
        'due': _money(b['due']), 'cash_limit': _money(limit), 'limit_reached': b['cash_in_hand'] >= limit,
        'rating': rating,
        'active_count': active, 'max_active': MAX_ACTIVE_ORDERS, 'offers_count': offers,
        'chart': _chart_7days(rider, today),
        'warnings': _warnings(rider, b, pending),
    })


def _int_param(raw, default, lo, hi):
    try:
        v = int(raw)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, v))


def _date_param(raw):
    from datetime import date
    try:
        return date.fromisoformat((raw or '').strip())
    except ValueError:
        return None


@rider_api(['GET'])
def api_history(request, rider):
    """Delivered / cancelled orders. ?page=1&page_size=20&from=YYYY-MM-DD&to=YYYY-MM-DD&status=delivered|cancelled"""
    page = _int_param(request.GET.get('page'), 1, 1, 100000)
    size = _int_param(request.GET.get('page_size'), 20, 1, 50)
    st = (request.GET.get('status') or '').strip()
    statuses = [st] if st in ('delivered', 'cancelled') else ['delivered', 'cancelled']
    qs = (DeliveryInfo.objects.filter(rider=rider, status__in=statuses, sale_order__isnull=False)
          .annotate(when=Coalesce('delivered_at', 'assigned_at', 'created_at')))
    d_from, d_to = _date_param(request.GET.get('from')), _date_param(request.GET.get('to'))
    if request.GET.get('from') and d_from is None or request.GET.get('to') and d_to is None:
        return _err('Tareekh YYYY-MM-DD likhein (jaise 2026-11-23).')
    if d_from:
        qs = qs.filter(when__date__gte=d_from)
    if d_to:
        qs = qs.filter(when__date__lte=d_to)
    total = qs.count()
    rows = list(qs.select_related('sale_order', 'sale_order__customer', 'sale_order__vendor')
                .order_by('-when', '-pk')[(page - 1) * size: page * size])
    agg = qs.filter(status='delivered').aggregate(n=Count('id'), earned=Sum('rider_fee'), cash=Sum('cash_collected'))
    items = []
    for d in rows:
        o = d.sale_order
        items.append({
            'id': o.pk, 'order_no': o.order_no, 'status': d.status,
            'vendor_id': o.vendor_id, 'store_name': store_orders.store_name(o.vendor_id),
            'customer_name': getattr(o.customer, 'name', '') or '',
            'total': _money(store_orders.order_payable_total(o)),
            'is_cod': (o.payment_method or 'cod') == 'cod',
            'fee': _money(d.rider_fee) if d.status == 'delivered' else 0.0,
            'cash_collected': _money(d.cash_collected),
            'when': _iso(d.when),
        })
    return JsonResponse({
        'ok': True, 'page': page, 'page_size': size, 'total': total,
        'has_more': page * size < total, 'items': items,
        # chune hue filter ka khulasa (sirf delivered)
        'summary': {'deliveries': agg['n'] or 0, 'earned': _money(agg['earned']), 'cash': _money(agg['cash'])},
    })


def _steps(di):
    """Status stepper: Accepted > Picked > Delivered (app ke liye)."""
    order = ['assigned', 'picked_up', 'delivered']
    if di.status == 'cancelled':
        cur = -1
    elif di.status == 'in_transit':
        cur = 1
    else:
        cur = order.index(di.status) if di.status in order else 0
    return [
        {'key': 'assigned', 'label': 'Accept kiya', 'done': cur >= 0, 'at': _iso(di.assigned_at)},
        {'key': 'picked_up', 'label': 'Maal le liya', 'done': cur >= 1, 'at': _iso(di.picked_up_at)},
        {'key': 'delivered', 'label': 'Deliver hua', 'done': cur >= 2, 'at': _iso(di.delivered_at)},
    ]


@rider_api(['GET'])
def api_order_detail(request, rider, pk):
    """Aik order ki mukammal detail + status timeline. Sirf rider ka apna order (pk = SaleOrder id)."""
    di = (DeliveryInfo.objects.filter(rider=rider, sale_order_id=pk)
          .select_related('sale_order', 'sale_order__customer', 'sale_order__vendor').first())
    if not di:
        return _err('Order nahi mila.', 404)
    o = di.sale_order
    data = _order_json(o, status=di.status)
    data.update({
        'delivery_status': di.status, 'order_status': o.status,
        'fee': _money(di.rider_fee if di.status == 'delivered' else rider.per_delivery_fee),
        'cash_collected': _money(di.cash_collected),
        'payment_method': o.payment_method or 'cod',
        'steps': _steps(di),
        'timeline': [{'status': t.status, 'title': t.title or t.get_status_display(),
                      'description': t.description or '', 'at': _iso(t.timestamp)}
                     for t in OrderTracking.objects.filter(sale_order=o).order_by('timestamp', 'pk')],
        'assigned_at': _iso(di.assigned_at), 'picked_up_at': _iso(di.picked_up_at),
        'delivered_at': _iso(di.delivered_at),
        'tracking': di.status in TRACK_STATUSES,
    })
    return JsonResponse({'ok': True, 'order': data})


def _profile_full(rider):
    rating = rider_rating(rider)
    b = rider_balances(rider)
    reviews = (OrderReview.objects.filter(rider=rider, rider_rating__isnull=False)
               .select_related('sale_order').order_by('-created_at')[:10])
    return {
        'id': rider.pk, 'name': rider.name, 'phone': rider.phone, 'vehicle': rider.vehicle,
        'online': rider.is_online, 'fee': _money(rider.per_delivery_fee),
        'joined': _iso(rider.created_at), 'total_deliveries': b['deliveries'],
        'rating': rating,
        'reviews': [{'stars': r.rider_rating, 'comment': r.rider_comment or '',
                     'order_no': r.sale_order.order_no, 'at': _iso(r.created_at)} for r in reviews],
    }


@rider_api(['GET', 'POST'])
def api_profile(request, rider):
    """GET: profile + rating + reviews. POST: naam / vehicle badlein (phone login ID hai, yahan se nahi badalta)."""
    if request.method == 'POST':
        d = _data(request)
        fields = []
        if 'name' in d:
            name = (d.get('name') or '').strip()[:100]
            if len(name) < 2:
                return _err('Naam kam az kam 2 harf ka likhein.')
            rider.name = name
            fields.append('name')
        if 'vehicle' in d:
            rider.vehicle = (d.get('vehicle') or '').strip()[:50]
            fields.append('vehicle')
        if not fields:
            return _err('Kuch badalne ko nahi diya (name ya vehicle).')
        rider.save(update_fields=fields)
        return JsonResponse({'ok': True, 'message': 'Profile update ho gaya.', 'profile': _profile_full(rider)})
    return JsonResponse({'ok': True, 'profile': _profile_full(rider)})


@rider_api(['POST'])
def api_password(request, rider):
    """Password badlein. body: old_password, new_password. Naya token wapis milta hai
    (purane token khud band ho jate hain)."""
    d = _data(request)
    old, new = d.get('old_password') or '', d.get('new_password') or ''
    if not old or not new:
        return _err('Purana aur naya password dono likhein.')
    key = f'rider_api_pw:{rider.pk}'
    if cache.get(key, 0) >= LOGIN_MAX_ATTEMPTS:
        return _err('Bohat zyada koshishen. 10 minute baad dobara try karein.', 429)
    user = rider.user
    if not user.check_password(old):
        cache.set(key, cache.get(key, 0) + 1, LOGIN_LOCK_SECONDS)
        return _err('Purana password ghalat hai.', 401)
    if len(new) < 6:
        return _err('Naya password kam az kam 6 harf ka ho.')
    if len(new) > 128:
        return _err('Naya password bohat lamba hai.')
    if new == old:
        return _err('Naya password purane se alag ho.')
    cache.delete(key)
    user.set_password(new)
    user.save(update_fields=['password'])
    rider.user = user
    return JsonResponse({'ok': True, 'message': 'Password badal gaya.', 'token': _make_token(rider)})
