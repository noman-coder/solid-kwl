"""
Customer Android app ki JSON API - Phase C6: Products (search, list, detail, suggest).

Endpoints (sab `api/customer/...`, guest bhi dekh sakta hai):
    GET products/        ?q=&category=&master=&store=&sort=&price_min=&price_max=&in_stock=1&area=&page=
    GET products/<id>/   product ka poora page (tasveeren, qeemat + offer, stock, store, milte julte products)
    GET search/suggest/  ?q=   typing ke waqt halki suggestions (products / stores / categories)

Logic naya nahi likha, web ka hi reuse hai:
    views_customer_portal : find_typo_correction (galat spelling), get_product_final_price, _alias_product_ids
    offers                : overlay (offer % memory mein), active_offer_map
    views_customer_home   : resolve_area, _product_json (qeemat + purani qeemat), _with_stock, _live_stores_qs
    views_customer_stores : _store_product_json (can_add, stock), _card_json helpers
    views_stores          : store_serves_area, _live_products
    views_reviews         : store_rating_map
    RecentlyViewed        : login customer ka record (web track_view jaisa, max 20)

Rules:
- Sirf wohi product jo `is_active` + `approval_status='approved'` + vendor wala ho aur us ka store approved ho.
  Inactive / rejected / pending product kabhi nahi aata (list mein bhi nahi, detail mein 404).
- Area chuna ho to sirf us area mein deliver karne wale stores ke products (list). Detail mein area ke bahar ka product
  khul jata hai magar `serves_area=false` + `can_add=false` + paigham.
- Khatam stock: `in_stock=false`, `can_add=false`. Band store: `store_open=false`, `can_add=false`.
- Galat spelling: kuch na mile to find_typo_correction; sahi lafz se products mile to `did_you_mean` + `typo_corrected`.
- Qeemat wohi jo web mein: batch ki qeemat, product ka discount, aur offer (do discount jama nahi, bara wala).
- Privacy: store ki coordinates kabhi wapas nahi aati. Stock ki asli tadaad sirf kam hone par (low_stock) dikhti hai.
- Koi migration nahi.
"""
import logging
from decimal import Decimal

from django.core.cache import cache
from django.db.models import Case, IntegerField, Q, Value, When
from django.http import JsonResponse

from ..models import Category, Product, RecentlyViewed, VendorProfile
from . import offers as vendor_offers
from .thumbs import thumb_url
from .views_customer_api import _err, customer_api_optional
from .views_customer_home import (STATUS_TEXT, _closed_message, _customer_location, _f, _iso, _live_stores_qs,
                                  _product_json, _with_stock, resolve_area)
from .views_customer_portal import _alias_product_ids, find_typo_correction, get_product_final_price
from .views_customer_stores import _int_param, _page_number
from .views_reviews import store_rating_map
from .views_stores import CURRENCY, store_serves_area

logger = logging.getLogger(__name__)

PAGE_SIZE = 24                  # products ka ek page (web jitna)
PRICE_POOL = 600                # qeemat se filter / sort ho to itne products Python mein dekhte hain (exact final price)
RELATED_LIMIT = 8
SUGGEST_PRODUCTS = 6
SUGGEST_STORES = 3
SUGGEST_CATEGORIES = 3
MIN_SUGGEST_CHARS = 2
RECENT_KEEP = 20                # RecentlyViewed: web jitna
SEARCH_LOG_SECONDS = 30         # ek hi lafz ka dobara log is se pehle nahi

SORTS = {
    'relevance': 'Sab se munasib',
    'newest': 'Naye pehle',
    'price_low': 'Qeemat: kam se zyada',
    'price_high': 'Qeemat: zyada se kam',
    'name': 'Naam (A-Z)',
}


# ---------------------------------------------------------------- chhote helpers

def _decimal_param(request, key):
    """?price_min=100 -> Decimal. Ghalat / manfi / bahut bara ho to None."""
    raw = (request.GET.get(key) or '').strip()
    if not raw:
        return None
    try:
        v = Decimal(raw)
    except Exception:
        return None
    if not v.is_finite() or v < 0 or v > Decimal('100000000'):
        return None
    return v


