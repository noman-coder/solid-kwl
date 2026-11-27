"""
Customer Android app ke liye JSON API (token login).

Phase C1: foundation - register / login / logout / me, phone OTP (send / verify), forgot + reset password.
          Baqi saari customer API (home, stores, cart, orders...) isi file ke helpers par khadi hongi.
          Koi migration nahi (sirf maujooda tables: Customer, CustomerProfile, CustomerAddress, CustomerOTP).
Phase C2: push-token (FCM token register/refresh), logout aur password reset par push token hatna.
          Nayi table CustomerPushToken (migration 0065, sirf additive). Bhejne ka kaam app/customer_push.py ka hai.

Logic wahi hai jo web ka hai (views_customer_auth: customer_register / customer_login / send_order_otp /
verify_order_otp, views_password_reset + utils.password_reset), bas JSON mein. Farq sirf itna:
- API stateless hai (session nahi), is liye token Django signing se banta hai (salt 'customer-api-v1', 30 din).
  Customer ka password badalne par purane token khud band ho jate hain.
- OTP verify yahan order auto-place nahi karta (web karta hai). Verify hone par server 30 minute ka "order verified"
  nishan cache mein rakhta hai; checkout (Phase C8) `is_order_verified(profile)` se wahi check karega.

Header:  Authorization: Bearer <token>
Error format hamesha:  {ok: false, error: '...', message: '...', code: '...'}   (message == error)

Usool:
- Har API sirf us customer ka data de (profile.customer). Doosre customer ka order/address/chat kabhi nahi
  (`owned_order_or_404` / `owned_address_or_404` neeche hain, aglay phases inhi ko use karein).
- Login lockout: phone + IP par 5 ghalat koshish -> 10 minute. Band (is_active=False) account ko saaf message.
- Password/token/OTP logging mein kabhi nahi.
"""
import json
import logging
from functools import wraps

from django.conf import settings
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.core import signing
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.core.validators import validate_email
from django.db import IntegrityError, transaction
from django.http import JsonResponse
from django.shortcuts import get_object_or_404
from django.utils.timezone import now
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.gzip import gzip_page
from django.views.decorators.http import require_http_methods

from ..models import (Customer, CustomerAddress, CustomerOTP, CustomerProfile, CustomerPushToken,
                      SaleOrder)
from ..utils import password_reset as pr
from ..utils.password_policy import password_errors
from .views_customer_auth import get_client_ip, is_valid_phone, normalize_phone

logger = logging.getLogger(__name__)

TOKEN_SALT = 'customer-api-v1'
TOKEN_MAX_AGE = 30 * 24 * 3600

LOGIN_MAX_ATTEMPTS = 5            # web/vendor wali hi hadd
LOGIN_LOCK_SECONDS = 10 * 60
OTP_RESEND_SECONDS = 60           # OTP dobara mangwane se pehle intezar
OTP_VALID_SECONDS = 5 * 60        # CustomerOTP.generate_otp: 5 minute
ORDER_VERIFIED_SECONDS = 30 * 60  # OTP verify ke baad itni der tak order ke liye verified

BLOCKED_MSG = 'Aap ka account band hai. Support se rabta karein.'
BAD_LOGIN_MSG = 'Phone ya password ghalat hai'
GENERIC_RESET_MSG = ('Agar yeh phone registered hai to 6-digit code bhej diya gaya hai '
                     '(WhatsApp ya email par, 5 minute valid). Spam folder bhi dekh lein.')


# ---------------------------------------------------------------- helpers

def _data(request):
    """JSON body ya form dono chalte hain."""
    ctype = request.META.get('CONTENT_TYPE', '')
    if 'application/json' in ctype:
        try:
            d = json.loads(request.body.decode('utf-8') or '{}')
            return d if isinstance(d, dict) else {}
        except (ValueError, UnicodeDecodeError):
            return {}
    return request.POST


def _err(msg, status=400, code='error', **extra):
    out = {'ok': False, 'error': msg, 'message': msg, 'code': code}
    out.update(extra)
    return JsonResponse(out, status=status)


def _s(d, key, limit):
    """Body se text field: sirf string, strip, lambai ki hadd."""
    v = d.get(key)
    return v.strip()[:limit] if isinstance(v, str) else ''


