"""
Extras
======
Customer: store_favorite_toggle (dil wala button store page par), favorite_stores_view (pasandida stores)
Vendor  : vendor_reviews (customers ki ratings), vendor_review_reply (jawab dein)

Naya table FavoriteStore aur OrderReview par 2 naye columns (migration 0056). Purana data safe.
"""
import logging

from django.contrib import messages
from django.core.paginator import Paginator
from django.db.models import Avg, Count
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.views.decorators.http import require_POST

from ..decorators import customer_login_required, vendor_login_required
from ..models import CompanyInfo, FavoriteStore, OrderReview, VendorProfile
from .views_reviews import _reviewer_name
from .views_vendor_portal import _company_name

logger = logging.getLogger(__name__)

MAX_FAVORITE_STORES = 100
MAX_REPLY_LEN = 300


def _customer(request):
    profile = getattr(request.user, 'customer_profile', None)
    return profile.customer if profile else None


def favorite_store_ids(request):
    """Login customer ke pasandida store ids (dil bhara dikhane ke liye). Warna khali set."""
    if not request.user.is_authenticated:
        return set()
    customer = _customer(request)
    if not customer:
        return set()
    return set(FavoriteStore.objects.filter(customer=customer).values_list('store_id', flat=True))


@customer_login_required
@require_POST
def store_favorite_toggle(request, pk):
    customer = _customer(request)
    if not customer:
        return JsonResponse({'success': False, 'message': 'Sirf customers ke liye'}, status=403)
    store = get_object_or_404(VendorProfile, pk=pk, is_approved=True)
    existing = FavoriteStore.objects.filter(customer=customer, store=store)
    if existing.exists():
        existing.delete()
        saved = False
    else:
        if FavoriteStore.objects.filter(customer=customer).count() >= MAX_FAVORITE_STORES:
            return JsonResponse({'success': False, 'message': f'{MAX_FAVORITE_STORES} se zyada favorite stores nahi ho sakte'})
        FavoriteStore.objects.get_or_create(customer=customer, store=store)
        saved = True
    return JsonResponse({'success': True, 'saved': saved,
                         'message': 'Favorite stores mein shamil' if saved else 'Favorite stores se hata diya'})


@customer_login_required
def favorite_stores_view(request):
    customer = _customer(request)
    if not customer:
        messages.error(request, 'Yeh page sirf customers ke liye hai')
        return redirect('shop_home')
    favs = list(FavoriteStore.objects.filter(customer=customer, store__is_approved=True)
                .select_related('store', 'store__store_category')[:MAX_FAVORITE_STORES])
    company = CompanyInfo.objects.first()
    cart = request.session.get('cart', {})
    return render(request, 'customer_portal/favorite_stores.html', {
        'favorites': favs,
        'company_name': company.name if company else 'Shop',
        'company': company,
        'cart_count': sum(i.get('quantity', 0) for i in cart.values()),
        'page_title': 'Favorite Stores',
    })


# ------------------------------------------------------------------ vendor reviews
@vendor_login_required
def vendor_reviews(request):
    profile = request.user.vendor_profile
    vendor = profile.vendor
    base = OrderReview.objects.filter(vendor=vendor, vendor_rating__isnull=False)
    agg = base.aggregate(avg=Avg('vendor_rating'), n=Count('id'))
    unanswered = request.GET.get('unanswered') == '1'
    qs = base.select_related('sale_order__customer')
    if unanswered:
        qs = qs.filter(vendor_reply='')
    page = Paginator(qs.order_by('-created_at'), 20).get_page(request.GET.get('page', 1))
    rows = [{'rv': rv, 'name': _reviewer_name(rv.sale_order)} for rv in page]
    return render(request, 'customer_portal/vendor/reviews.html', {
        'page_title': 'Customer Reviews',
        'profile': profile,
        'rows': rows,
        'page_obj': page,
        'avg': round(agg['avg'], 1) if agg['avg'] else None,
        'count': agg['n'],
        'unanswered': unanswered,
        'unanswered_count': base.filter(vendor_reply='').count(),
        'max_len': MAX_REPLY_LEN,
        'company_name': _company_name(),
    })


@vendor_login_required
@require_POST
def vendor_review_reply(request, pk):
    vendor = request.user.vendor_profile.vendor
    review = get_object_or_404(OrderReview, pk=pk, vendor=vendor)
    text = (request.POST.get('reply') or '').strip()[:MAX_REPLY_LEN]
    review.vendor_reply = text
    review.vendor_replied_at = timezone.now() if text else None
    review.save(update_fields=['vendor_reply', 'vendor_replied_at'])
    messages.success(request, 'Jawab save ho gaya' if text else 'Jawab hata diya')
    return redirect(request.POST.get('next') if (request.POST.get('next') or '').startswith('/shop/vendor/') else 'vendor_reviews')