def _live_catalog():
    """Customer ko dikhne wale products: active + approved + vendor ka approved store."""
    store_vendors = VendorProfile.objects.filter(is_approved=True).values('vendor')
    return Product.objects.filter(is_active=True, approval_status='approved', vendor__isnull=False,
                                  vendor__in=store_vendors)


def _serving_vendor_ids(area):
    """Un stores ke vendor ids jo `area` mein deliver karte hain (area khali ho to None = koi hadd nahi)."""
    if not area:
        return None
    return [st.vendor_id for st in _live_stores_qs().only('vendor_id', 'city', 'delivery_areas')
            if store_serves_area(st.city, area, st.delivery_areas)]


def _search_q(text):
    """Web jaisi talash: naam, serial, barcode, description, category, brand aur admin ke alias."""
    return (Q(name__icontains=text) | Q(serial_no__icontains=text) | Q(barcode__icontains=text) |
            Q(description__icontains=text) | Q(category__name__icontains=text) | Q(brand__name__icontains=text) |
            Q(id__in=_alias_product_ids(text)))


def _relevance(qs, text):
    """Naam se shuru hone wale pehle, phir naam mein jahan lafz ho, phir baqi."""
    return qs.annotate(rel_rank=Case(
        When(name__iexact=text, then=Value(0)),
        When(name__istartswith=text, then=Value(1)),
        When(name__icontains=text, then=Value(2)),
        default=Value(3), output_field=IntegerField())).order_by('rel_rank', 'name', 'id')


def _filtered(request, area, text, category_id, master_id, store_id, in_stock):
    """Sab filter lagi hui products ki queryset (sort / page se pehle)."""
    qs = _live_catalog()
    vendors = _serving_vendor_ids(area)
    if vendors is not None:
        qs = qs.filter(vendor_id__in=vendors)
    if store_id:
        qs = qs.filter(vendor__portal_profile__pk=store_id)
    if category_id:
        qs = qs.filter(category_id=category_id)
    elif master_id:
        qs = qs.filter(category__master_id=master_id)
    if text:
        qs = qs.filter(_search_q(text))
    qs = _with_stock(qs).select_related('category', 'brand', 'unit', 'vendor__portal_profile')
    if in_stock:
        qs = qs.filter(total_stock__gt=0)
    return qs


def _log_search(request, profile, text, count, corrected):
    """Traffic Analytics ke liye lafz ka record (web log_search jaisa), magar session bana kar nahi. Kabhi masla nahi."""
    try:
        from app.models import ShopSearchLog
        from app.shop_traffic import _device, _local_now, is_bot, normalize_keyword
        norm = normalize_keyword(text)
        if not norm or is_bot(request):
            return
        who = f'app-c{profile.pk}' if profile is not None else 'app-guest'
        if not cache.add(f'cust_search_log:{who}:{norm}', 1, SEARCH_LOG_SECONDS):
            return
        day, hour = _local_now()
        ShopSearchLog.objects.create(
            keyword=text[:100], keyword_norm=norm, results_count=int(count or 0), corrected_to=(corrected or '')[:100],
            day=day, hour=hour, session_key=who, device=_device(request))
    except Exception:
        logger.warning('customer products: search log error', exc_info=True)


def _track_view(profile, product):
    """Login customer ka recently viewed (web RecentlyViewed.track_view jaisa: purana hata kar upar, max 20)."""
    try:
        customer = profile.customer
        RecentlyViewed.objects.filter(customer=customer, session_key=None, product=product).delete()
        RecentlyViewed.objects.create(customer=customer, product=product)
        for old in RecentlyViewed.objects.filter(customer=customer)[RECENT_KEEP:]:
            old.delete()
    except Exception:
        logger.warning('customer products: recently viewed error', exc_info=True)