def _make_token(profile):
    return signing.dumps({'cid': profile.pk, 'pv': (profile.user.password or '')[-12:]}, salt=TOKEN_SALT)


def _profile_from_request(request):
    """Bearer token se CustomerProfile; ghalat/expire/purana token, band account ya staff user ho to None."""
    auth = request.META.get('HTTP_AUTHORIZATION', '')
    if not auth.lower().startswith('bearer '):
        return None
    try:
        payload = signing.loads(auth[7:].strip(), salt=TOKEN_SALT, max_age=TOKEN_MAX_AGE)
    except signing.BadSignature:
        return None
    profile = (CustomerProfile.objects.select_related('user', 'customer')
               .filter(pk=payload.get('cid')).first())
    if not profile or not profile.user or not profile.user.is_active:
        return None
    if profile.user.is_staff or profile.user.is_superuser:
        return None
    if (profile.user.password or '')[-12:] != payload.get('pv'):
        return None          # password badal gaya -> purane token band
    return profile


def _rate_hit(key, limit, window):
    """Fixed-window counter (cache). True = hadd paar ho gayi. limit 0/None = band. Cache kharab ho to rokte nahi."""
    if not limit:
        return False
    try:
        cache.add(key, 0, window)
        try:
            n = cache.incr(key)
        except ValueError:
            cache.set(key, 1, window)
            n = 1
        return n > limit
    except Exception:
        logger.warning('customer api rate limit cache error', exc_info=True)
        return False


def _secure(resp):
    """Har API jawab: cache na ho (token wala data), browser type guess na kare."""
    resp['Cache-Control'] = 'no-store'
    resp['X-Content-Type-Options'] = 'nosniff'
    return resp


def _no_store(view):
    @wraps(view)
    def wrapper(*a, **kw):
        return _secure(view(*a, **kw))
    return wrapper


def customer_api(methods):
    """csrf_exempt + method check + token check + rate limit + gzip.

    View ko (request, profile, ...) milta hai; customer = profile.customer.
    Rate limit: ek customer ke liye `CUSTOMER_API_RATE_LIMIT` requests / `CUSTOMER_API_RATE_WINDOW` second
    (429 + `Retry-After`). Default band (settings mein lagayein; Phase C17 mein final value).
    """
    def deco(view):
        @csrf_exempt
        @require_http_methods(methods)
        @gzip_page
        @wraps(view)
        def wrapper(request, *args, **kwargs):
            profile = _profile_from_request(request)
            if profile is None:
                return _secure(_err('Dobara login karein', 401, code='auth'))
            window = int(getattr(settings, 'CUSTOMER_API_RATE_WINDOW', 60) or 60)
            if _rate_hit(f'customer_api_rl:{profile.pk}', getattr(settings, 'CUSTOMER_API_RATE_LIMIT', 0), window):
                resp = _err('Bohat zyada requests. Thori der ruk kar dobara try karein.', 429, code='rate_limited')
                resp['Retry-After'] = str(window)
                return _secure(resp)
            return _secure(view(request, profile, *args, **kwargs))
        return wrapper
    return deco


def customer_api_optional(methods):
    """Guest bhi chalta hai (Phase C4: Home / areas / stores browse bina login).

    View ko (request, profile, ...) milta hai; guest ho to profile = None.
    Token bheja gaya ho magar ghalat / expire ho to 401 (app customer ko guest bana kar dobara login ka kehti hai).
    Rate limit: login wale customer par customer ke hisab se, guest par IP ke hisab se.
    """
    def deco(view):
        @csrf_exempt
        @require_http_methods(methods)
        @gzip_page
        @wraps(view)
        def wrapper(request, *args, **kwargs):
            profile = None
            if request.META.get('HTTP_AUTHORIZATION', '').strip():
                profile = _profile_from_request(request)
                if profile is None:
                    return _secure(_err('Dobara login karein', 401, code='auth'))
            window = int(getattr(settings, 'CUSTOMER_API_RATE_WINDOW', 60) or 60)
            who = f'c{profile.pk}' if profile else f'ip{get_client_ip(request) or ""}'
            limit = getattr(settings, 'CUSTOMER_API_RATE_LIMIT', 0)
            if _rate_hit(f'customer_api_rl:{who}', limit, window):
                resp = _err('Bohat zyada requests. Thori der ruk kar dobara try karein.', 429, code='rate_limited')
                resp['Retry-After'] = str(window)
                return _secure(resp)
            return _secure(view(request, profile, *args, **kwargs))
        return wrapper
    return deco


