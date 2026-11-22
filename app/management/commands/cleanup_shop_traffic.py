from django.core.management.base import BaseCommand

from app.shop_traffic import rollup_old_traffic


class Command(BaseCommand):
    help = ("Traffic Analytics: 90 din se purana raw data daily summary mein save karke raw rows hataata hai. "
            "Summary kabhi delete nahi hoti. Orders/products/customers ko touch nahi karta.")

    def add_arguments(self, parser):
        parser.add_argument('--days', type=int, default=90, help='raw data kitne din rakhna hai (default 90)')
        parser.add_argument('--dry-run', action='store_true', help='sirf dikhao, kuch change na karo')

    def handle(self, *args, **opts):
        done = rollup_old_traffic(keep_days=max(opts['days'], 30), max_days=400, dry_run=opts['dry_run'])
        for day, n_ev, n_sr in done:
            self.stdout.write(f"{day}: {n_ev} events, {n_sr} searches summarised")
        self.stdout.write(self.style.SUCCESS(f"{len(done)} day(s) processed" + (" (dry run)" if opts['dry_run'] else "")))
