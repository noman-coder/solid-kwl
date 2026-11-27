"""
Customer Android app ki JSON API - Phase C4: Area / location + Home tab.

Endpoints (sab `api/customer/...`):
    GET    home/        banners, store types, categories (tiles), nazdeeki stores, offers, recently viewed, coupons
    GET    areas/       areas ki list (shehar -> area), "Deliver to" chunne ke liye
    POST   area/        {area} chuna hua area check + us mein kitne stores deliver karte hain (khali area = hata do)
    POST   location/    {lat, lng} GPS se: login customer ki profile mein save + nazdeeki area ka mashwara
    DELETE location/    saved location hata do

Logic naya nahi likha, web ka hi reuse hai:
    views_customer_portal : _home_tiles / _home_masters / _home_categories, get_delivery_settings,
                            get_product_final_price, extract_city_from_address
    views_stores          : store_serves_area (area ke hisab se store ka milan), STATUS_ORDER
    views_reviews         : store_rating_map
    geo                   : haversine / attach_distances / parse_coords
    coupons / offers      : available_for_customer, live_offers_qs, overlay
    models                : ShopBanner.live(), VendorProfile, DeliveryArea, StoreCategory, RecentlyViewed

Farq sirf itna: API stateless hai (session nahi). Is liye customer ka chuna hua area phone mein save hota hai aur
har request par `?area=` ke saath aata hai (guest ke liye bhi). Login customer ne `area` na bheja ho to uske default
address ka shehar liya jata hai (web jaisa). Koi nayi table / migration nahi.

Privacy: customer ki coordinates kisi ko wapas nahi bheji jatin (na vendor, na doosre customer); store ki coordinates
bhi nahi - sirf "2.3 km" jaisa faasla jata hai.

Guest bhi Home dekh sakta hai (token na ho to guest). Token ghalat ho to 401.
"""
import logging
import math
from decimal import Decimal

from django.db.models import Count, DecimalField, Sum, Value
from django.db.models.functions import Coalesce
from django.http import JsonResponse
from django.utils import timezone

from ..models import (DeliveryArea, Product, RecentlyViewed, ShopBanner, StoreCategory, VendorProfile)
from . import coupons as coupon_engine
from . import offers as vendor_offers
from .geo import attach_distances, format_distance, haversine_km, parse_coords
from .thumbs import thumb_url
from .views_customer_api import _data, _err, _media_url, customer_api_optional
from .views_customer_portal import (_home_tiles, extract_city_from_address, get_delivery_settings,
                                    get_product_final_price)
from .views_reviews import store_rating_map
from .views_stores import STATUS_ORDER, store_serves_area

logger = logging.getLogger(__name__)

HOME_STORES_LIMIT = 12          # home par kitne stores (web featured_stores jitne)
HOME_STORES_POOL = 80           # area filter se pehle kitne stores dekhne hain
HOME_OFFERS_LIMIT = 8
HOME_RECENT_LIMIT = 10
HOME_COUPONS_LIMIT = 6
NEARBY_KM = 40                  # GPS se area ka mashwara: itne km ke andar ka store hi madad karega

STATUS_TEXT = {'open': 'Khula hai', 'busy': 'Busy hai', 'closed': 'Abhi band hai'}


# ---------------------------------------------------------------- chhote helpers

def _f(v, nd=2):
    """Decimal / None -> float (JsonResponse Decimal ko string bana deta hai)."""
    if v is None:
        return None
    try:
        return round(float(v), nd)
    except (TypeError, ValueError):
        return None


def _iso(dt):
    try:
        return dt.isoformat() if dt else None
    except Exception:
        return None


def _clean_area(raw):
    """Web `set_delivery_area` jaisa: faltu spaces hatao, lambai 100 tak."""
    if not isinstance(raw, str):
        return ''
    return ' '.join(raw.split())[:100]


def _live_vendor_ids():
    """Wo vendors jin ka kam az kam 1 product shop par live hai (web featured_stores jaisa)."""
    return Product.objects.filter(is_active=True, approval_status='approved', vendor__isnull=False).values('vendor')


