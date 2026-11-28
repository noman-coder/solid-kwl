"""
Customer Android app ki JSON API - Phase C7: Cart.

Endpoints (sab `api/customer/...`):
    GET  cart/           login customer ka cart (qeemat / stock taza dekh kar)
    GET  cart/count/     sirf ginti (tab ke badge ke liye, bohat halka)
    POST cart/add/       {product_id, quantity=1, area?, replace_cart?}
    POST cart/update/    {product_id, quantity}      (quantity 0 = hata do)
    POST cart/remove/    {product_id}
    POST cart/clear/     poora cart khali
    POST cart/ack/       "qeemat badal gayi" alert dekh liya
    POST cart/merge/     {items: [{product_id, quantity}]}  guest ka local cart login ke baad server cart mein jode
    POST cart/preview/   {items: [...]}  guest ka cart (bina login): qeemat/total/warning wapas, kuch save nahi hota

Logic naya nahi likha, web ka hi reuse hai:
    views_customer_portal : calculate_cart_data (subtotal / delivery / total / store rules), get_product_final_price
    store_orders          : cart_store_id (ek waqt mein ek store), cart_store_rules (fee, min order, open/closed),
                            validate_cart_for_order (checkout se pehle wala paigham)
    offers                : overlay (offer qeemat)
    views_customer_home   : _product_json (naam, tasveer, qeemat, purani qeemat, store), _with_stock
    views_customer_products: _live_catalog (sirf live products)

Rules:
- Cart ek nayi table CustomerCart mein (web ka cart session mein hota hai, app ke paas session nahi). Format web jaisa hi.
- Customer sirf apna cart dekhe / badle (profile.customer). Doosre ka cart kabhi nahi.
- Ek waqt mein ek hi store (web jaisa). Doosre store ka maal add ho to 409 `cart_conflict`; `replace_cart=true` se purana cart saaf.
- Stock check har add / update par (qty barhane par). Web jaisi hadd: ek item max 1000.
- Qeemat badal jaye (batch / discount / offer) to cart naye dam par aata hai, item par `price_changed` + `price_was`
  (customer `cart/ack/` ya qty badalne tak). Total hamesha naye dam par.
- Band / hata hua / rejected product: line `issue` ke sath aati hai (total mein nahi jodi jati), customer khud hata sakta hai.
  `can_checkout` sirf tab true jab koi issue na ho, store khula ho aur minimum order poora ho (Phase C8 isi par chalegi).
- Cart ki tabdeeli (add / update / remove / merge) cart ki row par select_for_update + transaction.atomic mein
  (do phone / do tap ek doosre ka kaam na mitayein).
- Migration 0066: sirf nayi table CustomerCart (additive).
"""
import logging
from decimal import Decimal

from django.db import transaction
from django.http import JsonResponse

from ..models import CustomerCart
from . import offers as vendor_offers
from . import store_orders
from .views_customer_api import _data, _err, customer_api, customer_api_optional
from .views_customer_home import _clean_area, _f, _product_json, _with_stock, resolve_area
from .views_customer_portal import calculate_cart_data, get_product_final_price
from .views_customer_products import _live_catalog
from .views_stores import CURRENCY, store_serves_area

logger = logging.getLogger(__name__)

MAX_QTY = 1000            # web add_to_cart jitni hadd
MAX_LINES = 100           # ek cart mein alag alag items ki hadd (misuse se bachao)
ZERO = Decimal('0.00')
CENT = Decimal('0.01')

ISSUE_TEXT = {
    'unavailable': 'Yeh product ab available nahi. Hata dein.',
    'out_of_stock': 'Stock khatam ho gaya hai.',
    'store_closed': 'Store abhi band hai.',
}


# ---------------------------------------------------------------- chhote helpers

def _money(v):
    try:
        return Decimal(str(v)).quantize(CENT)
    except Exception:
        return ZERO


def _int(v, default=None):
    """Sirf asli integer (bool / float string / khali nahi). Ghalat ho to default."""
    if isinstance(v, bool):
        return default
    try:
        if isinstance(v, float):
            return int(v) if v == int(v) else default
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def _load_products(ids):
    """{product_id: Product} - sirf live (active + approved + store approved), stock + offer ke sath."""
    ids = [i for i in ids if i]
    if not ids:
        return {}
    qs = _with_stock(_live_catalog().filter(pk__in=ids)).select_related(
        'category', 'brand', 'unit', 'vendor__portal_profile')
    products = [p for p in qs if getattr(p.vendor, 'portal_profile', None) is not None]
    vendor_offers.overlay(products)
    return {p.pk: p for p in products}


