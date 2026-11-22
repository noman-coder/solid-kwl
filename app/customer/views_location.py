"""Customer location endpoints (shop par popup se)."""
from django.http import JsonResponse
from django.views.decorators.http import require_POST

from .geo import CUSTOMER_LOC_KEY, parse_coords, save_customer_location


@require_POST
def set_customer_location(request):
    """Customer ne popup mein 'Allow' kiya -> browser ki location yahan save hoti hai."""
    lat, lng, _acc, err = parse_coords(request)
    if err:
        return JsonResponse({'success': False, 'error': err}, status=400)
    save_customer_location(request, lat, lng)
    return JsonResponse({'success': True})


@require_POST
def clear_customer_location(request):
    """Customer apni saved location hata sakta hai."""
    request.session.pop(CUSTOMER_LOC_KEY, None)
    request.session.modified = True
    try:
        if request.user.is_authenticated and hasattr(request.user, 'customer_profile'):
            cp = request.user.customer_profile
            cp.latitude = cp.longitude = cp.location_updated_at = None
            cp.save(update_fields=['latitude', 'longitude', 'location_updated_at'])
    except Exception:
        pass
    return JsonResponse({'success': True})
