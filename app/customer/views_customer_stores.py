"""
Customer Android app ki JSON API - Phase C5: Stores list + Store detail.

Endpoints (sab `api/customer/...`, guest bhi dekh sakta hai):
    GET stores/        ?q=&area=&category=&type=&sort=&open=1&free=1&top=1&new=1&page=&lat=&lng=
    GET stores/<id>/   ?category=&q=&page=      store ka poora page: info, menu (categories), products

Logic naya nahi likha, web ka hi reuse hai (views_stores.store_list / store_detail):
    views_stores        : store_serves_area, STATUS_ORDER, SORTS, CURRENCY
    views_customer_home : _live_stores_qs, resolve_area, _customer_location, _store_json, _product_json (C4)
    views_reviews       : store_rating_map, store_reviews (rating bars)
    views_extras        : FavoriteStore (dil bhara hai ya nahi)
    coupons / offers    : available_for_customer, overlay

Rules:
- Sirf approved stores jin ka koi product live (`is_active` + `approved`) ho (list). Area ke bahar wale stores list mein nahi
  aate (`outside_count` batata hai). Detail mein area ke bahar ka store khul jata hai magar `serves_area=false` + paigham.
- Band store: `is_open=false` + `closed_message`; us ke har product par `can_add=false` (app mein 'add' band).
- Khatam stock: `in_stock=false`, `can_add=false`. Inactive / rejected / pending product kabhi nahi aata.
- Privacy: store ya customer ki coordinates kabhi wapas nahi aati, sirf "2.3 km".
- Koi migration nahi.
"""
import logging
from datetime import timedelta

from django.db.models import Count, Q
from django.http import JsonResponse
from django.utils import timezone

from ..models import Category, FavoriteStore, StoreCategory, VendorProfile
from . import coupons as coupon_engine
from . import offers as vendor_offers
from .geo import attach_distances
from .views_customer_api import _err, customer_api_optional
from .views_customer_home import (STATUS_TEXT, _customer_location, _delivery_section, _f, _iso, _live_stores_qs,
                                  _product_json, _store_json, _with_stock, resolve_area)
from .views_reviews import store_rating_map, store_reviews
from .views_stores import CURRENCY, SORTS, STATUS_ORDER, _live_products, store_serves_area

logger = logging.getLogger(__name__)

LIST_PAGE_SIZE = 20             # stores ki list ka ek page
LIST_POOL = 300                 # area / filter se pehle kitne stores dekhne hain (web 200 leta hai)
DETAIL_PAGE_SIZE = 24           # store detail mein products ka ek page (web jitna)
NEW_STORE_DAYS = 30             # "Naye" filter: itne din ke andar approve hua store
TOP_RATED_MIN = 4.0             # "Top rated" filter: kam az kam itni rating
OTHER_CATEGORY = 0              # bina category wale products ka tab


# ---------------------------------------------------------------- chhote helpers

def _page_number(request):
    try:
        return max(1, min(int(request.GET.get('page', 1)), 10000))
    except (TypeError, ValueError):
        return 1


def _int_param(request, key):
    try:
        return int(request.GET.get(key, ''))
    except (TypeError, ValueError):
        return None


def _flag(request, key):
    return request.GET.get(key) == '1'


def _is_new(st):
    when = st.approved_at or st.created_at
    return bool(when and when >= timezone.now() - timedelta(days=NEW_STORE_DAYS))


def _fmt_time(t):
    """09:00 -> '9:00 AM' (Windows / Linux dono par chalne wala tareeqa)."""
    if not t:
        return ''
    h12 = t.hour % 12 or 12
    return f"{h12}:{t.minute:02d} {'AM' if t.hour < 12 else 'PM'}"


def _hours_text(st):
    if st.opens_at and st.closes_at:
        return f'{_fmt_time(st.opens_at)} - {_fmt_time(st.closes_at)}'
    return ''


def _prepare(stores, ratings=None):
    """Har store par wohi cheezen lagao jo web store_list lagati hai (.status, rating)."""
    ratings = store_rating_map() if ratings is None else ratings
    for st in stores:
        st.status = st.status_label
        r = ratings.get(st.vendor_id)
        st.rating_avg = r['avg'] if r else None
        st.rating_count = r['count'] if r else 0
    return stores


def _card_extras(stores):
    """Sirf us page ke stores ke liye: kitne products + top 3 categories (card ke tags). Do query, N+1 nahi."""
    ids = [st.vendor_id for st in stores]
    if not ids:
        return {}, {}
    live = _live_products().filter(vendor_id__in=ids)
    counts = dict(live.values('vendor').annotate(n=Count('id')).values_list('vendor', 'n'))
    tags = {}
    for vid, cname in live.exclude(category__isnull=True).values_list('vendor', 'category__name').distinct():
        tags.setdefault(vid, []).append(cname)
    return counts, {k: sorted(v)[:3] for k, v in tags.items()}


