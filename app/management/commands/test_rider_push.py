"""Test push: python manage.py test_rider_push 03211234567

Rider ke registered phone(s) par ek test notification bhejta hai aur batata hai ke kya masla hai
(config nahi / token nahi / FCM ne reject kiya).
"""
from django.core.management.base import BaseCommand, CommandError

from app import rider_push
from app.models import RiderProfile, RiderPushToken


class Command(BaseCommand):
    help = 'Rider ko test push notification bhejo (phone number do).'

    def add_arguments(self, parser):
        parser.add_argument('phone', help='Rider ka phone (jaise 03211234567)')

    def handle(self, *args, **opts):
        if not rider_push.is_configured():
            raise CommandError('FCM_SERVICE_ACCOUNT_JSON set nahi (ya ghalat hai). GitHub Secret check karein.')
        rider = RiderProfile.objects.filter(phone=opts['phone']).first()
        if not rider:
            raise CommandError(f"Is phone ka rider nahi mila: {opts['phone']}")
        tokens = list(RiderPushToken.objects.filter(rider=rider).values_list('token', flat=True))
        if not tokens:
            raise CommandError(f'{rider.name} ka koi push token nahi. Rider app kholkar login karwayein '
                               f'(Notifications allow karein).')
        res = rider_push.send_to_tokens(tokens, '🔔 Test notification', f'{rider.name}, push theek chal raha hai.',
                                        data={'type': 'test'}, tag='test')
        if res['dead']:
            RiderPushToken.objects.filter(token__in=res['dead']).delete()
        self.stdout.write(f"tokens={len(tokens)} sent={res['sent']} failed={res['failed']} dead_removed={len(res['dead'])}")
