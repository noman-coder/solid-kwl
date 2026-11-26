"""Vendor product offers (Vendor app Phase V13-B).

Additive only: ek nayi table. Offer ek product par waqt-wali (start-end) discount hai. Product ki apni price /
discount_percentage / original_price kabhi nahi badalti: customer ko dikhate waqt `app.customer.offers` offer ko
upar se lagata hai (aur offer khatam hote hi price khud pehli jaisi).
"""
from django.db import models


class ProductOffer(models.Model):
    product = models.ForeignKey('Product', on_delete=models.CASCADE, related_name='vendor_offers')
    profile = models.ForeignKey('VendorProfile', on_delete=models.CASCADE, related_name='product_offers')
    discount_percent = models.DecimalField(max_digits=5, decimal_places=2)
    starts_at = models.DateTimeField()
    ends_at = models.DateTimeField(help_text='Is waqt se pehle tak chalta hai (ends_at khud shamil nahi)')
    is_active = models.BooleanField(default=True, help_text='Vendor ka chalu / band switch')
    request_key = models.CharField(max_length=64, blank=True, default='', db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at', '-id']
        indexes = [
            models.Index(fields=['product', 'is_active', 'starts_at', 'ends_at'], name='poffer_prod_window'),
            models.Index(fields=['profile', '-created_at'], name='poffer_profile_created'),
        ]

    def __str__(self):
        return f"{self.product_id} -{self.discount_percent:g}% ({self.starts_at:%Y-%m-%d} - {self.ends_at:%Y-%m-%d})"