def _stock_of(p):
    return int(getattr(p, 'total_stock', 0) or 0)


def _is_open(p):
    vp = getattr(p.vendor, 'portal_profile', None)
    return bool(vp and vp.is_open_now)


def _item_for(p, qty):
    """Cart (session jaisa) ki ek entry."""
    return {
        'product_id': p.pk,
        'name': p.name,
        'price': float(get_product_final_price(p)),
        'quantity': qty,
        'image': p.image.url if p.image else None,
        'vendor_id': p.vendor_id or 0,
    }


def _get_cart(customer):
    cart, _created = CustomerCart.objects.get_or_create(customer=customer)
    return cart


def _clean_items(raw):
    """Server mein save cart ka dict: sirf theek shakal wali entries."""
    out = {}
    if not isinstance(raw, dict):
        return out
    for key, it in raw.items():
        if not isinstance(it, dict):
            continue
        pid = _int(it.get('product_id'))
        qty = _int(it.get('quantity'))
        if not pid or not qty or qty < 1:
            continue
        out[str(pid)] = it
    return out


# ---------------------------------------------------------------- cart ka jawab (qeemat / stock taza)

def build_cart(items, customer=None):
    """(payload, new_items). `items` web-session jaisa dict. Qeemat naye sire se (web jaisi) lagti hai.

    new_items: items jin mein taza qeemat / naam / `price_was` lagi hai (caller chahe to save kare).
    Phase C8 checkout isi ko dobara use karega (payload['can_checkout'], payload['checkout_message']).
    """
    items = _clean_items(items)
    products = _load_products([_int(it.get('product_id')) for it in items.values()])

    new_items = {}
    lines = []
    calc_cart = {}
    count = 0
    price_changed = False
    has_issues = False

    for key, it in items.items():
        pid = _int(it.get('product_id'))
        qty = min(_int(it.get('quantity'), 1), MAX_QTY)
        p = products.get(pid)
        stored_price = _money(it.get('price') or 0)
        count += qty

        if p is None:
            # hata hua / inactive / rejected / store approved nahi: dikhao magar total mein na jodo
            new_items[key] = dict(it)
            lines.append({
                'product_id': pid, 'name': it.get('name') or 'Product', 'image': it.get('image'), 'unit': '',
                'price': _f(stored_price), 'old_price': None, 'discount_percent': None, 'quantity': qty,
                'line_total': _f(stored_price * qty), 'stock': 0, 'max_qty': 0, 'store_id': None,
                'store_name': '', 'issue': 'unavailable', 'issue_message': ISSUE_TEXT['unavailable'],
                'price_changed': False, 'price_was': None,
            })
            has_issues = True
            continue

        vp = p.vendor.portal_profile
        card = _product_json(p, vp)
        final = _money(get_product_final_price(p))
        stock = _stock_of(p)

        ni = dict(it)
        ni.update({'name': p.name, 'price': float(final), 'image': p.image.url if p.image else None,
                   'vendor_id': p.vendor_id or 0})
        was = it.get('price_was')
        if abs(final - stored_price) >= CENT and stored_price > 0:
            ni['price_was'] = float(stored_price)       # qeemat abhi badli: alert
            was = ni['price_was']
        new_items[key] = ni

        issue = ''
        issue_msg = ''
        if not _is_open(p):
            issue, issue_msg = 'store_closed', card.get('closed_message') or ISSUE_TEXT['store_closed']
        elif stock <= 0:
            issue, issue_msg = 'out_of_stock', ISSUE_TEXT['out_of_stock']
        elif qty > stock:
            issue, issue_msg = 'low_stock', f'Sirf {stock} bache hain. Quantity kam karein.'
        if issue:
            has_issues = True
        changed = bool(was)
        price_changed = price_changed or changed

        lines.append({
            'product_id': p.pk, 'name': p.name, 'image': card['image'], 'unit': card['unit'],
            'price': _f(final), 'old_price': card['old_price'], 'discount_percent': card['discount_percent'],
            'quantity': qty, 'line_total': _f(final * qty), 'stock': stock, 'max_qty': min(stock, MAX_QTY),
            'store_id': vp.pk, 'store_name': vp.business_name,
            'issue': issue, 'issue_message': issue_msg,
            'price_changed': changed, 'price_was': _f(was) if changed else None,
        })
        calc_cart[key] = {'product_id': p.pk, 'name': p.name, 'price': float(final), 'quantity': qty,
                          'vendor_id': p.vendor_id or 0}

    data = calculate_cart_data(calc_cart, customer=customer)
    subtotal = _money(data['subtotal'])
    delivery = _money(data['delivery_charges'])
    total = _money(data['total_amount'])
    rules = data.get('store')

    store = None
    min_order = ZERO
    min_ok = True
    short_by = ZERO
    if rules and rules.get('is_vendor_store'):
        prof = rules['profile']
        min_order = _money(rules['min_order'])
        min_ok = bool(rules['min_ok'])
        short_by = _money(rules['short_by'])
        store = {
            'id': prof.pk, 'name': prof.business_name, 'is_open': bool(rules['is_open']),
            'closed_message': rules['closed_message'], 'delivery_time': rules['time_text'],
            'delivery_fee': _f(rules['delivery_fee']),
        }

    free = data.get('free_delivery_progress')
    free_json = None
    if free:
        free_json = {'threshold': _f(free['threshold']), 'remaining': _f(free['remaining']),
                     'percent': max(0, min(100, int(free['percent']))), 'unlocked': bool(free['unlocked'])}

    message = ''
    if calc_cart:
        message = store_orders.validate_cart_for_order(calc_cart, subtotal) or ''
    notices = []
    issue_notice = 'Kuch items abhi order nahi ho sakte. Un ko theek ya hata dein.'
    if price_changed:
        notices.append('Kuch items ki qeemat badal gayi hai. Naya total dekh lein.')
    if has_issues:
        notices.append(issue_notice)
    can_checkout = bool(calc_cart) and not has_issues and not message
    if has_issues and not message:
        message = issue_notice

    payload = {
        'items': lines,
        'count': count,
        'lines': len(lines),
        'subtotal': _f(subtotal),
        'delivery_fee': _f(delivery),
        'delivery_is_free': bool(calc_cart) and delivery <= 0,
        'delivery_time': store['delivery_time'] if store else '',
        'total': _f(total),
        'store': store,
        'min_order': _f(min_order),
        'min_ok': min_ok,
        'short_by': _f(short_by),
        'free_delivery': free_json,
        'price_changed': price_changed,
        'has_issues': has_issues,
        'can_checkout': can_checkout,
        'checkout_message': message,
        'notices': notices,
        'currency': CURRENCY,
    }
    return payload, new_items