def owned_order_or_404(profile, pk):
    """Sirf is customer ka order; doosre customer ka order -> Http404 (aglay phases yehi use karein)."""
    return get_object_or_404(SaleOrder, pk=pk, customer=profile.customer)


def owned_address_or_404(profile, pk):
    """Sirf is customer ka address; doosre ka -> Http404."""
    return get_object_or_404(CustomerAddress, pk=pk, customer=profile.customer)


def _login_key(phone, ip):
    return f'customer_login_fail:{phone}:{ip}'


def _media_url(f):
    try:
        return f.url if f else None
    except ValueError:
        return None


def _customer_json(profile):
    c = profile.customer
    addr = (CustomerAddress.objects.filter(customer=c, is_default=True).first()
            or CustomerAddress.objects.filter(customer=c).first())
    return {
        'id': c.pk,
        'code': c.customer_code or '',
        'name': c.name,
        'phone': c.contact_number or '',
        'email': c.email or '',
        'phone_verified': bool(profile.phone_verified),
        'email_verified': bool(profile.email_verified),
        'trusted': bool(profile.should_skip_order_otp()),
        'language': profile.preferred_language or 'en',
        'photo': _media_url(profile.profile_pic),
        'city': addr.city if addr else '',
        'address': addr.address_line_1 if addr else '',
        'member_since': profile.created_at.strftime('%Y-%m-%d') if profile.created_at else '',
    }


# ---- order OTP ka "verified" nishan (checkout, Phase C8, yahin se check karega)

def order_otp_required(profile):
    """Order ke liye OTP chahiye? (web wala hi rule: trusted customer ko nahi)"""
    return not profile.should_skip_order_otp()


def is_order_verified(profile):
    """OTP verify ho chuka hai (30 minute ke andar) ya customer trusted hai."""
    if not order_otp_required(profile):
        return True
    return bool(cache.get(f'customer_order_ok:{profile.pk}'))


def _mark_order_verified(profile):
    cache.set(f'customer_order_ok:{profile.pk}', 1, ORDER_VERIFIED_SECONDS)


def _mask_email(email):
    if '@' not in email:
        return email
    name, domain = email.split('@', 1)
    return f'{name[:2]}***@{domain}'


# ---------------------------------------------------------------- endpoints

