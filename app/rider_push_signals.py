"""
Rider ko PUSH notification (app band ho tab bhi).

Kab jati hai:
  1. Vendor order "Ready" kare  -> sab ONLINE riders ko (jinke paas jagah hai: MAX_ACTIVE_ORDERS se kam orders)
  2. Vendor / admin kisi rider ko order de  -> sirf us rider ko ("Order aap ko diya gaya")
     (rider khud accept kare to us ko push nahi jati)

Same pattern jo order_status_emails.py ka hai: SaleOrder / DeliveryInfo kahin se bhi badle (vendor panel,
admin, API) - signal pakad leta hai, purane views mein koi tabdeeli nahi.
Push transaction commit hone ke baad, background thread mein jati hai. Koi ghalti sirf log hoti hai.
"""
import logging

from django.db import transaction
from django.db.models.signals import post_save, pre_save
from django.dispatch import receiver

from . import rider_push

logger = logging.getLogger(__name__)


def _order_text(order):
    from .customer import store_orders
    store = store_orders.store_name(order.vendor_id) if order.vendor_id else ''
    try:
        total = f"Rs. {store_orders.order_payable_total(order):,.0f}"
    except Exception:
        total = ''
    return store, total


def _ready_tokens():
    """Online riders ke tokens jin ke paas naya order lene ki jagah hai."""
    from django.db.models import Count
    from .customer.views_rider_portal import ACTIVE_STATUSES, MAX_ACTIVE_ORDERS
    from .models import DeliveryInfo, RiderProfile, RiderPushToken

    rider_ids = list(RiderProfile.objects.filter(is_active=True, is_online=True, push_tokens__isnull=False)
                     .values_list('pk', flat=True).distinct())
    if not rider_ids:
        return []
    busy = set(DeliveryInfo.objects.filter(rider_id__in=rider_ids, status__in=ACTIVE_STATUSES)
               .values('rider_id').annotate(n=Count('id')).filter(n__gte=MAX_ACTIVE_ORDERS)
               .values_list('rider_id', flat=True))
    free = [r for r in rider_ids if r not in busy]
    return list(RiderPushToken.objects.filter(rider_id__in=free).values_list('token', flat=True))


def notify_order_ready(order_id):
    """Order ready hua - online riders ko batao (commit ke baad)."""
    def _go():
        try:
            if not rider_push.is_configured():
                return
            from .models import DeliveryInfo, SaleOrder
            order = SaleOrder.objects.filter(pk=order_id).first()
            if not order or order.status != 'ready' or not order.vendor_id:
                return
            di = DeliveryInfo.objects.filter(sale_order=order).first()
            if di and di.rider_id and di.status != 'cancelled':
                return                      # vendor ne rider pehle hi chun liya: sab ko alert nahi
            tokens = _ready_tokens()
            if not tokens:
                return
            store, total = _order_text(order)
            total_txt = f' ({total})' if total else ''
            rider_push.push_async(
                tokens,
                '📦 Naya order tayyar hai',
                f"{store}: Order #{order.order_no}{total_txt}. Accept karne ke liye kholein.",
                data={'type': 'order_ready', 'order_id': order.pk, 'order_no': order.order_no},
                tag=f'order-{order.pk}')
        except Exception:
            logger.exception('Rider push (order ready) failed for order %s', order_id)

    transaction.on_commit(_go)


def notify_order_assigned(order_id, rider_id):
    """Order seedha is rider ko diya gaya - sirf use batao (commit ke baad)."""
    def _go():
        try:
            if not rider_push.is_configured():
                return
            from .models import RiderPushToken, SaleOrder
            order = SaleOrder.objects.filter(pk=order_id).first()
            tokens = list(RiderPushToken.objects.filter(rider_id=rider_id).values_list('token', flat=True))
            if not order or not tokens:
                return
            store, _total = _order_text(order)
            rider_push.push_async(
                tokens,
                '🏍️ Order aap ko mila',
                f"{store} se Order #{order.order_no} uthana hai.",
                data={'type': 'order_assigned', 'order_id': order.pk, 'order_no': order.order_no},
                tag=f'order-{order.pk}')
        except Exception:
            logger.exception('Rider push (assigned) failed for order %s', order_id)

    transaction.on_commit(_go)


def _register():
    from .models import DeliveryInfo, RiderProfile, SaleOrder

    # NOTE: order_status_emails apna `_old_status` use karta hai; yahan alag naam (`_push_old_*`) taake takrao na ho.
    @receiver(pre_save, sender=SaleOrder, weak=False, dispatch_uid='rider_push_order_pre')
    def _remember_order_status(sender, instance, **kwargs):
        instance._push_old_status = None
        if instance.pk:
            instance._push_old_status = (sender.objects.filter(pk=instance.pk)
                                         .values_list('status', flat=True).first())

    @receiver(post_save, sender=SaleOrder, weak=False, dispatch_uid='rider_push_order_post')
    def _order_became_ready(sender, instance, created, **kwargs):
        old = getattr(instance, '_push_old_status', None)
        if created or old is None or old == instance.status:
            return
        if instance.status == 'ready':
            notify_order_ready(instance.pk)

    @receiver(pre_save, sender=DeliveryInfo, weak=False, dispatch_uid='rider_push_delivery_pre')
    def _remember_delivery(sender, instance, **kwargs):
        instance._push_old = (None, None)
        if instance.pk:
            instance._push_old = sender.objects.filter(pk=instance.pk).values_list('status', 'rider_id').first() \
                or (None, None)

    @receiver(post_save, sender=DeliveryInfo, weak=False, dispatch_uid='rider_push_delivery_post')
    def _order_assigned(sender, instance, created, **kwargs):
        if instance.status != 'assigned' or not instance.rider_id or not instance.sale_order_id:
            return
        old_status, old_rider = getattr(instance, '_push_old', (None, None))
        if old_status == 'assigned' and old_rider == instance.rider_id:
            return                          # rider wahi, status wahi: dobara push nahi
        rider_user_id = (RiderProfile.objects.filter(pk=instance.rider_id)
                         .values_list('user_id', flat=True).first())
        if instance.created_by_id and instance.created_by_id == rider_user_id:
            return                          # rider ne khud accept kiya
        notify_order_assigned(instance.sale_order_id, instance.rider_id)


_register()