def _reply(payload, message='', status=200, **extra):
    out = {'ok': True, 'cart': payload}
    if message:
        out['message'] = message
    out.update(extra)
    return JsonResponse(out, status=status)


def _synced(customer):
    """Cart load karo; qeemat badli ho to naya dam save (row lock ke sath) aur taza payload do."""
    cart = _get_cart(customer)
    payload, new_items = build_cart(cart.items, customer)
    if new_items != _clean_items(cart.items):
        with transaction.atomic():
            cart = CustomerCart.objects.select_for_update().get(pk=cart.pk)
            payload, new_items = build_cart(cart.items, customer)
            cart.items = new_items
            cart.save(update_fields=['items', 'updated_at'])
    return payload


def _locked_cart(customer):
    """transaction.atomic ke andar chalayein: is customer ke cart ki row lock."""
    cart = _get_cart(customer)
    return CustomerCart.objects.select_for_update().get(pk=cart.pk)


def _save(cart, items, customer):
    payload, new_items = build_cart(items, customer)
    cart.items = new_items
    cart.save(update_fields=['items', 'updated_at'])
    return payload


def _area_for(request, profile, body):
    """Area: body mein 'area' ho (khali = sab) to wohi, warna C4 wala resolve_area (default address)."""
    if isinstance(body, dict) and 'area' in body:
        return _clean_area(body.get('area'))
    if hasattr(body, 'get') and body.get('area') is not None:
        return _clean_area(body.get('area'))
    area, _src = resolve_area(request, profile)
    return area


def _read_qty_items(raw):
    """Body ki `items` list -> [(product_id, qty)] (duplicate jama, hadd ke andar). Ghalat shakal par None."""
    if not isinstance(raw, list) or len(raw) > MAX_LINES * 2:
        return None
    merged = {}
    for r in raw:
        if not isinstance(r, dict):
            continue
        pid = _int(r.get('product_id'))
        qty = _int(r.get('quantity', 1))
        if not pid or pid < 1 or qty is None or qty < 1:
            continue
        merged[pid] = min(merged.get(pid, 0) + qty, MAX_QTY)
    return list(merged.items())[:MAX_LINES]


# ---------------------------------------------------------------- GET cart/