def _card_json(st, counts, tags):
    j = _store_json(st)
    j['is_new'] = _is_new(st)
    j['product_count'] = counts.get(st.vendor_id, 0)
    j['tags'] = tags.get(st.vendor_id, [])
    return j


def _sort_keys():
    far = float('inf')
    return {
        'recommended': lambda s: (STATUS_ORDER[s.status], s.business_name.lower()),
        'nearest': lambda s: (STATUS_ORDER[s.status], s.distance_km if s.distance_km is not None else far,
                              s.business_name.lower()),
        'rating': lambda s: (STATUS_ORDER[s.status], -(s.rating_avg or 0), -s.rating_count, s.business_name.lower()),
        'fastest': lambda s: (STATUS_ORDER[s.status], s.delivery_time_min, s.delivery_time_max),
        'fee': lambda s: (STATUS_ORDER[s.status], s.delivery_fee or 0),
        'min_order': lambda s: (STATUS_ORDER[s.status], s.min_order_amount or 0),
    }


# ---------------------------------------------------------------- GET stores/

@customer_api_optional(['GET'])
def api_stores(request, profile):
    """Stores ki list: search, filters (Khula / Top rated / Free delivery / Naye / type / category), sort, page."""
    area, source = resolve_area(request, profile)
    loc = _customer_location(request, profile)

    search = request.GET.get('q', '').strip()[:100]
    open_only, free_only = _flag(request, 'open'), _flag(request, 'free')
    top_only, new_only = _flag(request, 'top'), _flag(request, 'new')
    category_id = _int_param(request, 'category')
    type_id = _int_param(request, 'type')

    sort = request.GET.get('sort') or ('nearest' if loc else 'recommended')
    if sort not in SORTS or (sort == 'nearest' and not loc):
        sort = 'nearest' if loc else 'recommended'

    live = _live_products()
    base = _live_stores_qs()

    # Store types (Restaurants, Grocery...): har type mein kitne stores (filter se pehle, web jaisa)
    type_counts = dict(base.exclude(store_category__isnull=True).values('store_category')
                       .annotate(n=Count('id')).values_list('store_category', 'n'))
    store_types = [{'id': t.id, 'name': t.name, 'icon': t.icon, 'count': type_counts[t.id]}
                   for t in StoreCategory.objects.filter(is_active=True) if type_counts.get(t.id)]
    if type_id and type_id not in {t['id'] for t in store_types}:
        type_id = None

    stores_qs = base
    if type_id:
        stores_qs = stores_qs.filter(store_category_id=type_id)
    if category_id:
        stores_qs = stores_qs.filter(vendor__in=live.filter(category_id=category_id).values('vendor'))
    if search:
        stores_qs = stores_qs.filter(
            Q(business_name__icontains=search) | Q(store_description__icontains=search) |
            Q(city__icontains=search) | Q(vendor__in=live.filter(name__icontains=search).values('vendor')))
    if free_only:
        stores_qs = stores_qs.filter(delivery_fee=0)

    stores = _prepare(list(stores_qs.order_by('business_name')[:LIST_POOL]))
    if open_only:
        stores = [s for s in stores if s.status != 'closed']
    if top_only:
        stores = [s for s in stores if s.rating_avg is not None and s.rating_avg >= TOP_RATED_MIN]
    if new_only:
        stores = [s for s in stores if _is_new(s)]

    attach_distances(stores, loc)

    outside = 0
    if area:
        inside = [s for s in stores if store_serves_area(s.city, area, s.delivery_areas)]
        outside = len(stores) - len(inside)
        stores = inside

    stores.sort(key=_sort_keys()[sort])        # khule pehle, band aakhir mein (har sort ke andar)

    total = len(stores)
    page = _page_number(request)
    start = (page - 1) * LIST_PAGE_SIZE
    chunk = stores[start:start + LIST_PAGE_SIZE]
    counts, tags = _card_extras(chunk)

    categories = list(Category.objects.filter(products__in=live).distinct().order_by('name')
                      .values('id', 'name')[:80])
    return JsonResponse({
        'ok': True,
        'area': area,
        'area_source': source,
        'has_location': loc is not None,
        'q': search,
        'sort': sort,
        'sorts': [{'key': k, 'label': v} for k, v in SORTS.items() if k != 'nearest' or loc],
        'filters': {'open': open_only, 'free': free_only, 'top': top_only, 'new': new_only,
                    'type': type_id, 'category': category_id},
        'store_types': store_types,
        'categories': categories,
        'stores': [_card_json(s, counts, tags) for s in chunk],
        'page': page,
        'page_size': LIST_PAGE_SIZE,
        'total': total,
        'has_more': start + LIST_PAGE_SIZE < total,
        'outside_count': outside,
        'logged_in': profile is not None,
    })


