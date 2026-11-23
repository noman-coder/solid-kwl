"""Coupon engine (validation + discount hisaab + redeem).

Views aur order-placement dono yahi use karte hain, taake rules ek hi jagah rahen.
Koi purani table nahi chhedi: discount SaleOrder.discount_value mein jata hai (jo pehle se
total_after_discount / invoice mein ghoomta hai), free delivery SaleOrder.delivery_fee = 0.
"""
import logging
from dataclasses import dataclass, field
from decimal import Decimal

from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from ..models import Coupon, CouponRedemption, SaleOrder
from . import store_orders

logger = logging.getLogger(__name__)

SESSION_KEY = 'coupon_code'
ZERO = Decimal('0.00')


@dataclass
class CouponResult:
    ok: bool = False
    message: str = ''
    coupon: Coupon = None
    discount: Decimal = ZERO          # items par discount
    free_delivery: bool = False
    delivery_waived: Decimal = ZERO   # delivery ki jo raqam maaf hui
    extra: dict = field(default_factory=dict)

    @property
    def total_saving(self):
        return self.discount + self.delivery_waived


def normalize_code(raw):
    return ''.join((raw or '').split()).upper()[:30]


def _live_count(coupon, customer=None):
    qs = coupon.live_redemptions()
    if customer is not None:
        qs = qs.filter(customer=customer)
    return qs.count()


def _is_first_order(customer):
    return not SaleOrder.objects.filter(customer=customer).exclude(status='cancelled').exists()


def evaluate(code, customer, cart, subtotal, delivery_charges=ZERO):
    """Code ko is customer + cart par parkho. CouponResult lautata hai (ok=False ho to message mein wajah)."""
    code = normalize_code(code)
    if not code:
        return CouponResult(message='Coupon code likhein')

    coupon = Coupon.objects.filter(code=code).select_related('vendor').first()
    if not coupon:
        return CouponResult(message='Yeh coupon code sahi nahi hai')

    subtotal = Decimal(subtotal or 0)
    delivery_charges = Decimal(delivery_charges or 0)
    now = timezone.now()

    if not coupon.is_active:
        return CouponResult(message='Yeh coupon abhi band hai')
    if coupon.valid_from and now < coupon.valid_from:
        return CouponResult(message='Yeh coupon abhi shuru nahi hua')
    if coupon.valid_until and now > coupon.valid_until:
        return CouponResult(message='Yeh coupon expire ho chuka hai')

    # Store ka mel: vendor coupon sirf usi store ke cart par
    if coupon.vendor_id:
        store_id = store_orders.cart_store_id(cart)
        if store_id != coupon.vendor_id:
            name = store_orders.store_name(coupon.vendor_id)
            return CouponResult(message=f'Yeh coupon sirf {name} ke order par chalta hai')

    if subtotal < coupon.min_order:
        return CouponResult(message=f'Is coupon ke liye kam az kam Rs. {coupon.min_order:,.0f} ka order chahiye')

    if coupon.usage_limit is not None and _live_count(coupon) >= coupon.usage_limit:
        return CouponResult(message='Yeh coupon poora istemal ho chuka hai')

    if customer is not None:
        if coupon.per_customer_limit and _live_count(coupon, customer) >= coupon.per_customer_limit:
            return CouponResult(message='Aap yeh coupon pehle hi istemal kar chuke hain')
        if coupon.first_order_only and not _is_first_order(customer):
            return CouponResult(message='Yeh coupon sirf pehle order ke liye hai')

    if coupon.discount_type == Coupon.TYPE_FREE_DELIVERY:
        if delivery_charges <= 0:
            return CouponResult(message='Is order par delivery pehle se free hai')
        return CouponResult(ok=True, coupon=coupon, free_delivery=True, delivery_waived=delivery_charges,
                            message='Free delivery lag gayi')

    discount = coupon.compute_discount(subtotal)
    if discount <= 0:
        return CouponResult(message='Is order par yeh coupon lagne layak nahi')
    return CouponResult(ok=True, coupon=coupon, discount=discount,
                        message=f'Coupon lag gaya: Rs. {discount:,.0f} ki bachat')