def _live_stores_qs():
    return (VendorProfile.objects.filter(is_approved=True, vendor__in=_live_vendor_ids())
            .select_related('vendor', 'store_category'))


def _query_coords(request):
    """?lat=&lng= (GET) - sahi ho to (lat, lng) warna None. parse_coords jaisi hi hadd."""
    try:
        lat = float(request.GET.get('lat'))
        lng = float(request.GET.get('lng'))
    except (TypeError, ValueError):
        return None
    if not (math.isfinite(lat) and math.isfinite(lng)) or not (-90 <= lat <= 90) or not (-180 <= lng <= 180):
        return None
    if lat == 0 and lng == 0:
        return None
    return round(lat, 6), round(lng, 6)


def _customer_location(request, profile):
    """(lat, lng) ya None: pehle request ki ?lat&lng, phir login customer ki saved location."""
    loc = _query_coords(request)
    if loc:
        return loc
    if profile is not None:
        try:
            if profile.latitude is not None and profile.longitude is not None:
                return float(profile.latitude), float(profile.longitude)
        except Exception:
            pass
    return None


def resolve_area(request, profile):
    """(area, source). source: 'chosen' (app ne bheja) | 'address' (default address ka shehar) | ''.

    `?area=` maujood ho (khali bhi) to wahi: khali matlab customer ne \"sab\" chuna. Na ho to login customer ke default
    address ka shehar (web `get_delivery_area` jaisa)."""
    if 'area' in request.GET:
        area = _clean_area(request.GET.get('area'))
        return area, ('chosen' if area else '')
    if profile is not None:
        try:
            customer = profile.customer
            addr = customer.addresses.filter(is_default=True).first()
            if addr and addr.city:
                return addr.city.strip()[:100], 'address'
            city = extract_city_from_address(customer.address)
            if city != 'other':
                return city.title(), 'address'
        except Exception:
            logger.warning('customer api: area lookup error', exc_info=True)
    return '', ''


def _closed_message(st):
    """Band store ka paigham (web store_closed_message jaisa lafz)."""
    return f'{st.business_name} abhi band hai, baad mein order karein.'


def _store_json(st):
    """Home ke store card ke liye (hamesha view mein pehle .status/.rating_* / distance lag chuka hota hai)."""
    return {
        'id': st.pk,
        'name': st.business_name,
        'logo': thumb_url(st.logo),
        'cover': thumb_url(st.cover_image),
        'type': st.store_category.name if st.store_category_id else '',
        'type_icon': st.store_category.icon if st.store_category_id else '',
        'city': st.city or '',
        'status': st.status,
        'status_text': STATUS_TEXT.get(st.status, ''),
        'is_open': st.status != 'closed',
        'closed_message': _closed_message(st) if st.status == 'closed' else '',
        'rating': getattr(st, 'rating_avg', None),
        'rating_count': getattr(st, 'rating_count', 0),
        'delivery_fee': _f(st.delivery_fee),
        'free_delivery': (st.delivery_fee or 0) == 0,
        'min_order': _f(st.min_order_amount),
        'delivery_time_min': st.delivery_time_min,
        'delivery_time_max': st.delivery_time_max,
        'distance_km': round(st.distance_km, 1) if getattr(st, 'distance_km', None) is not None else None,
        'distance_text': getattr(st, 'distance_text', '') or '',
        'verified': bool(st.has_location),
    }


def _product_json(p, vp):
    """Home ke chhote product card. `p` par vendor_offers.overlay lag chuka ho. `vp` = store ki VendorProfile."""
    final = get_product_final_price(p)
    pct = Decimal(p.discount_percentage or 0)
    old = None
    if pct > 0 and pct < 100:
        try:
            old = (Decimal(final) / (Decimal(1) - pct / Decimal(100))).quantize(Decimal('0.01'))
        except Exception:
            old = None
    stock = int(getattr(p, 'total_stock', 0) or 0)
    open_now = bool(vp and vp.status_label != 'closed')
    return {
        'id': p.pk,
        'name': p.name,
        'image': thumb_url(p.image),
        'unit': p.unit.name if getattr(p, 'unit_id', None) and p.unit else '',
        'price': _f(final),
        'old_price': _f(old),
        'discount_percent': _f(pct, 0) if pct > 0 else None,
        'in_stock': stock > 0,
        'store_id': vp.pk if vp else None,
        'store_name': vp.business_name if vp else '',
        'store_open': open_now,
        'closed_message': _closed_message(vp) if (vp and not open_now) else '',
    }


