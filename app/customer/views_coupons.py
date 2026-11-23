"""
Coupons
=======
Customer: coupon_apply / coupon_remove (checkout par), my_coupons (abhi chalne wale offers)
Vendor  : vendor_coupons (list + naya coupon), vendor_coupon_toggle, vendor_coupon_delete

Naye tables Coupon / CouponRedemption (migration 0056). Purane views/tables nahi badle.
Discount SaleOrder.discount_value mein jata hai (coupons.py dekhein).
"""
import json
import logging
import re
from datetime import datetime, time as dtime
from decimal import Decimal, InvalidOperation

from django.contrib import messages
from django.core.cache import cache
from django.db import IntegrityError
from django.db.models import Sum
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.views.decorators.http import require_POST

from ..decorators import customer_login_required, vendor_login_required
from ..models import CompanyInfo, Coupon
from . import coupons as coupon_engine, store_orders
from .checkout_cart import get_checkout_cart
from .views_customer_portal import calculate_cart_data
from .views_vendor_portal import _company_name

logger = logging.getLogger(__name__)

CODE_RE = re.compile(r'^[A-Z0-9]{3,20}$')
MAX_VENDOR_COUPONS = 50
MAX_PERCENT_VENDOR = Decimal('70')
MAX_FIXED = Decimal('100000')
MAX_TRIES = 10            # ek customer, 10 minute mein
TRY_WINDOW = 600


# ------------------------------------------------------------------ customer
def _throttled(user_id):
    key = f'coupon_tries:{user_id}'
    tries = cache.get(key, 0)
    if tries >= MAX_TRIES:
        return True
    cache.set(key, tries + 1, TRY_WINDOW)
    return False


@customer_login_required
@require_POST
def coupon_apply(request):
    profile = getattr(request.user, 'customer_profile', None)
    if not profile:
        return JsonResponse({'success': False, 'message': 'Sirf customers ke liye'}, status=403)
    if _throttled(request.user.id):
        return JsonResponse({'success': False, 'message': 'Bohat zyada koshishein. Kuch minute baad dobara try karein.'})
    try:
        body = json.loads(request.body) if request.body else {}
    except (ValueError, TypeError):
        body = {}
    code = body.get('code') or request.POST.get('code') or ''

    cart = get_checkout_cart(request)
    if not cart:
        return JsonResponse({'success': False, 'message': 'Cart khali hai'})
    customer = profile.customer
    data = calculate_cart_data(cart, customer=customer, delivery_type=request.session.get('delivery_type', 'standard'))
    res = coupon_engine.evaluate(code, customer, cart, data['subtotal'], data['delivery_charges'])
    if not res.ok:
        return JsonResponse({'success': False, 'message': res.message})

    coupon_engine.set_session(request, res.coupon.code)
    total = max(Decimal('0'), data['subtotal'] + data['delivery_charges'] - res.total_saving)
    return JsonResponse({'success': True, 'message': res.message, 'code': res.coupon.code,
                         'saving': float(res.total_saving), 'total_amount': float(total)})


@customer_login_required
@require_POST
def coupon_remove(request):
    coupon_engine.clear_session(request)
    return JsonResponse({'success': True})


def my_coupons(request):
    profile = getattr(request.user, 'customer_profile', None) if request.user.is_authenticated else None
    customer = profile.customer if profile else None
    offers = coupon_engine.available_for_customer(customer)
    for c in offers:
        c.store_label = store_orders.store_name(c.vendor_id) if c.vendor_id else 'Poori shop'
    company = CompanyInfo.objects.first()
    cart = request.session.get('cart', {})
    return render(request, 'customer_portal/coupons.html', {
        'offers': offers,
        'company_name': company.name if company else 'Shop',
        'company': company,
        'cart_count': sum(i.get('quantity', 0) for i in cart.values()),
        'page_title': 'Offers & Coupons',
    })


# ------------------------------------------------------------------ vendor
def _num(raw, label, errors, lo, hi, default=None):
    raw = (raw or '').strip()
    if raw == '':
        return default
    try:
        val = Decimal(raw)
    except InvalidOperation:
        errors.append(f'{label}: sahi number likhein')
        return default
    if val < lo or val > hi:
        errors.append(f'{label}: {lo} se {hi} ke beech hona chahiye')
        return default
    return val


def _date(raw, label, errors, end=False):
    raw = (raw or '').strip()
    if not raw:
        return None
    try:
        d = datetime.strptime(raw, '%Y-%m-%d').date()
    except ValueError:
        errors.append(f'{label}: tareekh sahi nahi')
        return None
    return timezone.make_aware(datetime.combine(d, dtime.max if end else dtime.min))


