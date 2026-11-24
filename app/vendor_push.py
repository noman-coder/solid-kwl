"""
Vendor app ko PUSH notification (Firebase Cloud Messaging) - app band ho / screen lock ho tab bhi.

FCM ka sender `rider_push.py` ka hi hai (service account, access token, dead-token pehchan): yahan dobara
nahi likha. Is file mein sirf vendor ka hissa hai: kis ko bhejna hai (VendorPushToken), kya likhna hai,
aur kab (naya order, cancel, rider cash, review, stock).

Setup: server par wahi secret `FCM_SERVICE_ACCOUNT_JSON` (rider push wala) - alag kuch nahi.
Secret na ho to server crash nahi karta, sirf ek dafa log likhta hai aur push chhod deta hai.

Usool: push order ke kaam ko kabhi nahi rokti.
  - Har public function try/except mein hai (ghalti sirf log hoti hai).
  - Order wale events transaction commit ke baad (`transaction.on_commit`) aur background thread mein jate hain.

Channels (vendor app V7 mein inhi naam ke channel banayegi):
  new_orders  -> 'Naye orders'  (alag awaaz)
  updates     -> 'Baqi updates' (cancel, cash, review, stock)

Message `data` mein hamesha 'type' hota hai (tap par app ko pata chale kahan kholna hai):
  new_order | order_cancelled | rider_cash | review | low_stock | out_of_stock | test
"""
import logging
import threading

from django.core.cache import cache
from django.db import transaction

from . import rider_push

logger = logging.getLogger(__name__)

NEW_ORDERS_CHANNEL = 'new_orders'
UPDATES_CHANNEL = 'updates'
TTL_ORDER = '3600s'            # naya order 1 ghanta tak phone ka intezar kare (rider se lambi: vendor ka phone band reh sakta hai)
TTL_UPDATE = '86400s'          # baqi khabrein 1 din
STOCK_ALERT_SECONDS = 24 * 3600   # ek product ka ek hi alert (low / khatam alag alag) din mein ek dafa

_warned = {'cfg': False}


# ---------------------------------------------------------------- config / tokens

def is_configured():
    """FCM_SERVICE_ACCOUNT_JSON theek set hai? Na ho to push chup chap band (ek dafa log)."""
    ok = rider_push._service_account() is not None
    if not ok and not _warned['cfg']:
        _warned['cfg'] = True
        logger.info('Vendor push band hai: FCM_SERVICE_ACCOUNT_JSON set nahi.')
    return ok


def _vendor_id(vendor):
    """Vendor, VendorProfile ya seedha vendor id - teeno chalte hain."""
    if vendor is None:
        return None
    if hasattr(vendor, 'vendor_id'):         # VendorProfile
        return vendor.vendor_id
    return getattr(vendor, 'pk', vendor)


def tokens_for(vendor):
    """Is vendor ke sab phones ke FCM tokens."""
    from .models import VendorPushToken
    vid = _vendor_id(vendor)
    if not vid:
        return []
    return list(VendorPushToken.objects.filter(profile__vendor_id=vid).values_list('token', flat=True))


# ---------------------------------------------------------------- sending

def _deliver(tokens, title, body, data=None, tag=None, channel_id=None, ttl=None):
    """Blocking: bhejo aur FCM ne jo tokens 'dead' bataye (app uninstall / token badla) DB se hata do."""
    res = rider_push.send_to_tokens(tokens, title, body, data=data, tag=tag, channel_id=channel_id, ttl=ttl)
    logger.info('Vendor push: sent=%s failed=%s dead=%s', res['sent'], res['failed'], len(res['dead']))
    if res['dead']:
        from .models import VendorPushToken
        VendorPushToken.objects.filter(token__in=res['dead']).delete()
    return res


def push_async(tokens, title, body, data=None, tag=None, channel_id=None, ttl=None):
    """Background thread mein bhejo (request / transaction ko na roke)."""
    tokens = list(tokens or [])
    if not tokens or not is_configured():
        return

    def _run():
        try:
            _deliver(tokens, title, body, data, tag, channel_id, ttl)
        except Exception:
            logger.exception('Vendor push thread failed')
        finally:
            from django.db import connection
            connection.close()

    threading.Thread(target=_run, name='vendor-push', daemon=True).start()


def notify_vendor(vendor, title, body, data=None, *, channel=UPDATES_CHANNEL, tag=None, ttl=None):
    """Is vendor ke sab phones ko push (non-blocking). Return: kitne phones ko bheji gayi (0 = kuch nahi gaya).

    `vendor`: Vendor / VendorProfile / vendor id. Kabhi exception nahi uthati.
    """
    try:
        if not is_configured():
            return 0
        tokens = tokens_for(vendor)
        if not tokens:
            return 0
        push_async(tokens, title, body, data=data, tag=tag, channel_id=channel,
                   ttl=ttl or (TTL_ORDER if channel == NEW_ORDERS_CHANNEL else TTL_UPDATE))
        return len(tokens)
    except Exception:
        logger.exception('notify_vendor failed')
        return 0


def _on_commit(fn):
    """Transaction chal rahi ho to commit ke baad, warna foran. fn khud try/except mein honi chahiye."""
    transaction.on_commit(fn)


# ---------------------------------------------------------------- events

def _money(value):
    try:
        return f"Rs. {value:,.0f}"
    except Exception:
        return ''


