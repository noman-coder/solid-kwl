"""Vendor ka stock add / minus (Vendor app Phase V10) - API ki SHARED logic.

Naya business logic nahi: stock add `_add_stock` (Inventory + StockBatch, margin rule wahi) se, aur stock minus
usi FIFO tareeqe se jis se bikri batch use karti hai (purane batch pehle). Har kamyab tabdeeli ka record
`VendorStockLog` mein (kitna tha -> kitna hua, wajah).

Usool:
  - Negative stock nahi ban sakta; jo stock pending orders ke liye `reserved` hai woh bhi minus nahi hota.
  - Sab kuch transaction.atomic + select_for_update (double tap / do phone par ek hi chale).
  - `request_key` wahi dobara aaye (net toot kar retry) to doosri dafa stock nahi badalta.
"""
import logging
from decimal import Decimal, InvalidOperation

from django.core.exceptions import ValidationError
from django.db import transaction
from django.db.models import F

from ..models import Inventory, Product, StockBatch, VendorStockLog
from ..vendor_commission import commission_percent, vendor_share
from .views_vendor_portal import _add_stock

logger = logging.getLogger(__name__)

MAX_QTY = Decimal('1000000')
MIN_QTY = Decimal('0.001')
NOTE_MAX = 200

ADD_REASONS = {'purchase': 'Naya maal aaya', 'return': 'Wapsi', 'correction': 'Ginti theek ki', 'other': 'Doosri wajah'}
MINUS_REASONS = {'damaged': 'Kharab / toota', 'expired': 'Expire', 'lost': 'Gum / chori',
                 'correction': 'Ginti theek ki', 'other': 'Doosri wajah'}
REASONS = {'add': ADD_REASONS, 'minus': MINUS_REASONS}


def _num(v):
    try:
        f = float(v or 0)
    except (TypeError, ValueError):
        return 0
    return int(f) if f == int(f) else round(f, 3)


def parse_qty(raw):
    """Quantity string/number -> Decimal (0.001 .. 1,000,000) ya None."""
    if raw is None or isinstance(raw, bool):
        return None
    try:
        d = Decimal(str(raw).strip())
    except (InvalidOperation, ValueError):
        return None
    if not d.is_finite() or d < MIN_QTY or d > MAX_QTY:
        return None
    return d.quantize(Decimal('0.001'))


def adjust_stock(profile, product_id, mode, qty_raw, reason='other', note='', request_key='', warehouse=None,
                 source='app'):
    """Ek product ka stock add/minus.

    Return: (status, data)
      ('ok', {'before', 'after', 'qty', 'kind', 'log_id'})
      ('same', {...})   -> yahi request_key pehle lag chuki hai, dobara nahi lagi
      ('error', {'error': msg, 'code': code})
    """
    vendor = profile.vendor
    if mode not in REASONS:
        return 'error', {'error': 'Add ya minus chunein.', 'code': 'bad_mode'}
    qty = parse_qty(qty_raw)
    if qty is None:
        return 'error', {'error': 'Quantity sahi likhein (0.001 se 1,000,000 tak).', 'code': 'bad_qty'}
    reason = (reason or 'other').strip().lower()
    if reason not in REASONS[mode]:
        reason = 'other'
    note = (note or '').strip()[:NOTE_MAX]
    request_key = (request_key or '').strip()[:64]
    if not warehouse:
        return 'error', {'error': 'Shop mein warehouse set nahi hai.', 'code': 'no_warehouse'}

    try:
        with transaction.atomic():
            product = Product.objects.select_for_update().filter(pk=product_id, vendor=vendor).first()
            if product is None:                      # doosre vendor ka / maujood nahi: ek hi jawab (leak nahi)
                return 'error', {'error': 'Ye product nahi mila.', 'code': 'not_found'}
            if product.approval_status != 'approved':
                return 'error', {'error': 'Sirf approved product ka stock badal sakte hain.', 'code': 'not_approved'}

            if request_key:
                dup = VendorStockLog.objects.filter(profile=profile, product=product, request_key=request_key).first()
                if dup:
                    return 'same', {'before': _num(dup.before), 'after': _num(dup.after), 'qty': _num(dup.qty),
                                    'kind': dup.kind, 'log_id': dup.pk}

            inv = Inventory.objects.select_for_update().filter(product=product, warehouse=warehouse).first()
            before = float(inv.stock) if inv else 0.0
            q = float(qty)

            if mode == 'add':
                price = (product.original_price if product.original_price and product.original_price > 0
                         else product.price)
                cost = vendor_share(price, product.discount_percentage or 0, commission_percent(profile))
                _add_stock(product, warehouse, q, cost, price)
            else:
                reserved = float(inv.reserved_stock) if inv else 0.0
                available = before - reserved
                if q > available + 1e-9:
                    if available <= 0:
                        return 'error', {'error': 'Is product ka stock pehle hi khatam hai.', 'code': 'no_stock'}
                    return 'error', {'error': f'Itna stock nahi hai. Maujooda: {_num(available)}.', 'code': 'too_much'}
                _consume_fifo(product, warehouse, q)
                Inventory.update_stock(product, -q, warehouse)

            after_inv = Inventory.objects.filter(product=product, warehouse=warehouse).first()
            after = float(after_inv.stock) if after_inv else 0.0
            if after < -1e-9:                         # hifazat: kabhi nahi hona chahiye
                raise ValidationError('Stock negative nahi ho sakta.')
            log = VendorStockLog.objects.create(
                product=product, profile=profile, kind=mode, qty=q, before=before, after=after,
                reason=reason, note=note, source=source, request_key=request_key)
        return 'ok', {'before': _num(before), 'after': _num(after), 'qty': _num(q), 'kind': mode, 'log_id': log.pk}
    except ValidationError as exc:
        try:
            msg = '; '.join(exc.messages)
        except Exception:
            msg = 'Stock update nahi ho saka.'
        return 'error', {'error': msg or 'Stock update nahi ho saka.', 'code': 'invalid'}
    except Exception:
        logger.exception('Vendor stock adjust failed (product %s)', product_id)
        return 'error', {'error': 'Stock update nahi ho saka. Dobara koshish karein.', 'code': 'server'}


def _consume_fifo(product, warehouse, qty):
    """Purane batch pehle (bikri jaisa). Batch records kam hon to jitna hai utna hi lete hain
    (Inventory ka negative check alag se hai)."""
    left = qty
    batches = (StockBatch.objects.select_for_update()
               .filter(product=product, warehouse=warehouse, remaining_qty__gt=0).order_by('id'))
    for b in batches:
        if left <= 1e-9:
            break
        take = min(left, b.remaining_qty)
        StockBatch.objects.filter(pk=b.pk).update(remaining_qty=F('remaining_qty') - take)
        left -= take


def log_quick_update_add(profile, product, qty, before, after, request_key=''):
    """Quick update ke 'naya stock' ka record (sirf history; stock pehle hi lag chuka hota hai). Kabhi exception nahi."""
    try:
        VendorStockLog.objects.create(product=product, profile=profile, kind='add', qty=float(qty),
                                      before=float(before), after=float(after), reason='purchase',
                                      source='quick_update', request_key=(request_key or '')[:64])
    except Exception:
        logger.exception('Vendor stock log (quick update) failed')