@csrf_exempt
@require_http_methods(['POST'])
@_no_store
def api_register(request):
    """Naya customer account (web `customer_register` wali validation). Kamyabi par token seedha milta hai."""
    d = _data(request)
    ip = get_client_ip(request) or ''
    if _rate_hit(f'customer_register_ip:{ip}', getattr(settings, 'CUSTOMER_REGISTER_IP_LIMIT', 20), 3600):
        return _err('Bohat zyada koshishen. Thori der baad dobara try karein.', 429, code='rate_limited')

    accept = d.get('accept_privacy')
    if accept not in (True, 'true', 'True', '1', 1, 'on'):
        return _err('Account banane ke liye Privacy Policy qabool karein.', code='privacy')
    full_name = _s(d, 'full_name', 100) or _s(d, 'name', 100)
    phone_raw = _s(d, 'phone', 20)
    email = _s(d, 'email', 100)
    city = _s(d, 'city', 100)
    address = _s(d, 'address', 500)
    password = d.get('password') if isinstance(d.get('password'), str) else ''
    confirm = d.get('confirm_password')

    if len(full_name) < 3:
        return _err('Poora naam likhein', code='name')
    if not phone_raw or not is_valid_phone(phone_raw):
        return _err('Sahi phone number likhein (03XXXXXXXXX)', code='phone')
    if not email:
        return _err('Email zaroori hai (OTP ke liye)', code='email')
    try:
        validate_email(email)
    except ValidationError:
        return _err('Sahi email likhein', code='email')
    if not city:
        return _err('Shehar likhein', code='city')
    if len(address) < 10:
        return _err('Poora address likhein', code='address')
    if confirm is not None and confirm != password:
        return _err('Dono password aik jaise likhein', code='password')

    phone = normalize_phone(phone_raw)
    errors = password_errors(password, (full_name, phone, email))
    if errors:
        return _err(errors[0], code='password')
    if Customer.objects.filter(contact_number=phone).exists():
        return _err('Yeh phone pehle se registered hai. Login karein.', 409, code='phone_exists')
    if User.objects.filter(email__iexact=email).exists():
        return _err('Yeh email pehle se registered hai.', 409, code='email_exists')

    try:
        with transaction.atomic():
            base = phone.replace('+', '').replace(' ', '')
            username, n = base, 1
            while User.objects.filter(username=username).exists():
                username, n = f'{base}_{n}', n + 1
            parts = full_name.split()
            user = User.objects.create_user(
                username=username, email=email, password=password,
                first_name=parts[0], last_name=' '.join(parts[1:]))
            customer = Customer.objects.create(
                name=full_name, contact_number=phone, email=email,
                address=f'{address}, {city}', customer_code=f'CUS-{user.id:05d}')
            profile = CustomerProfile.objects.create(
                customer=customer, user=user, phone_verified=False, email_verified=True, last_login_at=now())
            CustomerAddress.objects.create(
                customer=customer, address_type='home', full_name=full_name, phone=phone,
                address_line_1=address, city=city, is_default=True)
    except IntegrityError:
        logger.warning('customer api register integrity error', exc_info=True)
        return _err('Yeh phone ya email pehle se registered hai.', 409, code='phone_exists')

    profile = CustomerProfile.objects.select_related('user', 'customer').get(pk=profile.pk)
    return JsonResponse({'ok': True, 'token': _make_token(profile), 'customer': _customer_json(profile),
                         'message': f'Khush aamdeed {customer.name}!'}, status=201)


@csrf_exempt
@require_http_methods(['POST'])
@_no_store
def api_login(request):
    d = _data(request)
    phone_raw = _s(d, 'phone', 20)
    password = d.get('password') or ''
    if not phone_raw or not password or not isinstance(password, str):
        return _err('Phone aur password dono likhein')
    if not is_valid_phone(phone_raw):
        return _err('Sahi phone number likhein (03XXXXXXXXX)', code='phone')

    ip = get_client_ip(request) or ''
    if _rate_hit(f'customer_login_ip:{ip}', getattr(settings, 'CUSTOMER_LOGIN_IP_LIMIT', 60),
                 int(getattr(settings, 'CUSTOMER_LOGIN_IP_WINDOW', 300) or 300)):
        return _err('Bohat zyada koshishen. Thori der baad dobara try karein.', 429, code='locked')
    phone = normalize_phone(phone_raw)
    key = _login_key(phone, ip)
    if cache.get(key, 0) >= LOGIN_MAX_ATTEMPTS:
        return _err('Bohat zyada koshishen. 10 minute baad dobara try karein.', 429, code='locked')

    profile = (CustomerProfile.objects.select_related('user', 'customer')
               .filter(customer__contact_number=phone).first())
    user = profile.user if profile else None
    if user and (user.is_staff or user.is_superuser):
        user = None                                   # admin account is raste se kabhi nahi
    authed = authenticate(request, username=user.username, password=password) if user else None
    if not authed:
        if user and not user.is_active and user.check_password(password):
            return _err(BLOCKED_MSG, 403, code='blocked')   # sahi password, account band: koshish gini nahi jati
        cache.set(key, cache.get(key, 0) + 1, LOGIN_LOCK_SECONDS)
        return _err(BAD_LOGIN_MSG, 401, code='bad_login')

    cache.delete(key)
    profile.last_login_at = now()
    profile.save(update_fields=['last_login_at'])
    return JsonResponse({'ok': True, 'token': _make_token(profile), 'customer': _customer_json(profile)})