def evaluate_session(request, customer, cart, subtotal, delivery_charges=ZERO):
    """Session mein rakha coupon dobara parkho (cart badal gayi ho to ghalat discount na lage).
    Naakaam ho to coupon session se hata deta hai. Session mein coupon na ho to None."""
    code = request.session.get(SESSION_KEY)
    if not code:
        return None
    result = evaluate(code, customer, cart, subtotal, delivery_charges)
    if not result.ok:
        clear_session(request)
    return result


def set_session(request, code):
    request.session[SESSION_KEY] = normalize_code(code)
    request.session.modified = True


def clear_session(request):
    if SESSION_KEY in request.session:
        request.session.pop(SESSION_KEY, None)
        request.session.modified = True


def redeem(result, order, customer):
    """Order ban jaane ke baad coupon ka istemal likho. Lock ke saath limit dobara check hoti hai.
    Kamyab ho to True; warna (bohat nadir race) False - tab caller discount wapis le leta hai."""
    coupon = result.coupon
    try:
        with transaction.atomic():
            locked = Coupon.objects.select_for_update().get(pk=coupon.pk)
            if locked.usage_limit is not None and _live_count(locked) >= locked.usage_limit:
                return False
            if locked.per_customer_limit and _live_count(locked, customer) >= locked.per_customer_limit:
                return False
            CouponRedemption.objects.create(
                coupon=locked, customer=customer, sale_order=order,
                discount_amount=result.discount, delivery_waived=result.delivery_waived,
                funded_by=locked.funded_by,
            )
        return True
    except Exception as exc:  # pragma: no cover - order ko kabhi na rokein
        logger.error('Coupon redeem failed for order %s: %s', getattr(order, 'order_no', '?'), exc)
        return False


def apply_to_new_order(result, order, customer, original_delivery_fee):
    """Order ban chuka (discount_value/delivery_fee pehle hi lagi hui). Redeem karo;
    na ho paye to discount hata kar order ko bagair coupon ke theek-thaak rakho.
    Lautata hai: (applied: bool, discount, delivery_fee)"""
    if not result or not result.ok:
        return False, ZERO, original_delivery_fee
    if redeem(result, order, customer):
        order.coupon_code = result.coupon.code
        order.save(update_fields=['coupon_code'])
        return True, result.discount, order.delivery_fee
    order.discount_value = ZERO
    order.delivery_fee = original_delivery_fee
    order.notes = (order.notes or '') + f"\n⚠️ Coupon {result.coupon.code} order ke waqt lagne se reh gaya (limit poori) - discount hata diya."
    order.save(update_fields=['discount_value', 'delivery_fee', 'notes'])
    return False, ZERO, original_delivery_fee


def available_for_customer(customer, store_id=None):
    """Customer ko dikhane ke liye abhi chalne wale coupons (shop wale + optional ek store ke)."""
    now = timezone.now()
    qs = Coupon.objects.filter(is_active=True).filter(
        Q(valid_from__isnull=True) | Q(valid_from__lte=now)
    ).filter(Q(valid_until__isnull=True) | Q(valid_until__gte=now))
    if store_id:
        qs = qs.filter(Q(vendor__isnull=True) | Q(vendor_id=store_id))
    out = []
    for c in qs.select_related('vendor').order_by('-created_at')[:60]:
        if c.usage_limit is not None and _live_count(c) >= c.usage_limit:
            continue
        if customer is not None:
            if c.per_customer_limit and _live_count(c, customer) >= c.per_customer_limit:
                continue
            if c.first_order_only and not _is_first_order(customer):
                continue
        out.append(c)
    return out


def checkout_summary(request, customer, cart, data):
    """Checkout / cart page ke liye: coupon ka asar aur net total.
    `data` = calculate_cart_data ka natija. Coupon naakaam ho gaya ho to 'error' mein wajah (aur session saaf)."""
    res = evaluate_session(request, customer, cart, data['subtotal'], data['delivery_charges'])
    ok = bool(res and res.ok)
    saving = res.total_saving if ok else ZERO
    total = max(ZERO, data['subtotal'] + data['delivery_charges'] - saving)
    return {
        'ok': ok,
        'code': res.coupon.code if ok else '',
        'title': (res.coupon.title or res.coupon.short_label) if ok else '',
        'saving': saving,
        'discount': res.discount if ok else ZERO,
        'free_delivery': bool(ok and res.free_delivery),
        'total': total,
        'error': (res.message if (res is not None and not res.ok) else ''),
    }