def _with_stock(qs):
    return qs.annotate(total_stock=Coalesce(Sum('inventory__stock'), Value(0.0),
                                            output_field=DecimalField(max_digits=20, decimal_places=2)))


def _banner_action(b):
    """Banner dabane par app kya kare: store kholo / stores tab (filter ke sath) / bahar ka link / kuch nahi."""
    if b.store_id and b.store and b.store.is_approved:
        return {'type': 'store', 'store_id': b.store_id}
    link = (b.link_url or '').strip()
    if not link:
        return {'type': 'none'}
    if link.startswith('/shop/stores'):
        query = link.split('?', 1)[1] if '?' in link else ''
        params = {}
        for part in query.split('#', 1)[0].split('&'):
            if '=' in part:
                k, v = part.split('=', 1)
                if k in ('q', 'free', 'open', 'sort', 'category', 'type') and v:
                    params[k] = v[:60]
        return {'type': 'stores', 'params': params}
    if link.startswith('https://'):
        return {'type': 'url', 'url': link}
    if link.startswith('/'):
        return {'type': 'url', 'url': link, 'relative': True}     # app Api.absUrl se poora link banayegi
    return {'type': 'none'}


# ---------------------------------------------------------------- home ke hisse (har ek akela bhi tootay to home chale)

def _section(name, fn, default):
    try:
        return fn()
    except Exception:
        logger.error('customer home: %s section fail', name, exc_info=True)
        return default


def _banners_section():
    out = []
    for b in list(ShopBanner.live()[:8]):
        img = _media_url(b.image)
        if not img:
            continue
        out.append({'id': b.pk, 'title': b.title, 'image': img, 'action': _banner_action(b)})
    return out


def _store_types_section():
    live = _live_stores_qs()
    counts = dict(live.exclude(store_category__isnull=True).values('store_category')
                  .annotate(n=Count('id')).values_list('store_category', 'n'))
    return [{'id': t.id, 'name': t.name, 'icon': t.icon, 'count': counts[t.id]}
            for t in StoreCategory.objects.filter(is_active=True) if counts.get(t.id)]


def _tiles_section(master_id):
    tiles, master_name = _home_tiles(master_id)
    out = []
    for t in tiles:
        out.append({'id': t['id'], 'name': t['name'], 'icon': t.get('icon') or '',
                    'tone': t.get('tone') or 1,
                    'kind': 'master' if 'master=' in (t.get('href') or '') else 'category'})
    return out, master_name


def _stores_section(profile, area, loc):
    stores = list(_live_stores_qs().order_by('business_name')[:HOME_STORES_POOL])
    ratings = store_rating_map()
    for st in stores:
        st.status = st.status_label
        r = ratings.get(st.vendor_id)
        st.rating_avg = r['avg'] if r else None
        st.rating_count = r['count'] if r else 0
    attach_distances(stores, loc)
    outside = 0
    if area:
        inside = [s for s in stores if store_serves_area(s.city, area, s.delivery_areas)]
        outside = len(stores) - len(inside)
        stores = inside
    far = float('inf')
    stores.sort(key=lambda s: (STATUS_ORDER.get(s.status, 3),
                               s.distance_km if s.distance_km is not None else far,
                               s.business_name.lower()))
    return [_store_json(s) for s in stores[:HOME_STORES_LIMIT]], outside


def _serves(vp, area):
    return bool(vp and vp.is_approved and store_serves_area(vp.city, area, vp.delivery_areas))


