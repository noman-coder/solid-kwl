"""
Rider cash handover: receiver (admin / vendor) ka confirm ya reject (Phase 2).

Ek hi jagah ka logic, taake admin page aur vendor portal dono wahi qaida use karein.

- Confirm: transaction.atomic + select_for_update. RiderSettlement(kind='cash_in') banti hai aur
  handover.settlement se judti hai, is liye purana rider_balances() aur admin ka purana
  "Cash jama" form waise hi sahi chalte hain.
- Reject: wajah zaroori. Raqam rider ke paas hi rehti hai (settlement nahi banti).
- Raqam hamesha Decimal. Double click / double confirm se sirf ek settlement banti hai.
"""
import logging
from decimal import Decimal

from django.db import transaction
from django.utils.timezone import now

from ..models import RiderCashHandover, RiderProfile, RiderSettlement
from . import store_orders
from .views_rider_portal import rider_balances

logger = logging.getLogger(__name__)

MAX_REASON_LEN = 200


class HandoverError(Exception):
    """Receiver ko dikhane wala simple Roman Urdu message."""


def can_decide(handover, user, vendor=None):
    """Kaun confirm / reject kar sakta hai.
    admin handover  -> sirf superuser
    vendor handover -> sirf wahi vendor (vendor= us ka Vendor object)"""
    if handover.receiver == 'admin':
        return bool(user and user.is_authenticated and user.is_superuser)
    return bool(vendor is not None and handover.vendor_id == vendor.pk)


def _receiver_label(h):
    if h.receiver == 'vendor':
        return store_orders.store_name(h.vendor_id) if h.vendor_id else 'Vendor'
    return 'Admin'


def _lock_pending(handover_id, user, vendor):
    """Handover row lock karo, check karo ke pending hai aur is receiver ka hai."""
    h = (RiderCashHandover.objects.select_for_update()
         .select_related('rider', 'vendor').filter(pk=handover_id).first())
    if h is None:
        raise HandoverError('Handover nahi mila.')
    if not can_decide(h, user, vendor):
        raise HandoverError('Ye handover aap ke liye nahi hai.')
    if h.status != 'pending':
        word = 'confirm' if h.status == 'confirmed' else 'reject'
        raise HandoverError(f'Ye handover pehle hi {word} ho chuka hai.')
    return h


def confirm_handover(handover_id, user, vendor=None):
    """Handover confirm karo. Settlement (cash_in) banao. Returns handover."""
    with transaction.atomic():
        h = _lock_pending(handover_id, user, vendor)
        # rider ki row lock: admin ka purana cash_in form ya doosra confirm saath na chale
        rider = RiderProfile.objects.select_for_update().get(pk=h.rider_id)
        bal = rider_balances(rider)
        amount = Decimal(h.amount)
        if amount > bal['cash_in_hand']:
            raise HandoverError(
                f'Rider ke paas ab sirf Rs. {bal["cash_in_hand"]:,.0f} cash hisab mein hai '
                f'(shayad pehle jama ho chuka). Is handover ko reject karein.')
        who = _receiver_label(h)
        if h.receiver == 'vendor':
            note = f'Handover #{h.pk}: rider ne {who} ko diya, {who} ne confirm kiya'
        else:
            note = f'Handover #{h.pk}: rider ne Admin ko diya'
        if h.note:
            note += f' ({h.note})'
        settlement = RiderSettlement.objects.create(
            rider=rider, kind='cash_in', amount=amount, note=note[:200], created_by=user)
        h.status = 'confirmed'
        h.decided_at = now()
        h.decided_by = user
        h.settlement = settlement
        h.save(update_fields=['status', 'decided_at', 'decided_by', 'settlement'])

    store_orders._notify(
        rider.user, f'✅ Rs. {amount:,.0f} ka cash confirm ho gaya',
        f'{_receiver_label(h)} ne aap ka Rs. {amount:,.0f} ka handover confirm kar diya. '
        f'Aap ka cash in hand kam ho gaya.', None, 'success', email=False)
    return h


def reject_handover(handover_id, user, reason, vendor=None):
    """Handover reject karo (wajah zaroori). Raqam rider ke paas hi rehti hai."""
    reason = (reason or '').strip()[:MAX_REASON_LEN]
    if not reason:
        raise HandoverError('Reject karne ki wajah likhein.')
    with transaction.atomic():
        h = _lock_pending(handover_id, user, vendor)
        h.status = 'rejected'
        h.reject_reason = reason
        h.decided_at = now()
        h.decided_by = user
        h.save(update_fields=['status', 'reject_reason', 'decided_at', 'decided_by'])

    store_orders._notify(
        h.rider.user, f'❌ Rs. {h.amount:,.0f} ka handover reject hua',
        f'{_receiver_label(h)} ne handover reject kar diya. Wajah: {reason}. '
        f'Raqam abhi aap ke paas hai, dobara handover bhejein.', None, 'warning', email=False)
    return h


def pending_for_admin(rider=None):
    qs = RiderCashHandover.objects.filter(receiver='admin', status='pending').select_related('rider')
    return qs.filter(rider=rider) if rider is not None else qs


def pending_for_vendor(vendor):
    return RiderCashHandover.objects.filter(
        receiver='vendor', vendor=vendor, status='pending').select_related('rider')
