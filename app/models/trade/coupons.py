"""Models: trade/coupons - Coupon / promo code (admin ya vendor banaye) + kis order par kitna discount mila.

SAFE: sirf naye tables. Purane tables/data ko koi asar nahi.

- vendor khali  = poori shop ka coupon (admin banata hai, discount shop bardasht karti hai)
- vendor bhara  = sirf us store ke cart par chalega (vendor banata hai, discount vendor bardasht karta hai)
"""
from decimal import Decimal, ROUND_HALF_UP

from django.contrib.auth.models import User
from django.db import models
from django.utils import timezone

CENT = Decimal('0.01')


class Coupon(models.Model):
    TYPE_PERCENT = 'percent'
    TYPE_FIXED = 'fixed'
    TYPE_FREE_DELIVERY = 'free_delivery'
    TYPE_CHOICES = [
        (TYPE_PERCENT, 'Percent (%) discount'),
        (TYPE_FIXED, 'Fixed amount (Rs.) discount'),
        (TYPE_FREE_DELIVERY, 'Free delivery'),
    ]
    FUNDED_SHOP = 'shop'
    FUNDED_VENDOR = 'vendor'

    code = models.CharField(max_length=30, unique=True, help_text="Capital letters / numbers, jaise WELCOME50")
    title = models.CharField(max_length=80, blank=True, default='', help_text="Customer ko dikhne wali line, jaise 'Pehle order par 20% off'")
    vendor = models.ForeignKey(
        'Vendor', on_delete=models.CASCADE, null=True, blank=True, related_name='coupons',
        help_text="Khali = poori shop ke liye. Bhara = sirf us store ke cart par.")
    discount_type = models.CharField(max_length=20, choices=TYPE_CHOICES, default=TYPE_PERCENT)
    value = models.DecimalField(max_digits=10, decimal_places=2, default=Decimal('0.00'),
                                help_text="Percent ya Rs. (Free delivery mein zaroorat nahi)")
    max_discount = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True,
                                       help_text="Percent coupon par discount ki hadd (Rs.)")
    min_order = models.DecimalField(max_digits=10, decimal_places=2, default=Decimal('0.00'),
                                    help_text="Items ka kam az kam total (delivery ke baghair)")
    usage_limit = models.PositiveIntegerField(null=True, blank=True, help_text="Kul kitni dafa chal sakta hai (khali = be-had)")
    per_customer_limit = models.PositiveSmallIntegerField(default=1, help_text="Ek customer kitni dafa (0 = be-had)")
    first_order_only = models.BooleanField(default=False, help_text="Sirf naye customer ke pehle order par")
    valid_from = models.DateTimeField(null=True, blank=True)
    valid_until = models.DateTimeField(null=True, blank=True)
    is_active = models.BooleanField(default=True)
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, editable=False,
                                   related_name='created_coupons')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = 'Coupon'
        verbose_name_plural = '3.4 Coupons'
        ordering = ['-created_at']
        indexes = [models.Index(fields=['vendor', 'is_active'], name='app_coupon_vendor_active_idx')]

    def __str__(self):
        return f"{self.code} ({self.short_label})"

    def save(self, *args, **kwargs):
        self.code = ''.join((self.code or '').split()).upper()
        super().save(*args, **kwargs)

    @property
    def funded_by(self):
        return self.FUNDED_VENDOR if self.vendor_id else self.FUNDED_SHOP

    @property
    def short_label(self):
        if self.discount_type == self.TYPE_PERCENT:
            txt = f"{self.value.normalize():f}% off"
            if self.max_discount:
                txt += f" (max Rs. {self.max_discount:,.0f})"
            return txt
        if self.discount_type == self.TYPE_FIXED:
            return f"Rs. {self.value:,.0f} off"
        return "Free delivery"

    @property
    def status(self):
        """'active' | 'paused' | 'scheduled' | 'expired' | 'used_up'"""
        now = timezone.now()
        if not self.is_active:
            return 'paused'
        if self.valid_from and now < self.valid_from:
            return 'scheduled'
        if self.valid_until and now > self.valid_until:
            return 'expired'
        if self.usage_limit is not None and self.used_count >= self.usage_limit:
            return 'used_up'
        return 'active'

    @property
    def used_count(self):
        return self.live_redemptions().count()

    def live_redemptions(self):
        """Cancelled order wali redemption ginti mein nahi (coupon wapis mil jata hai)."""
        return self.redemptions.exclude(sale_order__status='cancelled')

    def compute_discount(self, subtotal):
        """Items ke subtotal par discount (free delivery ke liye 0). Subtotal se zyada kabhi nahi."""
        subtotal = Decimal(subtotal or 0)
        if self.discount_type == self.TYPE_PERCENT:
            amount = (subtotal * self.value / Decimal('100')).quantize(CENT, ROUND_HALF_UP)
            if self.max_discount:
                amount = min(amount, self.max_discount)
        elif self.discount_type == self.TYPE_FIXED:
            amount = self.value
        else:
            return Decimal('0.00')
        return max(Decimal('0.00'), min(amount, subtotal)).quantize(CENT, ROUND_HALF_UP)


class CouponRedemption(models.Model):
    """Kis order par kis customer ko kitna coupon discount mila (hisaab / settlement ke liye)."""
    coupon = models.ForeignKey(Coupon, on_delete=models.CASCADE, related_name='redemptions')
    customer = models.ForeignKey('Customer', on_delete=models.CASCADE, related_name='coupon_redemptions')
    sale_order = models.OneToOneField('SaleOrder', on_delete=models.CASCADE, related_name='coupon_redemption')
    discount_amount = models.DecimalField(max_digits=12, decimal_places=2, default=Decimal('0.00'))
    delivery_waived = models.DecimalField(max_digits=10, decimal_places=2, default=Decimal('0.00'))
    funded_by = models.CharField(max_length=10, default='shop')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = 'Coupon Redemption'
        verbose_name_plural = '3.5 Coupon Redemptions'
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.coupon.code} -> order {self.sale_order_id} (Rs. {self.discount_amount})"