@customer_api(['GET'])
def api_cart(request, profile):
    return _reply(_synced(profile.customer))


@customer_api(['GET'])
def api_cart_count(request, profile):
    cart = _get_cart(profile.customer)
    items = _clean_items(cart.items)
    count = sum(min(_int(it.get('quantity'), 0), MAX_QTY) for it in items.values())
    return JsonResponse({'ok': True, 'count': count, 'lines': len(items)})


# ---------------------------------------------------------------- POST cart/add/

@customer_api(['POST'])
def api_cart_add(request, profile):
    body = _data(request)
    pid = _int(body.get('product_id'))
    if not pid or pid < 1:
        return _err('Product theek nahi.', 400, code='bad_product')
    qty = _int(body.get('quantity', 1))             # na bheja to 1; ghalat (abc, 1.5) to error
    if qty is None or qty < 1:
        return _err('Quantity kam az kam 1 honi chahiye.', 400, code='bad_qty')
    if qty > MAX_QTY:
        return _err(f'Quantity bohat zyada hai (zyada se zyada {MAX_QTY}).', 400, code='bad_qty')
    replace = str(body.get('replace_cart', '')).lower() in ('1', 'true', 'yes')

    product = _load_products([pid]).get(pid)
    if product is None:
        return _err('Yeh product nahi mila.', 404, code='not_found')
    vp = product.vendor.portal_profile
    if not vp.is_open_now:
        return _err(f'{vp.business_name} abhi band hai, baad mein order karein.', 409, code='store_closed')
    area = _area_for(request, profile, body)
    if area and not store_serves_area(vp.city, area, vp.delivery_areas):
        return _err(f'{vp.business_name} {area} mein deliver nahi karta.', 409, code='not_served')
    stock = _stock_of(product)
    if stock <= 0:
        return _err('Yeh product abhi available nahi (stock khatam).', 409, code='out_of_stock')

    with transaction.atomic():
        cart = _locked_cart(profile.customer)
        items = _clean_items(cart.items)

        new_store = product.vendor_id or 0
        current = store_orders.cart_store_id(items)
        if items and current is not None and current != new_store:
            if not replace:
                cur_name, new_name = store_orders.store_name(current), store_orders.store_name(new_store)
                return _err(f'Aap ke cart mein "{cur_name}" ka maal hai. Purana cart khali karke "{new_name}" '
                            f'ka maal lein?', 409, code='cart_conflict', current_store=cur_name, new_store=new_name)
            items = {}

        key = str(pid)
        existing = _int(items.get(key, {}).get('quantity'), 0) if key in items else 0
        new_qty = existing + qty
        if new_qty > stock:
            left = max(stock - existing, 0)
            msg = (f'Sirf {stock} units available hain.' if not existing else
                   f'Sirf {stock} units available hain (cart mein {existing} hain).')
            return _err(msg, 409, code='stock', max_qty=stock, in_cart=existing, can_add_more=left)
        if key not in items and len(items) >= MAX_LINES:
            return _err('Cart mein is se zyada alag items nahi aa sakte.', 400, code='cart_full')

        items[key] = _item_for(product, new_qty)
        payload = _save(cart, items, profile.customer)
    return _reply(payload, f'{product.name} cart mein add ho gaya.', added={'product_id': pid, 'quantity': qty})


# ---------------------------------------------------------------- POST cart/update/ , remove/ , clear/ , ack/

@customer_api(['POST'])
def api_cart_update(request, profile):
    body = _data(request)
    pid = _int(body.get('product_id'))
    qty = _int(body.get('quantity'))
    if not pid or pid < 1:
        return _err('Product theek nahi.', 400, code='bad_product')
    if qty is None or qty < 0:
        return _err('Quantity theek nahi.', 400, code='bad_qty')
    if qty > MAX_QTY:
        return _err(f'Quantity bohat zyada hai (zyada se zyada {MAX_QTY}).', 400, code='bad_qty')

    with transaction.atomic():
        cart = _locked_cart(profile.customer)
        items = _clean_items(cart.items)
        key = str(pid)
        if key not in items:
            return _err('Yeh item aap ke cart mein nahi hai.', 404, code='not_in_cart')
        if qty == 0:
            del items[key]
            return _reply(_save(cart, items, profile.customer))
        current = _int(items[key].get('quantity'), 0)
        product = _load_products([pid]).get(pid)
        if qty > current:               # barhane par hi stock dekhte hain (kam karna hamesha ho sakta hai)
            if product is None:
                return _err('Yeh product ab available nahi. Hata dein.', 409, code='unavailable')
            stock = _stock_of(product)
            if qty > stock:
                return _err(f'Sirf {stock} units available hain.', 409, code='stock', max_qty=stock, in_cart=current)
        if product is not None:
            items[key] = _item_for(product, qty)        # taza qeemat, price_was saaf
        else:
            items[key]['quantity'] = qty
            items[key].pop('price_was', None)
        return _reply(_save(cart, items, profile.customer))