def _offers_section(area):
    """Chal rahe offers (offers.live_offers_qs): sirf us area ke khule/band approved stores ke products."""
    rows = (vendor_offers.live_offers_qs()
            .select_related('product', 'product__unit', 'product__vendor__portal_profile')
            .order_by('-discount_percent', '-id')[:60])
    seen, prods, ends = set(), [], {}
    for o in rows:
        p = o.product
        vp = getattr(p.vendor, 'portal_profile', None) if p.vendor_id else None
        if p.pk in seen or not vp or not _serves(vp, area):
            continue
        seen.add(p.pk)
        prods.append((p, vp))
        ends[p.pk] = o.ends_at
        if len(prods) >= HOME_OFFERS_LIMIT:
            break
    if not prods:
        return []
    stock = dict(_with_stock(Product.objects.filter(pk__in=[p.pk for p, _ in prods]))
                 .values_list('pk', 'total_stock'))
    vendor_offers.overlay([p for p, _ in prods])
    out = []
    for p, vp in prods:
        p.total_stock = stock.get(p.pk, 0)
        j = _product_json(p, vp)
        j['offer_ends_at'] = _iso(ends.get(p.pk))
        out.append(j)
    return out


def _recent_section(profile, area):
    """Login customer ke recently viewed products (guest ke liye khali: server par uska record nahi)."""
    if profile is None:
        return []
    ids = list(RecentlyViewed.objects.filter(customer=profile.customer)
               .order_by('-viewed_at').values_list('product_id', flat=True)[:30])
    if not ids:
        return []
    qs = (_with_stock(Product.objects.filter(pk__in=ids, is_active=True, approval_status='approved',
                                             vendor__isnull=False))
          .select_related('unit', 'vendor__portal_profile'))
    by_id = {p.pk: p for p in qs}
    items = []
    for pid in ids:
        p = by_id.get(pid)
        if not p:
            continue
        vp = getattr(p.vendor, 'portal_profile', None)
        if not vp or not _serves(vp, area):
            continue
        items.append((p, vp))
        if len(items) >= HOME_RECENT_LIMIT:
            break
    vendor_offers.overlay([p for p, _ in items])
    return [_product_json(p, vp) for p, vp in items]


def _coupons_section(profile):
    customer = profile.customer if profile is not None else None
    out = []
    for c in coupon_engine.available_for_customer(customer)[:HOME_COUPONS_LIMIT]:
        vp = getattr(c.vendor, 'portal_profile', None) if c.vendor_id else None
        out.append({
            'code': c.code,
            'title': c.title or c.short_label,
            'label': c.short_label,
            'min_order': _f(c.min_order),
            'valid_until': _iso(c.valid_until),
            'first_order_only': bool(c.first_order_only),
            'store_id': vp.pk if vp else None,
            'store_name': vp.business_name if vp else '',
        })
    return out


def _delivery_section():
    d = get_delivery_settings()
    return {'free_enabled': bool(d.get('free_enabled')), 'free_threshold': _f(d.get('free_threshold')),
            'standard_time': d.get('standard_time') or ''}


# ---------------------------------------------------------------- endpoints

@customer_api_optional(['GET'])
def api_home(request, profile):
    """Home tab ka saara data ek hi jawab mein (ek hissa kharab ho to baqi chalte hain, home kabhi khali error nahi)."""
    area, source = resolve_area(request, profile)
    loc = _customer_location(request, profile)
    try:
        master_id = int(request.GET.get('master', ''))
    except (TypeError, ValueError):
        master_id = None

    tiles, master_name = _section('tiles', lambda: _tiles_section(master_id), ([], ''))
    stores, outside = _section('stores', lambda: _stores_section(profile, area, loc), ([], 0))
    return JsonResponse({
        'ok': True,
        'area': area,
        'area_source': source,
        'has_location': loc is not None,
        'banners': _section('banners', _banners_section, []),
        'store_types': _section('store_types', _store_types_section, []),
        'categories': tiles,
        'selected_master': master_id if master_name else None,
        'selected_master_name': master_name,
        'stores': stores,
        'stores_outside_count': outside,
        'offers': _section('offers', lambda: _offers_section(area), []),
        'recently_viewed': _section('recent', lambda: _recent_section(profile, area), []),
        'coupons': _section('coupons', lambda: _coupons_section(profile), []),
        'delivery': _section('delivery', _delivery_section, {}),
        'logged_in': profile is not None,
    })


