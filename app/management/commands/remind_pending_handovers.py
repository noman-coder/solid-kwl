"""Rider cash handover 24 ghante se pending ho to admin ko reminder (auto-confirm NAHI - paisa ka mamla).

Chalane ka tareeqa (roz ek dafa, cron / task scheduler se):
    python manage.py remind_pending_handovers
    python manage.py remind_pending_handovers --hours 24
"""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from app.customer import store_orders
from app.models import RiderCashHandover


class Command(BaseCommand):
    help = "24 ghante se pending rider cash handovers ka admin ko reminder bhejta hai."

    def add_arguments(self, parser):
        parser.add_argument('--hours', type=int, default=24)

    def handle(self, *args, **opts):
        cutoff = timezone.now() - timedelta(hours=opts['hours'])
        old = list(RiderCashHandover.objects.filter(status='pending', created_at__lte=cutoff)
                   .select_related('rider', 'vendor'))
        if not old:
            self.stdout.write('Koi purana pending handover nahi.')
            return
        lines = []
        for h in old:
            to = f'Vendor {store_orders.store_name(h.vendor_id)}' if h.receiver == 'vendor' else 'Admin'
            lines.append(f'{h.rider.name} -> {to}: Rs. {h.amount:,.0f}')
        store_orders.notify_admins(
            f'⏰ {len(old)} rider cash handover confirm ka intezar kar rahe hain',
            f'{opts["hours"]} ghante se zyada pending: ' + '; '.join(lines[:10]),
            '/shop/rider/manage/', 'warning')
        self.stdout.write(f'{len(old)} pending handover(s) ka reminder bhej diya.')