def _clean_vendor_coupon(post):
    errors = []
    code = ''.join((post.get('code') or '').split()).upper()
    if not CODE_RE.match(code):
        errors.append('Code 3 se 20 harf/number ka ho (jaise WELCOME50), koi space ya nishan nahi')
    elif Coupon.objects.filter(code=code).exists():
        errors.append('Yeh code pehle se kisi aur coupon ka hai, doosra code chunein')

    dtype = post.get('discount_type')
    if dtype not in (Coupon.TYPE_PERCENT, Coupon.TYPE_FIXED, Coupon.TYPE_FREE_DELIVERY):
        errors.append('Coupon ki qism chunein')
        dtype = Coupon.TYPE_PERCENT

    value = Decimal('0')
    max_discount = None
    if dtype == Coupon.TYPE_PERCENT:
        value = _num(post.get('value'), 'Percent', errors, Decimal('1'), MAX_PERCENT_VENDOR, Decimal('0'))
        max_discount = _num(post.get('max_discount'), 'Max discount', errors, Decimal('1'), MAX_FIXED)
    elif dtype == Coupon.TYPE_FIXED:
        value = _num(post.get('value'), 'Rs. discount', errors, Decimal('1'), MAX_FIXED, Decimal('0'))
    if dtype != Coupon.TYPE_FREE_DELIVERY and not value and not errors:
        errors.append('Discount ki miqdar likhein')

    usage = _num(post.get('usage_limit'), 'Kul istemal', errors, Decimal('1'), Decimal('100000'))
    per_c = _num(post.get('per_customer_limit'), 'Har customer', errors, Decimal('0'), Decimal('100'), Decimal('1'))
    valid_from = _date(post.get('valid_from'), 'Shuru ki tareekh', errors)
    valid_until = _date(post.get('valid_until'), 'Khatam ki tareekh', errors, end=True)
    if valid_from and valid_until and valid_until < valid_from:
        errors.append('Khatam ki tareekh shuru se pehle nahi ho sakti')

    data = {
        'code': code,
        'title': (post.get('title') or '').strip()[:80],
        'discount_type': dtype,
        'value': value or Decimal('0'),
        'max_discount': max_discount,
        'min_order': _num(post.get('min_order'), 'Minimum order', errors, Decimal('0'), Decimal('1000000'), Decimal('0')),
        'usage_limit': int(usage) if usage else None,
        'per_customer_limit': int(per_c if per_c is not None else 1),
        'first_order_only': post.get('first_order_only') == 'on',
        'valid_from': valid_from,
        'valid_until': valid_until,
    }
    return data, errors


def _coupon_rows(vendor):
    rows = []
    for c in Coupon.objects.filter(vendor=vendor).order_by('-created_at'):
        agg = c.live_redemptions().aggregate(d=Sum('discount_amount'), w=Sum('delivery_waived'))
        rows.append({'c': c, 'status': c.status, 'used': c.used_count,
                     'given': (agg['d'] or 0) + (agg['w'] or 0)})
    return rows


@vendor_login_required
def vendor_coupons(request):
    profile = request.user.vendor_profile
    vendor = profile.vendor
    form = {}
    errors = []

    if request.method == 'POST':
        form = request.POST
        if not profile.is_approved:
            errors.append('Aap ka account abhi approve nahi hua')
        elif Coupon.objects.filter(vendor=vendor).count() >= MAX_VENDOR_COUPONS:
            errors.append(f'Zyada se zyada {MAX_VENDOR_COUPONS} coupons ho sakte hain. Purane delete karein.')
        else:
            data, errors = _clean_vendor_coupon(request.POST)
            if not errors:
                try:
                    Coupon.objects.create(vendor=vendor, created_by=request.user, **data)
                    messages.success(request, f"✅ Coupon {data['code']} ban gaya")
                    return redirect('vendor_coupons')
                except IntegrityError:
                    errors.append('Yeh code pehle se maujood hai')
                except Exception as exc:
                    logger.error('Vendor coupon create failed: %s', exc)
                    errors.append('Coupon nahi bana, dobara koshish karein')

    rows = _coupon_rows(vendor)
    return render(request, 'customer_portal/vendor/coupons.html', {
        'page_title': 'Coupons',
        'profile': profile,
        'rows': rows,
        'total_given': sum(r['given'] for r in rows),
        'errors': errors,
        'form': form,
        'company_name': _company_name(),
    })


@vendor_login_required
@require_POST
def vendor_coupon_toggle(request, pk):
    coupon = get_object_or_404(Coupon, pk=pk, vendor=request.user.vendor_profile.vendor)
    coupon.is_active = not coupon.is_active
    coupon.save(update_fields=['is_active'])
    messages.success(request, f"{coupon.code} {'chalu' if coupon.is_active else 'band'} kar diya")
    return redirect('vendor_coupons')


@vendor_login_required
@require_POST
def vendor_coupon_delete(request, pk):
    coupon = get_object_or_404(Coupon, pk=pk, vendor=request.user.vendor_profile.vendor)
    if coupon.redemptions.exists():
        # Hisaab ka record na jaye: sirf band karo
        coupon.is_active = False
        coupon.save(update_fields=['is_active'])
        messages.info(request, f'{coupon.code} istemal ho chuka hai, is liye delete nahi hua - band kar diya')
    else:
        code = coupon.code
        coupon.delete()
        messages.success(request, f'{code} delete ho gaya')
    return redirect('vendor_coupons')
