"""
Vendor ko stock ki PUSH khabar (kam / khatam) - Vendor app Phase V2.

Inventory kahin se bhi badle (order delivered, POS, admin, vendor ka apna quick update) - signal pakad leta hai,
purane views mein koi tabdeeli nahi. Sirf VENDOR ke products ka (Product.vendor bhara ho) aur sirf tab jab
stock us product ke threshold (`low_stock_threshold`) se neeche ho. Bar bar alert na aaye is liye
vendor_push.check_stock_alert din mein ek dafa hi bhejti hai.

Naya Inventory row (created) nazar-andaz: naya product add hote waqt row pehle 0 stock se banti hai, phir stock chadhta hai.
Koi bhi ghalti sirf log hoti hai - stock ka asal kaam kabhi nahi rukta.
"""
import logging

from django.db.models.signals import post_save
from django.dispatch import receiver

from . import vendor_push

logger = logging.getLogger(__name__)


def _register():
    from .models import Inventory, Product

    @receiver(post_save, sender=Inventory, weak=False, dispatch_uid='vendor_push_stock_post')
    def _stock_changed(sender, instance, created, **kwargs):
        try:
            if created or kwargs.get('raw'):
                return
            threshold = (Product.objects.filter(pk=instance.product_id, vendor__isnull=False)
                         .values_list('low_stock_threshold', flat=True).first())
            if threshold is None:               # shop ka apna maal: vendor push nahi
                return
            if instance.stock >= max(threshold or 0, 0) and instance.stock > 0:
                return                          # stock theek hai
            vendor_push.check_stock_alert(instance.product_id)
        except Exception:
            logger.exception('Vendor stock push signal failed')


_register()
