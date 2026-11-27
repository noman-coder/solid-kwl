"""
Account deletion + public legal pages (Google Play requirements)
=================================================================
- Customer / Vendor / Rider: in-app "Delete Account" (password confirm).
- /privacy-policy/   : public Privacy Policy page (no login needed).
- /delete-account/   : public page explaining how to delete the account / data.

NO model or database change is needed. Nothing here touches migrations.

How deletion works (so orders / accounting never break):
  * Customer: personal data is wiped (name, phone, email, address, saved addresses,
    OTPs, chat, profile photo) and the login (User + CustomerProfile) is deleted.
    The Customer row itself is kept but anonymized, because orders, sales and ledger
    rows depend on it (they CASCADE) - deleting it would erase accounting history.
  * Vendor / Rider: personal + store data is wiped and the login is closed
    (inactive, unusable password, anonymized username). The profile row is kept
    because settlements / commission reports depend on it.
  * Deletion is blocked while an order is still active, so no customer / rider is
    left stranded mid-delivery.
"""
import logging

from django.contrib import messages
from django.contrib.auth import logout
from django.core.cache import cache
from django.db import transaction
from django.shortcuts import redirect, render
from django.views.decorators.http import require_POST

from ..decorators import customer_login_required, vendor_login_required
from ..models import (
    CompanyInfo, Customer, CustomerAddress, CustomerOTP, SaleOrder,
)

logger = logging.getLogger(__name__)

ACTIVE_ORDER_STATUSES = ['pending', 'confirmed', 'processing', 'ready', 'partially_delivered']
RIDER_ACTIVE_STATUSES = ['assigned', 'picked_up', 'in_transit']
MAX_PASSWORD_TRIES = 5
LOCK_SECONDS = 600


# ============================================
# HELPERS
# ============================================

def _company():
    try:
        return CompanyInfo.objects.first()
    except Exception:
        return None


def _legal_context(request, title):
    company = _company()
    return {
        'page_title': title,
        'company_name': company.name if company and company.name else 'Khanewal Connect',
        'company_email': company.email if company and company.email else '',
        'company_phone': company.contact_number if company and company.contact_number else '',
        'company_address': company.address if company and company.address else '',
    }


def _password_ok(request, user):
    """Re-check the password before deleting (with a small brute-force limit)."""
    key = f"delete_account:{user.pk}"
    tries = cache.get(key, 0)
    if tries >= MAX_PASSWORD_TRIES:
        messages.error(request, '🔒 Too many wrong attempts. Please try again after 10 minutes.')
        return False
    if not request.POST.get('confirm_delete'):
        messages.error(request, '❌ Please tick the confirmation box to delete your account.')
        return False
    password = request.POST.get('password', '')
    if not password or not user.check_password(password):
        cache.set(key, tries + 1, LOCK_SECONDS)
        messages.error(request, '❌ Password is wrong. Account was not deleted.')
        return False
    cache.delete(key)
    return True


def _drop_file(field_file):
    """Remove an uploaded file from storage; never fail the deletion because of it."""
    try:
        if field_file and getattr(field_file, 'name', ''):
            field_file.delete(save=False)
    except Exception:
        logger.warning("Could not remove file %s", getattr(field_file, 'name', ''), exc_info=True)


def _best_effort(label, fn):
    """Run an optional cleanup step inside its own savepoint so one failure never breaks the rest."""
    try:
        with transaction.atomic():
            fn()
    except Exception:
        logger.warning("%s skipped", label, exc_info=True)


def _close_login(user, tag):
    """Anonymize + disable a login without deleting the row (keeps linked records safe)."""
    user.username = f"deleted_{tag}_{user.pk}"
    user.email = ''
    user.first_name = ''
    user.last_name = ''
    user.is_active = False
    user.set_unusable_password()
    user.save()


# ============================================
# CUSTOMER
# ============================================

@customer_login_required
@require_POST
def delete_account_customer(request):
    user = request.user
    if user.is_staff or user.is_superuser or not hasattr(user, 'customer_profile'):
        messages.error(request, '❌ This account cannot be deleted from here.')
        return redirect('shop_home')

    if not _password_ok(request, user):
        return redirect('my_account')

    profile = user.customer_profile
    customer = profile.customer

    if SaleOrder.objects.filter(customer=customer, status__in=ACTIVE_ORDER_STATUSES).exists():
        messages.error(
            request,
            '⚠️ You still have an active order. Please wait until it is delivered or cancel it, '
            'then delete your account.'
        )
        return redirect('my_account')

    try:
        with transaction.atomic():
            phone = customer.contact_number

            _drop_file(profile.profile_pic)
            CustomerAddress.objects.filter(customer=customer).delete()

            # Best-effort cleanup of other personal data (each step is optional).
            def _otps():
                if phone:
                    CustomerOTP.objects.filter(phone=phone).delete()

            def _otp_audit():
                if phone:
                    from ..models import OTPAuditLog
                    OTPAuditLog.objects.filter(phone=phone).update(phone='deleted')

            def _recent():
                from ..models import RecentlyViewed
                RecentlyViewed.objects.filter(customer=customer).delete()

            def _chat():
                from ..models import ChatConversation
                ChatConversation.objects.filter(customer=customer).delete()

            def _portal_orders():
                from ..models import CustomerOrder
                CustomerOrder.objects.filter(customer=customer).update(
                    shipping_phone='', shipping_address='', billing_address=None)

            _best_effort("OTP cleanup", _otps)
            _best_effort("OTP audit cleanup", _otp_audit)
            _best_effort("Recently viewed cleanup", _recent)
            _best_effort("Chat cleanup", _chat)
            _best_effort("Customer order snapshot cleanup", _portal_orders)

            # Keep the Customer row (orders/ledger depend on it) but remove all personal data.
            Customer.objects.filter(pk=customer.pk).update(
                name='Deleted User', contact_number=None, email=None, address=None,
                ref_name_1=None, ref_contact_number_1=None,
                ref_name_2=None, ref_contact_number_2=None,
            )

            # Deleting the login also deletes the CustomerProfile (CASCADE).
            user.delete()
    except Exception:
        logger.exception("Customer account deletion failed")
        messages.error(request, '❌ Something went wrong. Your account was not deleted. Please contact support.')
        return redirect('my_account')

    request.session.flush()
    logout(request)
    messages.success(request, '✅ Your account and personal data have been deleted.')
    return redirect('shop_home')


