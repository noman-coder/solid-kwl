"""\"Aksar saath khareeda jata hai\": shop ke asli orders (aur na hon to saath dekhe gaye products) se suggestions.

Sirf padhta hai, kuch change nahi karta. Nateeja 6 ghante cache hota hai taake product page tez rahe.
"""
from datetime import timedelta

from django.core.cache import cache
from django.db.models import Count
from django.utils import timezone

from .models import Product, SaleOrderItem, ShopTrafficEvent

CACHE_SECONDS = 6 * 3600


def _candidate_ids(product_id, limit):
    now = timezone.now()
    ids = []
    order_ids = list(
        SaleOrderItem.objects.filter(
            product_id=product_id, order__created_at__gte=now - timedelta(days=180),
            order__notes__contains='WEB ORDER')
        .exclude(order__status='cancelled').values_list('order_id', flat=True).distinct()[:1000])
    if order_ids:
        for r in (SaleOrderItem.objects.filter(order_id__in=order_ids).exclude(product_id=product_id)
                  .values('product_id').annotate(n=Count('order_id', distinct=True)).order_by('-n')[:limit * 2]):
            ids.append(r['product_id'])
    if len(ids) < limit:                       # orders kam hon to: jin ne ye dekha unhon ne aur kya dekha
        ev = ShopTrafficEvent.objects.filter(
            event_type__in=['product', 'cart_add'], created_at__gte=now - timedelta(days=30))
        sessions = list(ev.filter(product_id=product_id).exclude(session_key='')
                        .values_list('session_key', flat=True).distinct()[:500])
        if sessions:
            for r in (ev.filter(session_key__in=sessions).exclude(product_id=product_id)
                      .exclude(product__isnull=True).values('product_id')
                      .annotate(n=Count('session_key', distinct=True)).order_by('-n')[:limit * 2]):
                if r['n'] >= 2 and r['product_id'] not in ids:
                    ids.append(r['product_id'])
    return ids[:limit * 2]


def bought_together_products(product_id, limit=6):
    """Product objects (shop mein dikhne wale) ki list, behtareen pehle."""
    key = f"trf_bt:{product_id}"
    ids = cache.get(key)
    if ids is None:
        try:
            ids = _candidate_ids(product_id, limit)
        except Exception:
            ids = []
        cache.set(key, ids, CACHE_SECONDS)
    if not ids:
        return []
    live = {p.id: p for p in Product.objects.filter(
        id__in=ids, is_active=True, approval_status='approved').select_related('category', 'brand')}
    return [live[i] for i in ids if i in live][:limit]