@customer_api(['POST'])
def api_logout(request, profile):
    """Token stateless hai (app apna token mita deti hai). Is phone ka push token server se bhi hat jata hai,
    taake logout ke baad is phone par customer ke alert na aayein.

    Body (optional): {push_token}  (ya {token}). Sirf is customer ka apna token hatta hai.
    """
    d = _data(request)
    tok = _s(d, 'push_token', 255) or _s(d, 'token', 255)
    if tok:
        CustomerPushToken.objects.filter(customer=profile.customer, token=tok).delete()
    return JsonResponse({'ok': True})


MAX_PUSH_TOKENS = 5     # ek customer ke zyada se zyada itne phone


@customer_api(['POST'])
def api_push_token(request, profile):
    """App apna FCM token yahan register karti hai (login ke baad aur token badalne par).

    Body: {token, platform?, device?}. Token ek hi customer ka hota hai: kisi aur customer ne isi phone par
    login kiya to token naye customer ka ho jata hai (purane customer ko is phone par alert nahi jayega).
    Dobara bhejne par sirf `updated_at` taza hota hai (naya row nahi). Ek customer ke 5 se zyada phone nahi:
    sab se purane tokens khud hat jate hain.
    """
    d = _data(request)
    token = _s(d, 'token', 255)
    raw = d.get('token')
    if not isinstance(raw, str) or raw.strip() != token or not (20 <= len(token) <= 255) \
            or any(c.isspace() for c in token):
        return _err('Push token ghalat hai.', code='bad_token')
    platform = _s(d, 'platform', 20) or 'android'
    defaults = {'customer': profile.customer, 'platform': platform}
    device = _s(d, 'device', 100)
    if device:
        defaults['device'] = device
    customer = profile.customer
    with transaction.atomic():
        CustomerPushToken.objects.update_or_create(token=token, defaults=defaults)
        keep = list(CustomerPushToken.objects.filter(customer=customer).order_by('-updated_at', '-pk')
                    .values_list('pk', flat=True)[:MAX_PUSH_TOKENS])
        CustomerPushToken.objects.filter(customer=customer).exclude(pk__in=keep).delete()
    return JsonResponse({'ok': True})


@customer_api(['GET'])
def api_me(request, profile):
    return JsonResponse({'ok': True, 'customer': _customer_json(profile),
                         'order_otp_required': order_otp_required(profile),
                         'order_verified': is_order_verified(profile)})


@customer_api(['POST'])
def api_otp_send(request, profile):
    """Order verification OTP (web `send_order_otp` jaisa): email par jata hai. Trusted customer ko zaroorat nahi."""
    customer = profile.customer
    phone = customer.contact_number
    if not phone:
        return _err('Phone number nahi mila', code='no_phone')
    if not customer.email:
        return _err('Pehle apne account mein email add karein.', code='email_required', requires_email=True)
    if not order_otp_required(profile):
        return JsonResponse({'ok': True, 'skip_otp': True, 'message': 'Aap ko OTP ki zaroorat nahi.'})

    if not cache.add(f'customer_otp_cd:{profile.pk}', 1, OTP_RESEND_SECONDS):
        return _err(f'{OTP_RESEND_SECONDS} second baad dobara mangwayein.', 429, code='wait',
                    resend_after=OTP_RESEND_SECONDS)
    try:
        otp = CustomerOTP.generate_otp(
            phone=phone, purpose='order', customer_name=customer.name, customer_email=customer.email,
            ip_address=get_client_ip(request), user_agent=request.META.get('HTTP_USER_AGENT', '')[:500])
    except Exception as exc:          # 15 minute mein 3 se zyada request (model ki hadd) ya email ka masla
        cache.delete(f'customer_otp_cd:{profile.pk}')
        logger.warning('customer api otp not sent (customer %s): %s', customer.pk, exc)
        return _err('Bohat zyada OTP request. 15 minute baad dobara try karein.', 429, code='otp_limit')

    out = {'ok': True, 'skip_otp': False, 'email': _mask_email(customer.email),
           'expires_in': OTP_VALID_SECONDS, 'resend_after': OTP_RESEND_SECONDS}
    if otp.is_sent_to_customer:
        out['message'] = f"OTP {out['email']} par bhej diya gaya hai."
        out['email_sent'] = True
    else:
        out['message'] = 'OTP ban gaya magar email nahi gayi. Support se rabta karein.'
        out['email_sent'] = False
    return JsonResponse(out)


