"""Test push: python manage.py test_vendor_push 03211234567

Vendor ke registered phone(s) par ek test notification bhejta hai aur batata hai ke kya masla hai
(config nahi / token nahi / FCM ne reject kiya).

  --channel new_orders   'Naye orders' wale channel (alag awaaz) se bhejo  [default]
  --channel updates      'Baqi updates' wale channel se bhejo
"""
from django.core.management.base import BaseCommand, CommandError

from app import rider_push, vendor_push
from app.customer.views_customer_auth import normalize_phone
from app.models import VendorProfile, VendorPushToken


class Command(BaseCommand):
    help = 'Vendor ko test push notification bhejo (phone number do).'

    def add_arguments(self, parser):
        parser.add_argument('phone', help='Vendor ka phone (jaise 03211234567)')
        parser.add_argument('--channel', choices=[vendor_push.NEW_ORDERS_CHANNEL, vendor_push.UPDATES_CHANNEL],
                            default=vendor_push.NEW_ORDERS_CHANNEL, help='Kaun sa notification channel')

    def handle(self, *args, **opts):
        if not vendor_push.is_configured():
            raise CommandError('FCM_SERVICE_ACCOUNT_JSON set nahi (ya ghalat hai). GitHub Secret check karein.')
        raw = str(opts['phone']).strip()
        profile = (VendorProfile.objects.select_related('vendor')
                   .filter(vendor__contact_number__in={raw, normalize_phone(raw)}).first())
        if not profile:
            raise CommandError(f'Is phone ka vendor nahi mila: {raw}')
        tokens = list(VendorPushToken.objects.filter(profile=profile).values_list('token', flat=True))
        if not tokens:
            raise CommandError(f'{profile.business_name} ka koi push token nahi. Vendor app kholkar login karwayein '
                               f'(Notifications allow karein).')
        channel = opts['channel']
        res = rider_push.send_to_tokens(
            tokens, '🔔 Test notification', f'{profile.business_name}, vendor push theek chal raha hai.',
            data={'type': 'test'}, tag='test', channel_id=channel,
            ttl=vendor_push.TTL_ORDER if channel == vendor_push.NEW_ORDERS_CHANNEL else vendor_push.TTL_UPDATE)
        if res['dead']:
            VendorPushToken.objects.filter(token__in=res['dead']).delete()
        self.stdout.write(f"tokens={len(tokens)} sent={res['sent']} failed={res['failed']} "
                          f"dead_removed={len(res['dead'])} channel={channel}")