def notify_new_order(order_id):
    """Naya order aaya - vendor ko foran batao (commit ke baad)."""
    def _go():
        try:
            if not is_configured():
                return
            from .customer import store_orders
            from .models import SaleOrder
            order = SaleOrder.objects.select_related('customer').filter(pk=order_id).first()
            if not order or not order.vendor_id:
                return
            try:
                total = _money(store_orders.order_payable_total(order))
            except Exception:
                total = ''
            items = order.items.count()
            cust = getattr(order.customer, 'name', '') or 'Customer'
            parts = [f'{cust}', f'{items} item(s)']
            if total:
                parts.append(total)
            notify_vendor(
                order.vendor_id,
                f'🛒 Naya order #{order.order_no}',
                ' - '.join(parts) + '. Accept ya Reject karein.',
                data={'type': 'new_order', 'order_id': order.pk, 'order_no': order.order_no},
                channel=NEW_ORDERS_CHANNEL, tag=f'order-{order.pk}')
        except Exception:
            logger.exception('Vendor push (new order) failed for order %s', order_id)

    _on_commit(_go)


def notify_order_cancelled(order_id):
    """Customer ne order cancel kar diya (vendor ke apne reject par ye nahi jati)."""
    def _go():
        try:
            if not is_configured():
                return
            from .models import SaleOrder
            order = SaleOrder.objects.filter(pk=order_id).first()
            if not order or not order.vendor_id:
                return
            notify_vendor(
                order.vendor_id,
                f'❌ Order #{order.order_no} cancel ho gaya',
                'Customer ne ye order cancel kar diya hai.',
                data={'type': 'order_cancelled', 'order_id': order.pk, 'order_no': order.order_no},
                channel=UPDATES_CHANNEL, tag=f'order-{order.pk}')
        except Exception:
            logger.exception('Vendor push (cancel) failed for order %s', order_id)

    _on_commit(_go)


def notify_rider_cash(vendor_id, rider_name, amount, handover_id):
    """Rider ne cash handover bheja - vendor confirm kare."""
    def _go():
        try:
            if not is_configured() or not vendor_id:
                return
            notify_vendor(
                vendor_id,
                f'💵 Rider {rider_name} ne {_money(amount)} cash diya',
                'Cash mil gaya ho to app mein Confirm karein.',
                data={'type': 'rider_cash', 'handover_id': handover_id},
                channel=UPDATES_CHANNEL, tag=f'cash-{handover_id}')
        except Exception:
            logger.exception('Vendor push (rider cash) failed for handover %s', handover_id)

    _on_commit(_go)


def notify_new_review(order_id):
    """Customer ne store ko rating di."""
    def _go():
        try:
            if not is_configured():
                return
            from .models import OrderReview
            review = OrderReview.objects.select_related('sale_order').filter(sale_order_id=order_id).first()
            if not review or not review.vendor_id or not review.vendor_rating:
                return
            stars = int(review.vendor_rating)
            comment = (review.vendor_comment or '').strip()[:120]
            notify_vendor(
                review.vendor_id,
                f'⭐ Naya review: {stars}/5',
                comment or f'Order #{review.sale_order.order_no} par customer ne rating di.',
                data={'type': 'review', 'order_id': order_id, 'rating': stars},
                channel=UPDATES_CHANNEL, tag=f'review-{order_id}')
        except Exception:
            logger.exception('Vendor push (review) failed for order %s', order_id)

    _on_commit(_go)


def _first_time(key, seconds):
    """True = ye pehli dafa hai (is muddat mein). Cache kharab ho to False: spam se behtar hai ek alert chhoot jaye."""
    try:
        return bool(cache.add(key, 1, seconds))
    except Exception:
        logger.exception('vendor_push dedupe cache error')
        return False


def check_stock_alert(product_id):
    """Vendor ke product ka stock kam / khatam ho to ek push. Har product ka har qism ka alert din mein ek dafa.

    Commit ke baad stock dobara hisab karti hai (sab warehouse ka total), is liye adhoori save par
    jhoota alert nahi aata. Threshold product ki apni `low_stock_threshold` hai.
    """
    def _go():
        try:
            if not is_configured():
                return
            from django.db.models import Sum
            from .models import Inventory, Product
            p = (Product.objects.filter(pk=product_id, vendor__isnull=False)
                 .values('name', 'vendor_id', 'low_stock_threshold').first())
            if not p:
                return
            total = Inventory.objects.filter(product_id=product_id).aggregate(s=Sum('stock'))['s'] or 0
            if total <= 0:
                kind, title, body = ('out_of_stock', f"🚫 {p['name']} ka stock khatam",
                                     'Ye product ab customer ko nahi bik sakta. Stock add karein.')
            elif total < (p['low_stock_threshold'] or 0):
                left = f'{total:g}'
                kind, title, body = ('low_stock', f"⚠️ {p['name']} ka stock kam hai",
                                     f"Sirf {left} bacha hai (kam az kam {p['low_stock_threshold']:g}). Stock add karein.")
            else:
                return
            if not _first_time(f'vpush:stock:{kind}:{product_id}', STOCK_ALERT_SECONDS):
                return
            notify_vendor(p['vendor_id'], title, body,
                          data={'type': kind, 'product_id': product_id},
                          channel=UPDATES_CHANNEL, tag=f'stock-{product_id}')
        except Exception:
            logger.exception('Vendor push (stock) failed for product %s', product_id)

    _on_commit(_go)
