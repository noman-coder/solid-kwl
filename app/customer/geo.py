"""
Location helpers (store verification + customer nearby stores).

- parse_coords      : POST/JSON se lat/lng/accuracy ko check karke nikalta hai
- haversine_km      : do points ke beech faasla (km)
- format_distance   : 850 m / 2.3 km
- get_customer_location / save_customer_location : session (+ login customer ka profile)

Privacy: customer ki coordinates kabhi vendor ya doosre customers ko nahi dikhai jatin.
Store ki coordinates bhi page par nahi chhapti, sirf customer ko "2.3 km" jaisa faasla dikhta hai.
"""
import json
import math

from django.conf import settings
from django.utils import timezone

CUSTOMER_LOC_KEY = 'customer_location'     # session: {'lat':..,'lng':..,'ts': iso}


def parse_coords(request):
    """Returns (lat, lng, accuracy_m_or_None, error_text_or_None). JSON body ya form-POST dono chalte hain."""
    data = {}
    if request.content_type and 'json' in request.content_type:
        try:
            data = json.loads(request.body or b'{}')
        except (ValueError, TypeError):
            return None, None, None, 'Location ka data sahi nahi'
    else:
        data = request.POST
    try:
        lat = float(data.get('lat'))
        lng = float(data.get('lng'))
    except (TypeError, ValueError):
        return None, None, None, 'Location ka data sahi nahi'
    if not (math.isfinite(lat) and math.isfinite(lng)) or not (-90 <= lat <= 90) or not (-180 <= lng <= 180):
        return None, None, None, 'Location ka data sahi nahi'
    if lat == 0 and lng == 0:
        return None, None, None, 'Location ka data sahi nahi'
    acc = data.get('accuracy')
    try:
        acc = float(acc) if acc not in (None, '') else None
        if acc is not None and (not math.isfinite(acc) or acc < 0):
            acc = None
    except (TypeError, ValueError):
        acc = None
    return round(lat, 6), round(lng, 6), (round(acc, 1) if acc is not None else None), None


def max_accuracy_m():
    """Vendor verification ke liye sab se zyada qabil-e-qabool GPS ghalti (meters). settings.VENDOR_LOCATION_MAX_ACCURACY_M se badlein."""
    return float(getattr(settings, 'VENDOR_LOCATION_MAX_ACCURACY_M', 500))


def haversine_km(lat1, lng1, lat2, lng2):
    r = 6371.0088
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def format_distance(km):
    if km is None:
        return ''
    if km < 1:
        return f"{int(round(km * 1000, -1)) or 10} m"
    return f"{km:.1f} km"


def get_customer_location(request):
    """(lat, lng) ya None. Pehle session, phir login customer ka saved profile."""
    loc = request.session.get(CUSTOMER_LOC_KEY)
    if isinstance(loc, dict) and loc.get('lat') is not None and loc.get('lng') is not None:
        return float(loc['lat']), float(loc['lng'])
    try:
        if request.user.is_authenticated and hasattr(request.user, 'customer_profile'):
            cp = request.user.customer_profile
            if cp.latitude is not None and cp.longitude is not None:
                return float(cp.latitude), float(cp.longitude)
    except Exception:
        pass
    return None


def save_customer_location(request, lat, lng):
    request.session[CUSTOMER_LOC_KEY] = {'lat': lat, 'lng': lng, 'ts': timezone.now().isoformat()}
    request.session.modified = True
    try:
        if request.user.is_authenticated and hasattr(request.user, 'customer_profile'):
            cp = request.user.customer_profile
            cp.latitude, cp.longitude, cp.location_updated_at = lat, lng, timezone.now()
            cp.save(update_fields=['latitude', 'longitude', 'location_updated_at'])
    except Exception:
        pass     # profile save fail ho to bhi session wali location kaam karti rahe


def attach_distances(stores, customer_loc):
    """Har store par .distance_km aur .distance_text lagata hai (sirf verified location wale stores par)."""
    for st in stores:
        st.distance_km = None
        st.distance_text = ''
        if customer_loc and st.has_location:
            st.distance_km = haversine_km(customer_loc[0], customer_loc[1], st.latitude, st.longitude)
            st.distance_text = format_distance(st.distance_km)
    return stores