def _card(p):
    """List / grid ka product card: Home wala card + category, stock aur 'add' ho sakta hai ya nahi."""
    vp = getattr(p.vendor, 'portal_profile', None)
    j = _product_json(p, vp)
    stock = int(getattr(p, 'total_stock', 0) or 0)
    j.update({
        'category_id': p.category_id,
        'category_name': p.category.name if p.category_id and p.category else '',
        'brand': p.brand.name if getattr(p, 'brand_id', None) and p.brand else '',
        'stock': stock,
        'can_add': bool(j['store_open'] and stock > 0),
    })
    return j


# ---------------------------------------------------------------- GET products/

@customer_api_optional(['GET'])
def api_products(request, profile):
    """Products ki list / talash: filters, sort, galat spelling par bhi, page."""
    area, source = resolve_area(request, profile)
    text = ' '.join(request.GET.get('q', '').split())[:100]
    category_id = _int_param(request, 'category')
    master_id = _int_param(request, 'master')
    store_id = _int_param(request, 'store')
    in_stock = request.GET.get('in_stock') == '1'
    price_min = _decimal_param(request, 'price_min')
    price_max = _decimal_param(request, 'price_max')
    if price_min is not None and price_max is not None and price_min > price_max:
        price_min, price_max = price_max, price_min

    sort = request.GET.get('sort') or ('relevance' if text else 'newest')
    if sort not in SORTS or (sort == 'relevance' and not text):
        sort = 'relevance' if text else 'newest'

    qs = _filtered(request, area, text, category_id, master_id, store_id, in_stock)

    # Galat spelling: kuch na mile to web wala hi find_typo_correction
    searched = text
    did_you_mean = ''
    if text and len(text) >= 3 and not qs.exists():
        try:
            corrected, original = find_typo_correction(text)
        except Exception:
            logger.warning('customer products: typo correction error', exc_info=True)
            corrected, original = text, None
        if original and corrected and corrected.lower() != text.lower():
            fixed = _filtered(request, area, corrected, category_id, master_id, store_id, in_stock)
            if fixed.exists():
                qs, searched, did_you_mean = fixed, corrected, corrected

    if searched:
        ordered = {
            'relevance': lambda q: _relevance(q, searched),
            'newest': lambda q: q.order_by('-id'),
            'price_low': lambda q: q.order_by('price', 'id'),
            'price_high': lambda q: q.order_by('-price', 'id'),
            'name': lambda q: q.order_by('name', 'id'),
        }
    else:
        ordered = {
            'newest': lambda q: q.order_by('-id'),
            'price_low': lambda q: q.order_by('price', 'id'),
            'price_high': lambda q: q.order_by('-price', 'id'),
            'name': lambda q: q.order_by('name', 'id'),
        }
    qs = ordered.get(sort, ordered['newest'])(qs)

    page = _page_number(request)
    start = (page - 1) * PAGE_SIZE

    if price_min is not None or price_max is not None or sort in ('price_low', 'price_high'):
        # Final qeemat (batch + discount + offer) par: Python mein, taake dikhne wali qeemat se hi filter / sort ho.
        pool = list(qs[:PRICE_POOL])
        vendor_offers.overlay(pool)
        priced = [(get_product_final_price(p), p) for p in pool]
        if price_min is not None:
            priced = [t for t in priced if t[0] >= price_min]
        if price_max is not None:
            priced = [t for t in priced if t[0] <= price_max]
        if sort == 'price_low':
            priced.sort(key=lambda t: (t[0], t[1].pk))
        elif sort == 'price_high':
            priced.sort(key=lambda t: (-t[0], t[1].pk))
        total = len(priced)
        items = [p for _price, p in priced[start:start + PAGE_SIZE]]
    else:
        total = qs.count()
        items = list(qs[start:start + PAGE_SIZE])
        vendor_offers.overlay(items)

    cards = [_card(p) for p in items]
    if page == 1 and text:
        _log_search(request, profile, text, total, did_you_mean)

    base = _live_catalog()
    vendors = _serving_vendor_ids(area)
    if vendors is not None:
        base = base.filter(vendor_id__in=vendors)
    categories = list(Category.objects.filter(products__in=base).distinct().order_by('name').values('id', 'name')[:80])

    return JsonResponse({
        'ok': True,
        'area': area,
        'area_source': source,
        'q': text,
        'searched_q': searched,
        'did_you_mean': did_you_mean,
        'typo_corrected': bool(did_you_mean),
        'sort': sort,
        'sorts': [{'key': k, 'label': v} for k, v in SORTS.items() if k != 'relevance' or searched],
        'filters': {'category': category_id, 'master': master_id, 'store': store_id, 'in_stock': in_stock,
                    'price_min': _f(price_min) if price_min is not None else None,
                    'price_max': _f(price_max) if price_max is not None else None},
        'categories': categories,
        'products': cards,
        'page': page,
        'page_size': PAGE_SIZE,
        'total': total,
        'has_more': start + PAGE_SIZE < total,
        'currency': CURRENCY,
        'logged_in': profile is not None,
    })