@customer_api(['POST'])
def api_cart_remove(request, profile):
    body = _data(request)
    pid = _int(body.get('product_id'))
    if not pid or pid < 1:
        return _err('Product theek nahi.', 400, code='bad_product')
    with transaction.atomic():
        cart = _locked_cart(profile.customer)
        items = _clean_items(cart.items)
        items.pop(str(pid), None)       # pehle se na ho to bhi theek (dobara tap par error nahi)
        return _reply(_save(cart, items, profile.customer))


@customer_api(['POST'])
def api_cart_clear(request, profile):
    with transaction.atomic():
        cart = _locked_cart(profile.customer)
        return _reply(_save(cart, {}, profile.customer))


@customer_api(['POST'])
def api_cart_ack(request, profile):
    """Customer ne 'qeemat badal gayi' alert dekh liya: price_was saaf."""
    with transaction.atomic():
        cart = _locked_cart(profile.customer)
        items = _clean_items(cart.items)
        for it in items.values():
            it.pop('price_was', None)
        return _reply(_save(cart, items, profile.customer))


# ---------------------------------------------------------------- POST cart/merge/

@customer_api(['POST'])
def api_cart_merge(request, profile):
    """Guest ka local cart login ke baad server cart mein.

    - Server cart mein jo pehle se hai wahi store rehta hai; doosre store ka guest maal chhoot jata hai (`skipped`).
    - Same product dono mein ho to bari quantity (dobara bhejne par double nahi hoti), stock se zyada nahi.
    - Khatam / hata hua product chhoot jata hai (`skipped`).
    """
    body = _data(request)
    wanted = _read_qty_items(body.get('items'))
    if wanted is None:
        return _err('Cart ki list theek nahi.', 400, code='bad_items')

    products = _load_products([pid for pid, _q in wanted])
    skipped = []
    merged = 0
    with transaction.atomic():
        cart = _locked_cart(profile.customer)
        items = _clean_items(cart.items)
        store = store_orders.cart_store_id(items) if items else None
        for pid, qty in wanted:
            p = products.get(pid)
            if p is None:
                skipped.append({'product_id': pid, 'reason': 'unavailable'})
                continue
            stock = _stock_of(p)
            if stock <= 0:
                skipped.append({'product_id': pid, 'name': p.name, 'reason': 'out_of_stock'})
                continue
            vendor = p.vendor_id or 0
            if store is not None and store != vendor:
                skipped.append({'product_id': pid, 'name': p.name, 'reason': 'other_store'})
                continue
            key = str(pid)
            if key not in items and len(items) >= MAX_LINES:
                skipped.append({'product_id': pid, 'name': p.name, 'reason': 'cart_full'})
                continue
            have = _int(items.get(key, {}).get('quantity'), 0) if key in items else 0
            final_qty = min(max(have, qty), stock, MAX_QTY)
            items[key] = _item_for(p, final_qty)
            store = vendor
            merged += 1
        payload = _save(cart, items, profile.customer)

    msg = ''
    if skipped:
        msg = 'Kuch items cart mein nahi aa sake (khatam ya doosre store ke).'
    return _reply(payload, msg, merged=merged, skipped=skipped)


# ---------------------------------------------------------------- POST cart/preview/ (guest bhi)

@customer_api_optional(['POST'])
def api_cart_preview(request, profile):
    """Guest ka local cart dikhane ke liye: qeemat, total, warning. Kuch save nahi hota."""
    body = _data(request)
    wanted = _read_qty_items(body.get('items'))
    if wanted is None:
        return _err('Cart ki list theek nahi.', 400, code='bad_items')

    products = _load_products([pid for pid, _q in wanted])
    items = {}
    for pid, qty in wanted:
        p = products.get(pid)
        if p is None:
            items[str(pid)] = {'product_id': pid, 'name': 'Product', 'price': 0, 'quantity': qty, 'image': None,
                               'vendor_id': 0}
        else:
            items[str(pid)] = _item_for(p, qty)
    payload, _new = build_cart(items, profile.customer if profile is not None else None)
    return _reply(payload)
