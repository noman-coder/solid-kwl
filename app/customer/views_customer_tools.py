"""
Customer Tools
==============
Customer ke liye naye kaam:

- reorder_order    : purana order dobara cart mein ("Dobara order karein")
- wishlist_toggle  : product ko Favorites mein daalo / nikalo (heart button)
- wishlist_view    : Favorites ki list, cart mein ek click par add

Purane views nahi badle. Sirf naya table ShopWishlist (migration 0055).
"""
import logging

from django.contrib import messages
from django.db.models import Sum
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.views.decorators.http import require_POST

from ..decorators import customer_login_required
from ..models import CompanyInfo, Inventory, Product, SaleOrder, ShopWishlist
from . import store_orders
from .views_customer_portal import get_product_final_price, store_closed_message

logger = logging.getLogger(__name__)

MAX_WISHLIST = 200


def _customer(request):
    profile = getattr(request.user, 'customer_profile', None)
    return profile.customer if profile else None


def _stock_map(product_ids):
    return {r['product_id']: r['total'] or 0 for r in
            Inventory.objects.filter(product_id__in=product_ids)
            .values('product_id').annotate(total=Sum('stock'))}


@customer_login_required
@require_POST
def reorder_order(request, order_id):
    """Purane order ka maal (maujooda price aur stock ke hisaab se) cart mein daalo."""
    customer = _customer(request)
    if not customer:
        messages.error(request, 'Yeh feature sirf customers ke liye hai')
        return redirect('shop_home')

    order = get_object_or_404(SaleOrder, id=order_id, customer=customer)
    items = list(order.items.select_related('product'))
    stock = _stock_map([i.product_id for i in items])

    cart, added, skipped = {}, 0, []
    for item in items:
        product = item.product
        if not product.is_active or store_closed_message(product):
            skipped.append(product.name)
            continue
        available = int(stock.get(product.id, 0))
        qty = min(max(int(item.qty), 1), available)
        if qty < 1:
            skipped.append(product.name)
            continue
        cart[str(product.id)] = {
            'product_id': product.id,
            'name': product.name,
            'price': float(get_product_final_price(product)),
            'quantity': qty,
            'image': product.image.url if product.image else None,
            'vendor_id': product.vendor_id or 0,
        }
        added += 1

    if not cart:
        messages.error(request, '❌ Is order ka koi product abhi available nahi hai.')
        return redirect('order_detail_customer', order_id=order.id)

    # Naya cart purane cart ko replace karta hai (ek waqt mein ek hi store)
    for key in ('buy_now_mode', 'buy_now_product_id', 'buy_now_item'):
        request.session.pop(key, None)
    request.session['cart'] = cart
    request.session.modified = True

    if skipped:
        shown = ', '.join(skipped[:3]) + ('...' if len(skipped) > 3 else '')
        messages.warning(request, f'⚠️ {len(skipped)} product available nahi: {shown}')
    messages.success(request, f'🛒 {added} product cart mein daal diye. Price aaj ki hai.')
    return redirect('cart_view')


@customer_login_required
@require_POST
def wishlist_toggle(request, product_id):
    customer = _customer(request)
    if not customer:
        return JsonResponse({'success': False, 'message': 'Sirf customers ke liye'}, status=403)

    product = get_object_or_404(Product, id=product_id, is_active=True)
    existing = ShopWishlist.objects.filter(customer=customer, product=product)
    if existing.exists():
        existing.delete()
        saved = False
    else:
        if ShopWishlist.objects.filter(customer=customer).count() >= MAX_WISHLIST:
            return JsonResponse({'success': False,
                                 'message': f'Favorites mein {MAX_WISHLIST} se zyada products nahi ho sakte'})
        ShopWishlist.objects.get_or_create(customer=customer, product=product)
        saved = True

    return JsonResponse({
        'success': True, 'saved': saved,
        'count': ShopWishlist.objects.filter(customer=customer).count(),
        'message': 'Favorites mein shamil' if saved else 'Favorites se hata diya',
    })


@customer_login_required
def wishlist_view(request):
    customer = _customer(request)
    if not customer:
        messages.error(request, 'Yeh page sirf customers ke liye hai')
        return redirect('shop_home')

    rows = list(ShopWishlist.objects.filter(customer=customer, product__is_active=True)
                .select_related('product', 'product__unit')[:MAX_WISHLIST])
    stock = _stock_map([r.product_id for r in rows])
    products = []
    for r in rows:
        p = r.product
        qty = stock.get(p.id, 0)
        products.append({
            'product': p,
            'price': get_product_final_price(p),
            'in_stock': qty > 0,
            'closed': store_closed_message(p),
        })

    company = CompanyInfo.objects.first()
    cart = request.session.get('cart', {})
    return render(request, 'customer_portal/wishlist.html', {
        'company_name': company.name if company else 'Shop',
        'company': company,
        'products': products,
        'cart_count': sum(i['quantity'] for i in cart.values()),
        'page_title': 'Favorites',
    })


def wishlist_ids(request):
    """Product-id ka set (heart ko bhara dikhane ke liye). Login na ho to khali."""
    if not request.user.is_authenticated:
        return set()
    customer = _customer(request)
    if not customer:
        return set()
    return set(ShopWishlist.objects.filter(customer=customer).values_list('product_id', flat=True))