@customer_api_optional(['GET'])
def api_areas(request, profile):
    """Areas ki master list (admin ki DeliveryArea): [{city, areas: [{name, label}]}]. Shehar khud bhi chuna ja sakta hai."""
    groups = []
    for city, items in DeliveryArea.grouped():
        groups.append({'city': city, 'label': city, 'areas': [{'name': a.name, 'label': a.label} for a in items]})
    listed = {g['city'].lower() for g in groups}
    # admin ne sirf delivery charges mein shehar likhe hon (areas nahi) to bhi chunne ko mil jayen
    for c in (get_delivery_settings().get('city_charges') or {}).keys():
        if c != 'other' and c.lower() not in listed:
            groups.append({'city': c.title(), 'label': c.title(), 'areas': []})
    return JsonResponse({'ok': True, 'groups': groups})


@customer_api_optional(['POST'])
def api_area_set(request, profile):
    """Chuna hua area check karo: {ok, area, known, stores_count}. Khali area = \"sab\" (filter hata do).

    Server par save nahi hota (session nahi, migration nahi): app isay phone mein rakhti aur har request par
    `?area=` mein bhejti hai."""
    area = _clean_area(_data(request).get('area'))
    if not area:
        return JsonResponse({'ok': True, 'area': '', 'known': True, 'stores_count': None})
    labels = {l.lower() for l in DeliveryArea.valid_labels()}
    cities = {c.lower() for c in (get_delivery_settings().get('city_charges') or {}).keys() if c != 'other'}
    cities |= {c.lower() for c, _ in DeliveryArea.grouped()}
    known = area.lower() in labels or area.lower() in cities
    stores = _live_stores_qs()
    count = sum(1 for s in stores[:300] if store_serves_area(s.city, area, s.delivery_areas))
    return JsonResponse({'ok': True, 'area': area, 'known': known, 'stores_count': count})


@customer_api_optional(['POST', 'DELETE'])
def api_location(request, profile):
    """POST {lat, lng}: GPS location. Login customer ki profile mein save (web `set_customer_location` jaisa);
    jawab mein nazdeeki store ke hisab se area ka mashwara. DELETE: saved location hata do.

    Coordinates wapas kabhi nahi bheji jatin."""
    if request.method == 'DELETE':
        if profile is not None:
            try:
                profile.latitude = profile.longitude = profile.location_updated_at = None
                profile.save(update_fields=['latitude', 'longitude', 'location_updated_at'])
            except Exception:
                logger.warning('customer api: location clear fail', exc_info=True)
        return JsonResponse({'ok': True})

    lat, lng, _acc, err = parse_coords(request)
    if err:
        return _err(err, 400, code='bad_location')
    saved = False
    if profile is not None:
        try:
            profile.latitude, profile.longitude, profile.location_updated_at = lat, lng, timezone.now()
            profile.save(update_fields=['latitude', 'longitude', 'location_updated_at'])
            saved = True
        except Exception:
            logger.warning('customer api: location save fail', exc_info=True)     # save na ho to bhi mashwara chale

    nearest, nearest_km = None, None
    for st in _live_stores_qs():
        if not st.has_location:
            continue
        km = haversine_km(lat, lng, st.latitude, st.longitude)
        if nearest_km is None or km < nearest_km:
            nearest, nearest_km = st, km
    suggested, near_store = '', None
    if nearest is not None and nearest_km <= NEARBY_KM:
        suggested = (nearest.city or '').strip()
        near_store = {'id': nearest.pk, 'name': nearest.business_name, 'distance_text': format_distance(nearest_km)}
    return JsonResponse({'ok': True, 'saved': saved, 'suggested_area': suggested, 'nearest_store': near_store,
                         'message': '' if suggested else 'Aap ki location ke nazdeek abhi koi store nahi mila. '
                                                          'List se apna area chunein.'})
