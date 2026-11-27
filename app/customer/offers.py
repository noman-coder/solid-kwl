"""Vendor product offers (Phase V13-B): waqt-wale discount ka engine.

Usool:
  * Product ki price / discount_percentage / original_price DB mein kabhi nahi badalti.
  * Customer ko dikhate waqt offer upar se lagta hai: asar = max(product ka apna discount, offer %). Do discount jama nahi hote.
  * Offer sirf chalu + start/end ke andar + product approved/active ho to chalta hai. Khatam hote hi price khud pehli jaisi.
  * `overlay()` sirf memory mein discount_percentage badalta hai; `Product.save()` asli value wapas rakhta hai.
"""
from datetime import datetime, time, timedelta
from decimal import Decimal

from django.conf import settings
from django.utils import timezone

from ..models import ProductOffer
from ..vendor_commission import commission_percent, effective_price

HUNDRED = Decimal('100')
MAX_OFFER_PERCENT = Decimal('70')
MIN_OFFER_PERCENT = Decimal('1')
MAX_OFFER_DAYS = 90
MAX_VENDOR_OFFERS = 100


def live_offers_qs(now=None):
    """Abhi chalu offers (switch on, waqt ke andar, product approved + active)."""
    now = now or timezone.now()
    return ProductOffer.objects.filter(
        is_active=True, starts_at__lte=now, ends_at__gt=now,
        product__is_active=True, product__approval_status='approved')


def active_offer_map(product_ids, now=None):
    """{product_id: Decimal offer %} - ek se zyada offer hon to sab se bara."""
    ids = [int(i) for i in product_ids if i]
    if not ids:
        return {}
    out = {}
    for pid, pct in live_offers_qs(now).filter(product_id__in=ids).values_list('product_id', 'discount_percent'):
        pct = Decimal(pct)
        if pct > out.get(pid, Decimal('0')):
            out[pid] = pct
    return out


def effective_discount(product, offer_pct=None):
    """Customer par lagne wala discount %: max(product ka apna, offer)."""
    base = Decimal(product.discount_percentage or 0)
    if offer_pct is None:
        offer_pct = active_offer_map([product.pk]).get(product.pk)
    if offer_pct and Decimal(offer_pct) > base:
        return Decimal(offer_pct)
    return base


def overlay(products):
    """Products ki list par offer memory mein lagao (DB mein nahi). Wohi list wapas. Kharab ho to bina offer chalta hai.

    Har product par `offer_percent` (Decimal ya None) aur `has_offer` set hota hai. Page kabhi nahi tootta.
    """
    items = list(products or [])
    if not items:
        return items
    try:
        offer_map = active_offer_map([getattr(p, 'pk', None) for p in items])
    except Exception:
        offer_map = {}
    for p in items:
        p.offer_percent = None
        p.has_offer = False
        pct = offer_map.get(p.pk)
        if not pct:
            continue
        own = Decimal(p.discount_percentage or 0)
        if pct > own:
            p._offer_real_discount = own          # Product.save() yahi wapas rakhta hai
            p.discount_percentage = pct
            p.offer_percent = pct
            p.has_offer = True
    return items


# ---------------------------------------------------------------- vendor side (API) helpers

def local_day_start(d):
    """date -> us din ka local 00:00 (aware datetime)."""
    return timezone.make_aware(datetime.combine(d, time.min), timezone.get_current_timezone())


def window_from_dates(start_date, end_date):
    """(start, end) dates -> (starts_at, ends_at): shuru us din 00:00, end wale din ke aakhir tak (agle din 00:00)."""
    return local_day_start(start_date), local_day_start(end_date + timedelta(days=1))


def base_price(product):
    """Product ka asli (discount se pehle wala) rate."""
    op = Decimal(product.original_price or 0)
    return op if op > 0 else Decimal(product.price or 0)


def max_allowed_percent(profile, product):
    """Offer % ki hadd. Vendor ka hissa batch ke 'cost' mein pehle se tay hota hai (offer us ko nahi badalta),
    isliye agar offer price vendor ke hisse se neeche chala jaye to shop ka commission minus ho jata.
    `VENDOR_OFFER_CAP_TO_COMMISSION` (default True) is hadd ko lagata hai: 100 * (1 - (1-d)(1-c)). Band karne par sirf 70%."""
    if not getattr(settings, 'VENDOR_OFFER_CAP_TO_COMMISSION', True):
        return MAX_OFFER_PERCENT
    d = Decimal(product.discount_percentage or 0) / HUNDRED
    c = Decimal(commission_percent(profile)) / HUNDRED
    cap = (HUNDRED * (Decimal(1) - (Decimal(1) - d) * (Decimal(1) - c))).quantize(Decimal('0.01'))
    return max(Decimal('0'), min(cap, MAX_OFFER_PERCENT))


def prices(product, pct):
    """(regular_price, offer_price) - regular = product ka maujooda discount ke baad, offer = max(discount, offer %) ke baad."""
    base = base_price(product)
    own = Decimal(product.discount_percentage or 0)
    return effective_price(base, own), effective_price(base, max(own, Decimal(pct)))


def offer_state(offer, now=None):
    """live | scheduled | ended | paused"""
    now = now or timezone.now()
    if offer.ends_at <= now:
        return 'ended'
    if not offer.is_active:
        return 'paused'
    if offer.starts_at > now:
        return 'scheduled'
    return 'live'
