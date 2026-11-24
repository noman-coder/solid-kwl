"""Rider COD cash handover (rider ne cash admin ya vendor ko diya - receiver confirm karta hai).

Additive only: ek nayi table (+ ek M2M jodne wali table). Koi purani table/column change nahi hota.
Confirm hone par RiderSettlement(kind='cash_in') banti hai (Phase 2), is liye purana
rider_balances() aur admin ka rider_detail page waise hi chalte rahte hain.
"""
from django.db import models


class RiderCashHandover(models.Model):
    RECEIVERS = [('admin', 'Admin'), ('vendor', 'Vendor')]
    STATUS = [('pending', 'Pending'), ('confirmed', 'Confirmed'), ('rejected', 'Rejected')]

    rider = models.ForeignKey('RiderProfile', on_delete=models.CASCADE, related_name='handovers')
    receiver = models.CharField(max_length=10, choices=RECEIVERS)
    vendor = models.ForeignKey('Vendor', on_delete=models.SET_NULL, null=True, blank=True,
                               related_name='rider_cash_handovers',
                               help_text="receiver == 'vendor' par zaroori")
    amount = models.DecimalField(max_digits=12, decimal_places=2)
    note = models.CharField(max_length=200, blank=True, default='')
    orders = models.ManyToManyField('DeliveryInfo', blank=True, related_name='cash_handovers',
                                    help_text="Kin orders ka cash (optional)")
    status = models.CharField(max_length=10, choices=STATUS, default='pending')
    reject_reason = models.CharField(max_length=200, blank=True, default='')
    created_at = models.DateTimeField(auto_now_add=True)
    decided_at = models.DateTimeField(null=True, blank=True)
    decided_by = models.ForeignKey('auth.User', on_delete=models.SET_NULL, null=True, blank=True,
                                   related_name='+')
    settlement = models.OneToOneField('RiderSettlement', on_delete=models.SET_NULL, null=True,
                                      blank=True, related_name='handover')

    class Meta:
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['rider', 'status'], name='app_rch_rider_status_idx'),
            models.Index(fields=['receiver', 'vendor', 'status'], name='app_rch_recv_vendor_idx'),
        ]

    def __str__(self):
        return f"{self.rider.name} -> {self.receiver} Rs.{self.amount} ({self.status})"