# ============================================
# VENDOR
# ============================================

def vendor_has_active_orders(vendor):
    """Store ke koi order abhi chal rahe hon to account delete nahi hota (web + vendor app dono)."""
    return SaleOrder.objects.filter(vendor=vendor, status__in=ACTIVE_ORDER_STATUSES).exists()


def wipe_vendor_account(user):
    """Vendor ka store + personal data saaf karo aur login band karo (web aur vendor app dono yahi use karte hain).

    Profile row rehti hai (settlement / commission reports uspar khade hain). Raise karta hai agar kuch bigre -
    caller transaction / message sambhalta hai. Vendor app ke push tokens bhi hat jate hain (delete ke baad alert nahi).
    """
    from ..models import Product, Vendor, VendorProfile, VendorPushToken

    profile = user.vendor_profile
    vendor = profile.vendor
    with transaction.atomic():
        # Hide the store and all its products.
        Product.objects.filter(vendor=vendor).update(is_active=False)

        _drop_file(profile.logo)
        _drop_file(profile.cover_image)
        VendorProfile.objects.filter(pk=profile.pk).update(
            business_name='Deleted Store', city='', store_description='',
            logo='', cover_image='', delivery_areas='',
            store_status='closed', is_approved=False,
        )
        Vendor.objects.filter(pk=vendor.pk).update(
            name='Deleted Vendor', contact_number=None, address=None,
        )
        VendorPushToken.objects.filter(profile=profile).delete()
        _close_login(user, 'vendor')


@vendor_login_required
@require_POST
def delete_account_vendor(request):
    user = request.user
    if not _password_ok(request, user):
        return redirect('vendor_dashboard')

    profile = user.vendor_profile
    vendor = profile.vendor

    if vendor_has_active_orders(vendor):
        messages.error(
            request,
            '⚠️ You still have open store orders. Please complete or reject them first, '
            'then delete your account.'
        )
        return redirect('vendor_dashboard')

    try:
        wipe_vendor_account(user)
    except Exception:
        logger.exception("Vendor account deletion failed")
        messages.error(request, '❌ Something went wrong. Your account was not deleted. Please contact support.')
        return redirect('vendor_dashboard')

    request.session.flush()
    logout(request)
    messages.success(request, '✅ Your vendor account and store data have been deleted.')
    return redirect('shop_home')


# ============================================
# RIDER
# ============================================

def _rider_login_required(view_func):
    """Same rules as the rider portal decorator, kept local to avoid a circular import."""
    from functools import wraps

    @wraps(view_func)
    def wrapper(request, *args, **kwargs):
        if not request.user.is_authenticated:
            messages.warning(request, '🔒 Please log in as a rider first')
            return redirect('rider_login')
        if getattr(request.user, 'rider_profile', None) is None:
            messages.error(request, '❌ This page is for riders only')
            return redirect('shop_home')
        return view_func(request, *args, **kwargs)
    return wrapper


@_rider_login_required
@require_POST
def delete_account_rider(request):
    user = request.user
    if not _password_ok(request, user):
        return redirect('rider_earnings')

    rider = user.rider_profile

    from ..models import DeliveryInfo, RiderProfile
    if DeliveryInfo.objects.filter(rider=rider, status__in=RIDER_ACTIVE_STATUSES).exists():
        messages.error(
            request,
            '⚠️ You still have an active delivery. Please finish it first, then delete your account.'
        )
        return redirect('rider_earnings')

    try:
        with transaction.atomic():
            # phone is unique, so give it a unique placeholder instead of blanking it.
            RiderProfile.objects.filter(pk=rider.pk).update(
                name='Deleted Rider', phone=f"deleted-{rider.pk}", vehicle='',
                is_active=False, is_online=False,
            )
            _close_login(user, 'rider')
    except Exception:
        logger.exception("Rider account deletion failed")
        messages.error(request, '❌ Something went wrong. Your account was not deleted. Please contact support.')
        return redirect('rider_earnings')

    request.session.flush()
    logout(request)
    messages.success(request, '✅ Your rider account has been deleted.')
    return redirect('rider_login')


# ============================================
# PUBLIC PAGES (no login)
# ============================================

def privacy_policy(request):
    return render(request, 'legal/privacy_policy.html', _legal_context(request, 'Privacy Policy'))


def delete_account_info(request):
    return render(request, 'legal/delete_account.html', _legal_context(request, 'Delete Your Account'))