# ---------------------------------------------------------------- GET stores/<id>/

def _store_product_json(p, vp):
    """Store ke product ka card: Home wala product json + category, chhota description, stock, 'add' ho sakta hai ya nahi."""
    j = _product_json(p, vp)
    stock = int(getattr(p, 'total_stock', 0) or 0)
    desc = (p.description or '').strip()
    j.update({
        'category_id': p.category_id or OTHER_CATEGORY,
        'category_name': p.category.name if p.category_id and p.category else '',
        'description': desc[:140] + ('...' if len(desc) > 140 else ''),
        'stock': stock,
        'can_add': bool(j['store_open'] and stock > 0),
    })
    return j


def _detail_json(st, loc, area, profile, ratings_summary):
    """Store ki info (cover, timing, fee, rating, coupons, favorite...). Coordinates nahi."""
    st.status = st.status_label
    st.rating_avg = ratings_summary['avg']
    st.rating_count = ratings_summary['count']
    attach_distances([st], loc)
    j = _store_json(st)
    serves = store_serves_area(st.city, area, st.delivery_areas)
    customer = profile.customer if profile is not None else None
    coupons = []
    try:
        for c in coupon_engine.available_for_customer(customer, store_id=st.vendor_id)[:3]:
            coupons.append({'code': c.code, 'title': c.title or c.short_label, 'label': c.short_label,
                            'min_order': _f(c.min_order), 'valid_until': _iso(c.valid_until),
                            'first_order_only': bool(c.first_order_only)})
    except Exception:
        logger.warning('customer store detail: coupons error', exc_info=True)
    favorite = False
    if customer is not None:
        favorite = FavoriteStore.objects.filter(customer=customer, store=st).exists()
    j.update({
        'description': (st.store_description or '').strip(),
        'hours_text': _hours_text(st),
        'opens_at': st.opens_at.strftime('%H:%M') if st.opens_at else '',
        'closes_at': st.closes_at.strftime('%H:%M') if st.closes_at else '',
        'status_text': STATUS_TEXT.get(st.status, ''),
        'is_new': _is_new(st),
        'serves_area': serves,
        'area_message': '' if serves else f'{st.business_name} {area} mein deliver nahi karta.',
        'is_favorite': favorite,
        'coupons': coupons,
        'currency': CURRENCY,
        'share_path': f'/shop/stores/{st.pk}/',
        'share_text': f'{st.business_name} par order karein',
    })
    return j


@customer_api_optional(['GET'])
def api_store_detail(request, profile, pk):
    """Ek store ka poora page. Approved na ho / na mile to 404 (JSON)."""
    store = (VendorProfile.objects.select_related('vendor', 'store_category')
             .filter(pk=pk, is_approved=True).first())
    if store is None:
        return _err('Yeh store nahi mila.', 404, code='not_found')

    area, _src = resolve_area(request, profile)
    loc = _customer_location(request, profile)
    search = request.GET.get('q', '').strip()[:100]
    category_id = _int_param(request, 'category')

    base = _live_products().filter(vendor=store.vendor)
    menu = []
    for row in base.values('category_id', 'category__name').annotate(n=Count('id')).order_by('category__name'):
        cid = row['category_id']
        menu.append({'id': cid if cid else OTHER_CATEGORY, 'name': row['category__name'] or 'Doosra',
                     'count': row['n']})
    # bina category wale (NULL) aakhir mein
    menu.sort(key=lambda m: (m['id'] == OTHER_CATEGORY, m['name'].lower()))

    qs = _with_stock(base).select_related('category', 'unit')
    if category_id == OTHER_CATEGORY:
        qs = qs.filter(category__isnull=True)
    elif category_id:
        qs = qs.filter(category_id=category_id)
    if search:
        qs = qs.filter(Q(name__icontains=search) | Q(description__icontains=search))
    qs = qs.order_by('category__name', 'name', 'id')

    total = qs.count()
    page = _page_number(request)
    start = (page - 1) * DETAIL_PAGE_SIZE
    items = list(qs[start:start + DETAIL_PAGE_SIZE])
    vendor_offers.overlay(items)

    reviews = store_reviews(store.vendor, limit=0)          # sirf rating + bars (list C14 mein)
    summary = reviews['summary']
    info = _detail_json(store, loc, area, profile, summary)
    info['rating_bars'] = reviews['bars']

    return JsonResponse({
        'ok': True,
        'store': info,
        'delivery': _delivery_section(),
        'menu': menu,
        'menu_total': sum(m['count'] for m in menu),
        'products': [_store_product_json(p, store) for p in items],
        'selected_category': category_id,
        'q': search,
        'page': page,
        'page_size': DETAIL_PAGE_SIZE,
        'total': total,
        'has_more': start + DETAIL_PAGE_SIZE < total,
        'logged_in': profile is not None,
    })
