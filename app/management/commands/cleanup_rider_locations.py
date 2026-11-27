from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from app.models import RiderLiveLocation, RiderLocationLog


class Command(BaseCommand):
    help = "7 din se purani rider location history aur live rows saaf karta hai (sirf naye tables)"

    def add_arguments(self, parser):
        parser.add_argument('--days', type=int, default=7)

    def handle(self, *args, **opts):
        cut = timezone.now() - timedelta(days=opts['days'])
        n, _ = RiderLocationLog.objects.filter(recorded_at__lt=cut).delete()
        m, _ = RiderLiveLocation.objects.filter(updated_at__lt=cut).delete()
        self.stdout.write(f"deleted logs={n} live={m}")