# ---------------------------------------------------------------- GET products/<id>/

def _gallery(p):
    """Product ki tasveeren. Abhi ek hi photo hoti hai: (chhoti, poori). Photo na ho to khali list."""
    full = None
    try:
        full = p.image.url if p.image else None
    except ValueError:
        full = None
    if not full:
        return []
    return [{'thumb': thumb_url(p.image) or full, 'full': full}]


def _store_box(vp, rating):
    """Product page par store ka chhota card (coordinates nahi)."""
    st = vp.status_label
    return {
        'id': vp.pk,
        'name': vp.business_name,
        'logo': thumb_url(vp.logo),
        'city': vp.city or '',
        'status': st,
        'status_text': STATUS_TEXT.get(st, ''),
        'is_open': st != 'closed',
        'closed_message': _closed_message(vp) if st == 'closed' else '',
        'rating': rating['avg'] if rating else None,
        'rating_count': rating['count'] if rating else 0,
        'delivery_fee': _f(vp.delivery_fee),
        'free_delivery': (vp.delivery_fee or 0) == 0,
        'min_order': _f(vp.min_order_amount),
        'delivery_time_min': vp.delivery_time_min,
        'delivery_time_max': vp.delivery_time_max,
    }


def _related(product, area, vendors):
    """Milte julte: wohi category / brand ke live products (khud ko chhor kar), pehle isi store ke."""
    cond = Q()
    if product.category_id:
        cond |= Q(category_id=product.category_id)
    if product.brand_id:
        cond |= Q(brand_id=product.brand_id)
    if not cond:
        return []
    qs = _live_catalog().filter(cond).exclude(pk=product.pk)
    if vendors is not None:
        qs = qs.filter(vendor_id__in=vendors)
    qs = _with_stock(qs).select_related('category', 'brand', 'unit', 'vendor__portal_profile')
    qs = qs.annotate(same_store=Case(When(vendor_id=product.vendor_id, then=Value(0)), default=Value(1),
                                output_field=IntegerField())).order_by('same_store', '-id')
    items = list(qs[:RELATED_LIMIT])
    vendor_offers.overlay(items)
    return [_card(p) for p in items]


