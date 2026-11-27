"""
Customer app ko PUSH notification (Firebase Cloud Messaging) - app band ho / screen lock ho tab bhi.

FCM ka sender `rider_push.py` ka hi hai (service account, access token, dead-token pehchan): yahan dobara
nahi likha (vendor_push.py bhi yahi karta hai). Is file mein sirf customer ka hissa hai: kis ko bhejna hai
(CustomerPushToken), kya likhna hai, aur kab (order ka status badalne par).

Setup: server par wahi secret `FCM_SERVICE_ACCOUNT_JSON` (rider / vendor push wala) - alag kuch nahi.
Customer app ka Firebase project alag ho to us ka service-account JSON yahi secret ban jata hai
(ek server par ek hi project ka key chalta hai). Secret na ho to server crash nahi karta, sirf ek dafa log
likhta hai aur push chhod deta hai.

Usool: push order ke kaam ko kabhi nahi rokti.
  - Har public function try/except mein hai (ghalti sirf log hoti hai).
  - Order wale events transaction commit ke baad (`transaction.on_commit`) aur background thread mein jate hain.
  - Ek hi event dobara save() se dobara push nahi hota (cache dedupe).

Hook kahan lagta hai: `customer_push_signals.py` (SaleOrder / DeliveryInfo ka status kahin se bhi badle -
vendor app, vendor portal, admin, rider app - signal pakad leta hai; purane views mein koi tabdeeli nahi).

Channels (customer app C11 mein inhi naam ke channel banayegi):
  order_updates -> 'Order updates' (high importance)
  offers        -> 'Offers' (alag, customer band kar sakta hai)

Message `data` mein hamesha 'type' hota hai (tap par app ko pata chale kahan kholna hai) aur order wale events
mein 'order_id' + 'order_no' (tap -> Order Detail):
  order_accepted | order_rejected | order_cancelled | order_ready | rider_assigned | order_on_the_way |
  order_delivered | offer | test
"""
import logging
import threading

from django.core.cache import cache
from django.db import transaction

from . import rider_push

logger = logging.getLogger(__name__)

ORDER_CHANNEL = 'order_updates'
OFFERS_CHANNEL = 'offers'
TTL_ORDER = '21600s'           # order ki khabar 6 ghante tak phone ka intezar kare (purani status khabar kaam ki nahi)
TTL_OFFER = '86400s'           # offer 1 din
DEDUPE_SECONDS = 24 * 3600     # ek order ka ek event din mein ek dafa

_warned = {'cfg': False}


# ---------------------------------------------------------------- config / tokens

def is_configured():
    """FCM_SERVICE_ACCOUNT_JSON theek set hai? Na ho to push chup chap band (ek dafa log)."""
    ok = rider_push._service_account() is not None
    if not ok and not _warned['cfg']:
        _warned['cfg'] = True
        logger.info('Customer push band hai: FCM_SERVICE_ACCOUNT_JSON set nahi.')
    return ok


def _customer_id(customer):
    """Customer, CustomerProfile ya seedha customer id - teeno chalte hain."""
    if customer is None:
        return None
    if hasattr(customer, 'customer_id'):         # CustomerProfile
        return customer.customer_id
    return getattr(customer, 'pk', customer)


def tokens_for(customer):
    """Is customer ke sab phones ke FCM tokens (band / delete hue account ke nahi)."""
    from .models import CustomerPushToken
    cid = _customer_id(customer)
    if not cid:
        return []
    return list(CustomerPushToken.objects
                .filter(customer_id=cid)
                .exclude(customer__portal_profile__user__is_active=False)
                .values_list('token', flat=True))


# ---------------------------------------------------------------- sending

def _deliver(tokens, title, body, data=None, tag=None, channel_id=None, ttl=None):
    """Blocking: bhejo aur FCM ne jo tokens 'dead' bataye (app uninstall / token badla) DB se hata do."""
    res = rider_push.send_to_tokens(tokens, title, body, data=data, tag=tag, channel_id=channel_id, ttl=ttl)
    logger.info('Customer push: sent=%s failed=%s dead=%s', res['sent'], res['failed'], len(res['dead']))
    if res['dead']:
        from .models import CustomerPushToken
        CustomerPushToken.objects.filter(token__in=res['dead']).delete()
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
            logger.exception('Customer push thread failed')
        finally:
            from django.db import connection
            connection.close()

    threading.Thread(target=_run, name='customer-push', daemon=True).start()


