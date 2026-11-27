"""Vendor stock history (Vendor app Phase V10).

Additive only: ek nayi table. Vendor app se jab bhi stock add/minus hota hai (stock adjust, quick update ka
'naya stock') to yahan ek row likhi jati hai: kitna tha, kitna bacha, kyun. Koi purani table/column nahi badli.
"""
from django.db import models


class VendorStockLog(models.Model):
    KIND_CHOICES = [('add', 'Stock add'), ('minus', 'Stock kam')]

    product = models.ForeignKey('Product', on_delete=models.CASCADE, related_name='vendor_stock_logs')
    profile = models.ForeignKey('VendorProfile', on_delete=models.CASCADE, related_name='stock_logs')
    kind = models.CharField(max_length=5, choices=KIND_CHOICES)
    qty = models.FloatField()
    before = models.FloatField()
    after = models.FloatField()
    reason = models.CharField(max_length=20, default='other')
    note = models.CharField(max_length=200, blank=True, default='')
    source = models.CharField(max_length=20, default='app', help_text="app | quick_update")
    request_key = models.CharField(max_length=64, blank=True, default='', db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at', '-id']
        indexes = [models.Index(fields=['profile', '-created_at'], name='vstocklog_profile_created')]

    def __str__(self):
        sign = '+' if self.kind == 'add' else '-'
        return f"{self.product_id} {sign}{self.qty:g} ({self.before:g}->{self.after:g})"