@customer_api_optional(['GET'])
def api_product_detail(request, profile, pk):
    """Ek product ka poora page. Live na ho (inactive / rejected / store band-approved nahi) / na mile to 404 (JSON)."""
    product = (_with_stock(_live_catalog().filter(pk=pk))
               .select_related('category', 'brand', 'unit', 'vendor__portal_profile').first())
    if product is None:
        return _err('Yeh product nahi mila.', 404, code='not_found')
    vp = getattr(product.vendor, 'portal_profile', None)
    if vp is None:
        return _err('Yeh product nahi mila.', 404, code='not_found')

    area, _src = resolve_area(request, profile)
    vendors = _serving_vendor_ids(area)
    vendor_offers.overlay([product])
    if profile is not None:
        _track_view(profile, product)

    j = _card(product)
    stock = int(getattr(product, 'total_stock', 0) or 0)
    serves = store_serves_area(vp.city, area, vp.delivery_areas)
    offer_pct = getattr(product, 'offer_percent', None)
    offer_ends = None
    if offer_pct:
        try:
            offer_ends = vendor_offers.live_offers_qs().filter(product=product).order_by('ends_at') \
                .values_list('ends_at', flat=True).first()
        except Exception:
            offer_ends = None
    try:
        threshold = float(product.low_stock_threshold or 0)
    except (TypeError, ValueError):
        threshold = 0
    low = 0 < stock <= max(threshold, 0)
    rating = store_rating_map().get(vp.vendor_id)

    j.update({
        'description': (product.description or '').strip(),
        'images': _gallery(product),
        'serves_area': serves,
        'area_message': '' if serves else f'{vp.business_name} {area} mein deliver nahi karta.',
        'can_add': bool(j['store_open'] and stock > 0 and serves),
        'max_qty': stock if stock > 0 else 0,
        'low_stock': low,
        'stock_text': ('Sirf %d bache hain' % stock) if low else ('Stock mein hai' if stock > 0 else 'Abhi available nahi'),
        'has_offer': bool(offer_pct),
        'offer_percent': _f(offer_pct, 0) if offer_pct else None,
        'offer_ends_at': _iso(offer_ends),
        'store': _store_box(vp, rating),
        'related': _related(product, area, vendors),
        'currency': CURRENCY,
        'share_path': f'/shop/product/{product.pk}/',
        'share_text': f'{product.name} - {vp.business_name} se mangwayein',
    })
    return JsonResponse({'ok': True, 'product': j, 'logged_in': profile is not None})


# ---------------------------------------------------------------- GET search/suggest/

@customer_api_optional(['GET'])
def api_suggest(request, profile):
    """Typing ke waqt halki suggestions: products, stores, categories. Chhota jawab, kam query."""
    text = ' '.join(request.GET.get('q', '').split())[:60]
    out = {'ok': True, 'q': text, 'products': [], 'stores': [], 'categories': [], 'did_you_mean': ''}
    if len(text) < MIN_SUGGEST_CHARS:
        return JsonResponse(out)

    area, _src = resolve_area(request, profile)
    vendors = _serving_vendor_ids(area)
    base = _live_catalog()
    if vendors is not None:
        base = base.filter(vendor_id__in=vendors)

    def run(term):
        prods = list(_relevance(base.filter(Q(name__icontains=term) | Q(id__in=_alias_product_ids(term))), term)
                     .select_related('unit', 'vendor__portal_profile')[:SUGGEST_PRODUCTS])
        stores = list(_live_stores_qs().filter(business_name__icontains=term).order_by('business_name')[:SUGGEST_STORES * 3])
        if area:
            stores = [s for s in stores if store_serves_area(s.city, area, s.delivery_areas)]
        stores = stores[:SUGGEST_STORES]
        cats = list(Category.objects.filter(name__icontains=term, products__in=base).distinct()
                    .order_by('name').values('id', 'name')[:SUGGEST_CATEGORIES])
        return prods, stores, cats

    prods, stores, cats = run(text)
    if not (prods or stores or cats) and len(text) >= 3:
        try:
            corrected, original = find_typo_correction(text)
        except Exception:
            corrected, original = text, None
        if original and corrected and corrected.lower() != text.lower():
            prods, stores, cats = run(corrected)
            if prods or stores or cats:
                out['did_you_mean'] = corrected

    out['products'] = [{'id': p.pk, 'name': p.name, 'image': thumb_url(p.image),
                        'unit': p.unit.name if p.unit_id and p.unit else '',
                        'store_name': p.vendor.portal_profile.business_name
                        if getattr(p.vendor, 'portal_profile', None) else ''} for p in prods]
    out['stores'] = [{'id': s.pk, 'name': s.business_name, 'logo': thumb_url(s.logo), 'city': s.city or ''}
                     for s in stores]
    out['categories'] = cats
    return JsonResponse(out)
