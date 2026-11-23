"""Rider live location (order live tracking).

Additive only: do naye tables. Koi purani table/column change nahi hota.
"""
from django.db import models


class RiderLiveLocation(models.Model):
    """Rider ki sirf LATEST location (har rider ki 1 row)."""
    rider = models.OneToOneField('RiderProfile', on_delete=models.CASCADE,
                                 related_name='live_location')
    latitude = models.FloatField()
    longitude = models.FloatField()
    accuracy_m = models.FloatField(null=True, blank=True)
    speed_mps = models.FloatField(null=True, blank=True)
    heading = models.FloatField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"{self.rider.name} @ {self.latitude:.5f},{self.longitude:.5f}"


class RiderLocationLog(models.Model):
    """History (route replay / dispute). cleanup_rider_locations 7 din baad saaf karti hai."""
    delivery = models.ForeignKey('DeliveryInfo', on_delete=models.CASCADE,
                                 related_name='location_logs')
    latitude = models.FloatField()
    longitude = models.FloatField()
    accuracy_m = models.FloatField(null=True, blank=True)
    recorded_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [models.Index(fields=['delivery', '-recorded_at'], name='app_rll_deliv_rec_idx')]
        ordering = ['-recorded_at']
