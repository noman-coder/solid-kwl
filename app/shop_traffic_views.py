"""Public shop helper views for Traffic Analytics."""
from django.http import Http404, HttpResponseRedirect

from .models import ShopBanner
from .shop_traffic import log_banner_click


def banner_click(request, pk):
    """Banner par click ginta hai, phir banner ke asli link par bhej deta hai (link admin ne set kiya hota hai)."""
    try:
        banner = ShopBanner.objects.select_related('store').get(pk=pk)
    except ShopBanner.DoesNotExist:
        raise Http404("Banner not found")
    target = banner.get_link()
    if not target:
        raise Http404("Banner has no link")
    log_banner_click(request, banner)
    return HttpResponseRedirect(target)
