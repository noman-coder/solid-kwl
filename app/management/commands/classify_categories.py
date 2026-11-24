"""Purani (ya sab) categories ko master category do.

  python manage.py classify_categories            # sirf jin ka master nahi
  python manage.py classify_categories --all      # AI/keyword wali sab dobara (manual ko chhor kar)
  python manage.py classify_categories --no-ai    # sirf keywords, Gemini nahi
  python manage.py classify_categories --retry-fallback   # + jo pehle 'fallback' (Other) rahi un par AI dobara
  python manage.py classify_categories --dry-run  # sirf dikhao, save nahi
"""
from django.core.management.base import BaseCommand
from django.db.models import Q

from app.category_ai import assign_master, classify
from app.models import Category, MasterCategory


class Command(BaseCommand):
    help = "Categories ko master category (shop home ki bari categories) mein daalta hai."

    def add_arguments(self, parser):
        parser.add_argument('--all', action='store_true')
        parser.add_argument('--no-ai', action='store_true')
        parser.add_argument('--retry-fallback', action='store_true')
        parser.add_argument('--dry-run', action='store_true')

    def handle(self, *args, **o):
        qs = Category.objects.exclude(master_source='manual')
        if not o['all']:
            cond = Q(master__isnull=True)
            if o['retry_fallback']:
                cond |= Q(master_source='fallback')
            qs = qs.filter(cond)
        names = list(MasterCategory.objects.filter(is_active=True).values_list('name', flat=True))
        if not names:
            self.stderr.write("Koi master category nahi - pehle `python manage.py migrate` chalayein.")
            return
        for c in qs.order_by('name'):
            if o['dry_run']:
                m, src = classify(c.name, names, use_ai=not o['no_ai'])
                self.stdout.write(f"{c.name:30} -> {m} ({src})")
            else:
                res = assign_master(c, force=True, use_ai=not o['no_ai'])
                self.stdout.write(f"{c.name:30} -> {res[0]} ({res[1]})" if res else f"{c.name:30} -> (koi master nahi)")
        self.stdout.write(self.style.SUCCESS("Ho gaya. 'fallback' wali categories admin mein check kar lein."))
