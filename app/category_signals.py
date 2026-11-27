"""Nayi Category banti hai to khud master category chun lo (keyword turant, Gemini background thread mein).
Category add karna kabhi is par depend nahi karta: koi bhi ghalti sirf log hoti hai."""
import logging
import threading

from django.conf import settings
from django.db import connection, transaction
from django.db.models.signals import post_delete, post_save
from django.dispatch import receiver

from .category_ai import assign_master, clear_shop_category_cache, keyword_master
from .models import Category, MasterCategory

logger = logging.getLogger(__name__)


def _auto_on():
    return getattr(settings, 'CATEGORY_AI_AUTO', True)


def _run_ai(pk):
    try:
        cat = Category.objects.filter(pk=pk).first()
        if cat:
            assign_master(cat)
    except Exception:
        logger.exception('Category AI assign failed (pk=%s)', pk)
    finally:
        connection.close()


@receiver(post_save, sender=Category)
def category_saved(sender, instance, created, raw=False, **kwargs):
    if raw:
        return
    clear_shop_category_cache()
    if not _auto_on() or instance.master_id:
        return
    pk = instance.pk

    def _go():
        try:
            if keyword_master(instance.name):
                assign_master(instance, use_ai=False)           # turant, API ke baghair
            else:
                threading.Thread(target=_run_ai, args=(pk,), daemon=True).start()
        except Exception:
            logger.exception('Category master assign failed (pk=%s)', pk)

    transaction.on_commit(_go)


@receiver(post_delete, sender=Category)
@receiver(post_save, sender=MasterCategory)
@receiver(post_delete, sender=MasterCategory)
def _bust_cache(sender, **kwargs):
    clear_shop_category_cache()
