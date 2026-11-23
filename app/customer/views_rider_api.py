"""
Rider Android app ke liye JSON API (token login).

Koi nayi table nahi, koi migration nahi. Token Django ke signing se banta hai (30 din chalta hai;
rider ka password badalne par purane token khud band ho jate hain).
Logic wahi hai jo views_rider_portal.py ka hai - bas JSON mein.

Header:  Authorization: Bearer <token>
"""
import json
import logging
from decimal import Decimal
from functools import wraps

from django.contrib.auth import authenticate
from django.core import signing
from django.core.cache import cache
from django.db import transaction
from django.http import JsonResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.utils.timezone import now
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from ..models import DeliveryInfo, RiderProfile, SaleOrder, VendorProfile
from . import store_orders
from .views_customer_auth import get_client_ip, normalize_phone
from .views_rider_portal import (
    ACTIVE_STATUSES, LOGIN_LOCK_SECONDS, LOGIN_MAX_ATTEMPTS, MAX_ACTIVE_ORDERS,
    _assign, _offers_qs, _touch, _track, _vendor_user, period_stats, rider_balances,
    save_rider_location,
)

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
        'tracking': any(m['delivery_status'] in ('picked_up', 'in_transit') for m in mine),
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