@customer_api(['POST'])
def api_otp_verify(request, profile):
    """OTP code check (web `verify_order_otp` ka logic: CustomerOTP.find_and_verify). Order auto-place nahi hota."""
    d = _data(request)
    code = _s(d, 'code', 6) or _s(d, 'otp_code', 6)
    if not (code.isdigit() and len(code) == 6):
        return _err('6-digit OTP likhein', code='bad_code')
    phone = profile.customer.contact_number
    if not phone:
        return _err('Phone number nahi mila', code='no_phone')
    if _rate_hit(f'customer_otp_ver:{profile.pk}', 20, 3600):
        return _err('Bohat zyada koshishen. Thori der baad dobara try karein.', 429, code='rate_limited')

    ok, _otp, msg = CustomerOTP.find_and_verify(phone=phone, code=code, purpose='order')
    if not ok:
        return _err(msg, 400, code='bad_code')
    if not profile.phone_verified:
        profile.phone_verified = True
        profile.save(update_fields=['phone_verified'])
    _mark_order_verified(profile)
    return JsonResponse({'ok': True, 'verified': True, 'valid_minutes': ORDER_VERIFIED_SECONDS // 60,
                         'customer': _customer_json(profile)})


@csrf_exempt
@require_http_methods(['POST'])
@_no_store
def api_forgot_password(request):
    """Step 1: phone -> code (WhatsApp/email). Jawab hamesha ek jaisa (phone registered ho ya na ho)."""
    d = _data(request)
    phone_raw = _s(d, 'phone', 20)
    if not phone_raw or not is_valid_phone(phone_raw):
        return _err('Sahi phone number likhein (03XXXXXXXXX)', code='phone')
    phone = normalize_phone(phone_raw)
    ip = get_client_ip(request) or ''
    if pr.too_many('fp_req_ip', ip, pr.REQ_PER_IP):
        return _err('Bohat zyada koshishen. Thori der baad dobara try karein.', 429, code='rate_limited')
    pr.bump(f'fp_req_ip:{ip}')

    account = pr.find_account(phone, ('customer',))      # sirf customer account (vendor ka number nahi)
    if account:
        pr.request_code(account, ip, request.META.get('HTTP_USER_AGENT', ''))
    return JsonResponse({'ok': True, 'message': GENERIC_RESET_MSG, 'resend_after': OTP_RESEND_SECONDS})


@csrf_exempt
@require_http_methods(['POST'])
@_no_store
def api_reset_password(request):
    """Step 2: phone + 6-digit code + naya password. Kamyabi par purane saare token band."""
    d = _data(request)
    phone_raw = _s(d, 'phone', 20)
    if not phone_raw or not is_valid_phone(phone_raw):
        return _err('Sahi phone number likhein (03XXXXXXXXX)', code='phone')
    phone = normalize_phone(phone_raw)
    ip = get_client_ip(request) or ''
    if pr.too_many('fp_ver_ip', ip, pr.VERIFY_PER_IP):
        return _err('Bohat zyada koshishen. Thori der baad dobara try karein.', 429, code='rate_limited')
    pr.bump(f'fp_ver_ip:{ip}')

    password = d.get('password') if isinstance(d.get('password'), str) else ''
    confirm = d.get('confirm_password')
    confirm = confirm if isinstance(confirm, str) else password
    account = pr.find_account(phone, ('customer',))
    if not account:
        return _err('Code ghalat ya expire ho chuka hai.', 400, code='bad_code')
    ok, msg = pr.complete_reset(account, _s(d, 'code', 6), password, confirm, ip)
    if not ok:
        return _err(msg, 400, code='bad_code')
    try:        # purane token band hue: un phones par push bhi band (app dobara login par naya token degi)
        CustomerPushToken.objects.filter(customer__portal_profile__user=account.user).delete()
    except Exception:
        logger.warning('customer api reset: push token cleanup failed', exc_info=True)
    return JsonResponse({'ok': True, 'message': msg})
