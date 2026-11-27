"""Test push: python manage.py test_customer_push 03211234567

Customer ke registered phone(s) par ek test notification bhejta hai aur batata hai ke kya masla hai
(config nahi / token nahi / FCM ne reject kiya).

  --channel order_updates   'Order updates' wale channel se bhejo  [default]
  --channel offers          'Offers' wale channel se bhejo
"""
from django.core.management.base import BaseCommand, CommandError

from app import customer_push, rider_push
from app.customer.views_customer_auth import normalize_phone
from app.models import Customer, CustomerPushToken


class Command(BaseCommand):
    help = 'Customer ko test push notification bhejo (phone number do).'

    def add_arguments(self, parser):
        parser.add_argument('phone', help='Customer ka phone (jaise 03211234567)')
        parser.add_argument('--channel', choices=[customer_push.ORDER_CHANNEL, customer_push.OFFERS_CHANNEL],
                            default=customer_push.ORDER_CHANNEL, help='Kaun sa notification channel')

    def handle(self, *args, **opts):
        if not customer_push.is_configured():
            raise CommandError('FCM_SERVICE_ACCOUNT_JSON set nahi (ya ghalat hai). GitHub Secret check karein.')
        raw = str(opts['phone']).strip()
        customer = Customer.objects.filter(contact_number__in={raw, normalize_phone(raw)}).first()
        if not customer:
            raise CommandError(f'Is phone ka customer nahi mila: {raw}')
        tokens = list(CustomerPushToken.objects.filter(customer=customer).values_list('token', flat=True))
        if not tokens:
            raise CommandError(f'{customer.name} ka koi push token nahi. Customer app kholkar login karwayein '
                               f'(Notifications allow karein).')
        channel = opts['channel']
        res = rider_push.send_to_tokens(
            tokens, '🔔 Test notification', f'{customer.name}, customer push theek chal raha hai.',
            data={'type': 'test'}, tag='test', channel_id=channel,
            ttl=customer_push.TTL_OFFER if channel == customer_push.OFFERS_CHANNEL else customer_push.TTL_ORDER)
        if res['dead']:
            CustomerPushToken.objects.filter(token__in=res['dead']).delete()
        self.stdout.write(f"tokens={len(tokens)} sent={res['sent']} failed={res['failed']} "
                          f"dead_removed={len(res['dead'])} channel={channel}")
