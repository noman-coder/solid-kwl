"""Vendor app ke push notification tokens (Firebase Cloud Messaging).

Additive only: ek nayi table. Koi purani table/column change nahi hota.
Ek vendor ke kai phone ho sakte hain (kai tokens); ek token ek hi vendor ka hota hai
(doosra vendor usi phone par login kare to token us ka ho jata hai).
"""
from django.db import models


class VendorPushToken(models.Model):
    profile = models.ForeignKey('VendorProfile', on_delete=models.CASCADE, related_name='push_tokens')
    token = models.CharField(max_length=255, unique=True)
    device = models.CharField(max_length=100, blank=True, default='',
                              help_text="Phone ka naam/model (optional, sirf pehchan ke liye)")
    platform = models.CharField(max_length=20, default='android')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-updated_at']

    def __str__(self):
        return f"{self.profile.business_name} ({self.platform}) ...{self.token[-8:]}"