def notify_customer(customer, title, body, data=None, *, channel=ORDER_CHANNEL, tag=None, ttl=None):
    """Is customer ke sab phones ko push (non-blocking). Return: kitne phones ko bheji gayi (0 = kuch nahi gaya).

    `customer`: Customer / CustomerProfile / customer id. Kabhi exception nahi uthati.
    `channel`: ORDER_CHANNEL (order status) ya OFFERS_CHANNEL (naya coupon / offer).
    """
    try:
        if not is_configured():
            return 0
        tokens = tokens_for(customer)
        if not tokens:
            return 0
        push_async(tokens, title, body, data=data, tag=tag, channel_id=channel,
                   ttl=ttl or (TTL_OFFER if channel == OFFERS_CHANNEL else TTL_ORDER))
        return len(tokens)
    except Exception:
        logger.exception('notify_customer failed')
        return 0


def _on_commit(fn):
    """Transaction chal rahi ho to commit ke baad, warna foran. fn khud try/except mein honi chahiye."""
    transaction.on_commit(fn)


def _first_time(key, seconds=DEDUPE_SECONDS):
    """True = ye pehli dafa hai (is muddat mein). Cache kharab ho to False: spam se behtar hai ek alert chhoot jaye."""
    try:
        return bool(cache.add(key, 1, seconds))
    except Exception:
        logger.exception('customer_push dedupe cache error')
        return False


# ---------------------------------------------------------------- order events

def _messages(event, order, store, extra):
    """(title, body) Roman Urdu mein. `store` khali ho sakta hai (shop ka apna order)."""
    no = order.order_no
    shop = store or 'Store'
    if event == 'order_accepted':
        mins = getattr(order, 'prep_minutes', None)
        body = f'{shop} ne aap ka order qubool kar liya.'
        if mins:
            body += f' Tayyar hone mein taqreeban {mins} minute.'
        return f'✅ Order #{no} qubool ho gaya', body
    if event == 'order_rejected':
        reason = (order.reject_reason or '').strip()
        body = f'{shop} ye order qubool nahi kar saka.'
        if reason:
            body += f' Wajah: {reason}'
        return f'❌ Order #{no} qubool nahi hua', body
    if event == 'order_cancelled':
        return f'❌ Order #{no} cancel ho gaya', 'Aap ka order cancel kar diya gaya hai.'
    if event == 'order_ready':
        if extra.get('pickup'):
            return f'📦 Order #{no} tayyar hai', f'{shop} se apna order le jayein.'
        return f'📦 Order #{no} tayyar hai', f'{shop} ne order tayyar kar diya. Rider jald uthayega.'
    if event == 'rider_assigned':
        rider = extra.get('rider_name') or 'Rider'
        return '🏍️ Rider mil gaya', f'{rider} aap ka Order #{no} lene aa rahe hain.'
    if event == 'order_on_the_way':
        return '🛵 Order raste mein hai', f'Aap ka Order #{no} aap ki taraf aa raha hai. App mein track karein.'
    if event == 'order_delivered':
        return f'🎉 Order #{no} pahunch gaya', 'Order deliver ho gaya. Khareedari ka shukriya!'
    return None


def notify_order_event(order_id, event, *, dedupe_extra=''):
    """Order ke is event par us order ke customer ko push (commit ke baad, ek event ek dafa).

    event: order_accepted | order_rejected | order_cancelled | order_ready | rider_assigned |
           order_on_the_way | order_delivered
    Order dobara DB se parha jata hai (taza data); status mein tab tak tabdeeli ho gayi ho to bhi message
    event ke mutabiq jata hai. Kabhi exception nahi uthati.
    """
    def _go():
        try:
            if not is_configured():
                return
            from .models import DeliveryInfo, SaleOrder
            order = SaleOrder.objects.select_related('customer').filter(pk=order_id).first()
            if not order or not order.customer_id:
                return
            if not tokens_for(order.customer_id):
                return                      # is customer ke paas app / push nahi: dedupe key bhi kharch na karo
            if not _first_time(f'cpush:{order_id}:{event}:{dedupe_extra}'):
                return
            store = ''
            if order.vendor_id:
                from .customer.store_orders import store_name
                store = store_name(order.vendor_id) or ''
            extra = {}
            di = DeliveryInfo.objects.select_related('rider').filter(sale_order_id=order_id).first()
            if event == 'order_ready' and di and di.delivery_type == 'customer_pickup':
                extra['pickup'] = True
            if event == 'rider_assigned' and di and di.rider_id:
                extra['rider_name'] = (getattr(di.rider, 'name', '') or '').strip()
            msg = _messages(event, order, store, extra)
            if not msg:
                return
            title, body = msg
            notify_customer(
                order.customer_id, title, body,
                data={'type': event, 'order_id': order.pk, 'order_no': order.order_no},
                channel=ORDER_CHANNEL, tag=f'order-{order.pk}')
        except Exception:
            logger.exception('Customer push (%s) failed for order %s', event, order_id)

    try:
        _on_commit(_go)
    except Exception:
        logger.exception('Customer push (%s) could not be queued for order %s', event, order_id)
