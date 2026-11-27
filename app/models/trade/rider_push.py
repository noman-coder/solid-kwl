"""Rider app ke push notification tokens (Firebase Cloud Messaging).

Additive only: ek nayi table. Koi purani table/column change nahi hota.
Ek rider ke kai phone ho sakte hain (kai tokens); ek token ek hi rider ka hota hai.
"""
from django.db import models


class RiderPushToken(models.Model):
    rider = models.ForeignKey('RiderProfile', on_delete=models.CASCADE, related_name='push_tokens')
    token = models.CharField(max_length=255, unique=True)
    platform = models.CharField(max_length=20, default='android')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-updated_at']

    def __str__(self):
        return f"{self.rider.name} ({self.platform}) ...{self.token[-8:]}"
