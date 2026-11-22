from datetime import date, timedelta

from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from app.shop_traffic import send_daily_summary, summary_recipients


class Command(BaseCommand):
    help = "Shop traffic ki daily summary email bhejta hai (receiver: SUMMERY_REC secret). Default: kal ki."

    def add_arguments(self, parser):
        parser.add_argument('--date', help='YYYY-MM-DD (default: kal)')
        parser.add_argument('--to', help='address (default: SUMMERY_REC)')

    def handle(self, *args, **opts):
        day = date.fromisoformat(opts['date']) if opts['date'] else timezone.localtime(timezone.now()).date() - timedelta(days=1)
        to = [opts['to']] if opts['to'] else summary_recipients()
        if not to:
            raise CommandError('Receiver nahi mila: SUMMERY_REC set karein ya --to dein.')
        send_daily_summary(day, to=to)
        self.stdout.write(self.style.SUCCESS(f'Summary for {day} sent to {", ".join(to)}'))
