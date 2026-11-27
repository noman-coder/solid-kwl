"""
Customer ko order status ki PUSH (app band ho tab bhi) - Customer app Phase C2.

Kab jati hai (order ka customer, agar us ne customer app mein login karke push token register kiya ho):
  SaleOrder.status      confirmed          -> 'Order qubool ho gaya' (accept)
                        cancelled          -> 'Order qubool nahi hua' (vendor ne reject, wajah ke saath)
                                              ya 'Order cancel ho gaya' (wajah ke baghair: customer / admin cancel)
                        ready              -> 'Order tayyar hai'
                        delivered          -> 'Order pahunch gaya'
  DeliveryInfo.status   assigned           -> 'Rider mil gaya' (rider assign hua / badla)
                        picked_up/in_transit -> 'Order raste mein hai' (dono ke liye ek hi push)

Same pattern jo order_status_emails.py aur rider_push_signals.py ka hai: status kahin se bhi badle (vendor app,
vendor panel, admin, rider app, customer cancel) - signal pakad leta hai, purane views mein koi tabdeeli nahi.
Push transaction commit hone ke baad, background thread mein jati hai. Koi bhi ghalti sirf log hoti hai:
order ka status badalna kabhi nahi rukta (har receiver try/except mein hai).

NOTE: doosre signals apne `_old_status` / `_push_old_*` use karte hain; yahan alag naam (`_cpush_old_*`) taake takrao na ho.
"""
import logging

from django.db.models.signals import post_save, pre_save
from django.dispatch import receiver

from . import customer_push

logger = logging.getLogger(__name__)

# SaleOrder.status -> event (cancelled ka event wajah dekh kar neeche tay hota hai)
ORDER_EVENTS = {
    'confirmed': 'order_accepted',
    'ready': 'order_ready',
    'delivered': 'order_delivered',
}
# DeliveryInfo.status -> event (picked_up aur in_transit dono "raste mein": ek hi event, ek hi push)
DELIVERY_EVENTS = {
    'picked_up': 'order_on_the_way',
    'in_transit': 'order_on_the_way',
}


def order_event_for(status, reject_reason=''):
    """SaleOrder ke naye status par kaun sa push event? None = push nahi."""
    if status == 'cancelled':
        return 'order_rejected' if (reject_reason or '').strip() else 'order_cancelled'
    return ORDER_EVENTS.get(status)


def _register():
    from .models import DeliveryInfo, SaleOrder

    @receiver(pre_save, sender=SaleOrder, weak=False, dispatch_uid='customer_push_order_pre')
    def _remember_order_status(sender, instance, **kwargs):
        instance._cpush_old_status = None
        try:
            if instance.pk and not kwargs.get('raw'):
                instance._cpush_old_status = (sender.objects.filter(pk=instance.pk)
                                              .values_list('status', flat=True).first())
        except Exception:
            logger.exception('Customer push: purana order status nahi parh saka')

    @receiver(post_save, sender=SaleOrder, weak=False, dispatch_uid='customer_push_order_post')
    def _order_status_changed(sender, instance, created, **kwargs):
        try:
            old = getattr(instance, '_cpush_old_status', None)
            if created or kwargs.get('raw') or old is None or old == instance.status:
                return
            event = order_event_for(instance.status, instance.reject_reason)
            if event:
                customer_push.notify_order_event(instance.pk, event)
        except Exception:
            logger.exception('Customer push signal (order) failed')

    @receiver(pre_save, sender=DeliveryInfo, weak=False, dispatch_uid='customer_push_delivery_pre')
    def _remember_delivery(sender, instance, **kwargs):
        instance._cpush_old = (None, None)
        try:
            if instance.pk and not kwargs.get('raw'):
                instance._cpush_old = (sender.objects.filter(pk=instance.pk)
                                       .values_list('status', 'rider_id').first() or (None, None))
        except Exception:
            logger.exception('Customer push: purani delivery nahi parh saka')

    @receiver(post_save, sender=DeliveryInfo, weak=False, dispatch_uid='customer_push_delivery_post')
    def _delivery_changed(sender, instance, created, **kwargs):
        try:
            if kwargs.get('raw') or not instance.sale_order_id:
                return
            old_status, old_rider = getattr(instance, '_cpush_old', (None, None))
            if instance.status == 'assigned' and instance.rider_id:
                if old_status == 'assigned' and old_rider == instance.rider_id:
                    return                  # rider wahi, status wahi: dobara push nahi
                # rider badle to naya push (dedupe key mein rider shamil)
                customer_push.notify_order_event(instance.sale_order_id, 'rider_assigned',
                                                 dedupe_extra=str(instance.rider_id))
                return
            event = DELIVERY_EVENTS.get(instance.status)
            if event and not created and old_status != instance.status:
                customer_push.notify_order_event(instance.sale_order_id, event)
        except Exception:
            logger.exception('Customer push signal (delivery) failed')


_register()
