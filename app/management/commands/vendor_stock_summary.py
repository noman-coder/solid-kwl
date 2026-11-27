"""Roz ek dafa vendors ko stock ka summary push: python manage.py vendor_stock_summary

Cron / scheduler se din mein ek dafa chalayein (misal: roz subah 9 baje). Jin vendors ke approved products
kam ya khatam hain unhi ko bheji jati hai; ek vendor ko din mein ek hi (dobara chalane par bhi). Koi stock/DB
tabdeeli nahi hoti.

  --dry-run   sirf dikhao ke kis ko kya jata, bheji kuch nahi.
"""
from django.core.management.base import BaseCommand
from django.db.models import F

from app import vendor_push
from app.customer import views_vendor_api as api
from app.models import VendorProfile


class Command(BaseCommand):
    help = 'Vendors ko roz ek stock summary push (kam / khatam products).'

    def add_arguments(self, parser):
        parser.add_argument('--dry-run', action='store_true', help='Bheje bina dikhao.')

    def handle(self, *args, **opts):
        dry = opts['dry_run']
        sent = skipped = 0
        profiles = (VendorProfile.objects.filter(is_approved=True, push_tokens__isnull=False)
                    .select_related('vendor').distinct())
        for profile in profiles:
            try:
                qs = api._product_qs(profile.vendor).filter(approval_status='approved', stk__lte=F('thr'))
                rows = list(qs.order_by('stk', 'name').values('name', 'stk'))
                out = sum(1 for r in rows if (r['stk'] or 0) <= 0)
                low = len(rows) - out
                if not rows:
                    continue
                names = [r['name'] for r in rows]
                if dry:
                    self.stdout.write(f'{profile.business_name}: {out} khatam, {low} kam')
                    continue
                if vendor_push.notify_stock_summary(profile.vendor_id, low, out, names):
                    sent += 1
                else:
                    skipped += 1
            except Exception as exc:          # ek vendor ki ghalti baqi ko na roke
                self.stderr.write(f'{profile.pk}: {exc}')
        if not dry:
            self.stdout.write(self.style.SUCCESS(f'Summary bheji: {sent}, chhodi (pehle bhej di / push band): {skipped}'))
