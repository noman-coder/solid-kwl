"""
Phase C1 tests: customer API foundation (register / login / logout / me, OTP, forgot + reset password,
token, lockout, ownership).

Run:  python manage.py test app.tests_customer_api -v 2

Cache locmem aur email locmem backend par override hain (Redis/SMTP ki zaroorat nahi).
"""
import json

from django.contrib.auth.models import User
from django.core import mail
from django.core.cache import cache
from django.http import Http404, JsonResponse
from django.test import RequestFactory, TestCase, override_settings
from django.urls import reverse

from app.customer import views_customer_api as api
from app.models import (Customer, CustomerAddress, CustomerOTP, CustomerProfile, SaleOrder, Vendor, VendorProfile,
                        Warehouse)
from app.customer.views_customer_auth import normalize_phone

LOCMEM = {'default': {'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'}}
MAIL = 'django.core.mail.backends.locmem.EmailBackend'
NO_WA = dict(WHATSAPP_PHONE_NUMBER_ID='', WHATSAPP_ACCESS_TOKEN='', WHATSAPP_OTP_TEMPLATE='')
PHONE_A, PHONE_B = '03001111111', '03002222222'
PASSWORD = 'Secret-pass-12'
NEW_PW = 'Br4nd-New-Pass#42'


def make_customer(name, phone, email=None, active=True, trusted=False):
    p = normalize_phone(phone)
    user = User.objects.create_user(f'u_{phone}', email or f'{phone}@x.com', PASSWORD, is_active=active)
    cust = Customer.objects.create(name=name, contact_number=p, email=email or f'{phone}@x.com', address='Lahore')
    profile = CustomerProfile.objects.create(customer=cust, user=user, is_trusted=trusted)
    CustomerAddress.objects.create(customer=cust, full_name=name, phone=p, address_line_1='House 1, Gulberg',
                                   city='Lahore', is_default=True)
    return profile


def reg_body(**over):
    d = {'full_name': 'Hadi Ahmad', 'phone': '03005556666', 'email': 'hadi@example.com', 'city': 'Khanewal',
         'address': 'Street 4, Model Town', 'password': PASSWORD, 'confirm_password': PASSWORD,
         'accept_privacy': True}
    d.update(over)
    return d


@override_settings(CACHES=LOCMEM, EMAIL_BACKEND=MAIL, **NO_WA)
class CustomerApiBase(TestCase):
    def setUp(self):
        cache.clear()
        self.a = make_customer('Ali', PHONE_A)
        self.b = make_customer('Bilal', PHONE_B)

    def post(self, name, body, **extra):
        return self.client.post(reverse(name), json.dumps(body), content_type='application/json', **extra)

    def login(self, phone=PHONE_A, password=PASSWORD):
        return self.post('customer_api_login', {'phone': phone, 'password': password})

    def bearer(self, profile):
        return {'HTTP_AUTHORIZATION': 'Bearer ' + api._make_token(profile)}


class RegisterTests(CustomerApiBase):
    def test_register_ok_returns_token_and_creates_rows(self):
        r = self.post('customer_api_register', reg_body())
        self.assertEqual(r.status_code, 201)
        d = r.json()
        self.assertTrue(d['ok'] and d['token'])
        self.assertEqual(d['customer']['phone'], '+923005556666')
        self.assertFalse(d['customer']['phone_verified'])
        cust = Customer.objects.get(contact_number='+923005556666')
        self.assertTrue(hasattr(cust, 'portal_profile'))
        self.assertTrue(CustomerAddress.objects.filter(customer=cust, is_default=True).exists())
        # token se seedha me
        me = self.client.get(reverse('customer_api_me'), HTTP_AUTHORIZATION='Bearer ' + d['token'])
        self.assertEqual(me.status_code, 200)

    def test_register_then_login(self):
        self.post('customer_api_register', reg_body())
        self.assertEqual(self.login('03005556666').status_code, 200)

    def test_privacy_required(self):
        r = self.post('customer_api_register', reg_body(accept_privacy=False))
        self.assertEqual((r.status_code, r.json()['code']), (400, 'privacy'))

    def test_validation_errors(self):
        for over, code in [({'full_name': 'Al'}, 'name'), ({'phone': '123'}, 'phone'), ({'email': 'bad'}, 'email'),
                           ({'email': ''}, 'email'), ({'city': ''}, 'city'), ({'address': 'short'}, 'address'),
                           ({'password': 'abc', 'confirm_password': 'abc'}, 'password'),
                           ({'confirm_password': 'Other-pass-12'}, 'password')]:
            r = self.post('customer_api_register', reg_body(**over))
            self.assertEqual(r.status_code, 400, over)
            self.assertEqual(r.json()['code'], code, over)
            self.assertFalse(r.json()['ok'])

    def test_duplicate_phone_and_email(self):
        r = self.post('customer_api_register', reg_body(phone=PHONE_A))
        self.assertEqual((r.status_code, r.json()['code']), (409, 'phone_exists'))
        r = self.post('customer_api_register', reg_body(email=self.a.customer.email))
        self.assertEqual((r.status_code, r.json()['code']), (409, 'email_exists'))

    def test_vendor_phone_does_not_block_nor_leak(self):
        # vendor ka number customer register mein chal jata hai (web jaisa), lekin vendor account chhua nahi jata
        v = Vendor.objects.create(name='S', contact_number=normalize_phone('03007778888'))
        VendorProfile.objects.create(vendor=v, user=User.objects.create_user('vv', 'v@x.com', PASSWORD),
                                     business_name='S')
        r = self.post('customer_api_register', reg_body(phone='03007778888', email='new@example.com'))
        self.assertEqual(r.status_code, 201)


class LoginTests(CustomerApiBase):
    def test_login_ok_returns_token_and_customer(self):
        r = self.login()
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'] and d['token'])
        self.assertEqual(d['customer']['name'], 'Ali')
        for k in ('phone', 'email', 'phone_verified', 'trusted', 'city', 'address', 'code'):
            self.assertIn(k, d['customer'])
        self.a.refresh_from_db()
        self.assertIsNotNone(self.a.last_login_at)

    def test_login_works_with_phone_formats(self):
        for ph in ('03001111111', '+923001111111', '923001111111', '0300 1111111'):
            cache.clear()
            self.assertEqual(self.login(phone=ph).status_code, 200, ph)

    def test_login_form_post_also_works(self):
        r = self.client.post(reverse('customer_api_login'), {'phone': PHONE_A, 'password': PASSWORD})
        self.assertEqual(r.status_code, 200)

    def test_wrong_password_error_format(self):
        r = self.login(password='nope')
        self.assertEqual(r.status_code, 401)
        d = r.json()
        self.assertFalse(d['ok'])
        self.assertEqual(d['code'], 'bad_login')
        self.assertEqual(d['error'], d['message'])

    def test_unknown_phone_same_error_as_wrong_password(self):
        r = self.login(phone='03009990000')
        self.assertEqual((r.status_code, r.json()['code']), (401, 'bad_login'))

    def test_missing_fields_and_bad_phone(self):
        self.assertEqual(self.post('customer_api_login', {'phone': PHONE_A}).status_code, 400)
        self.assertEqual(self.post('customer_api_login', {'phone': '12', 'password': 'x'}).json()['code'], 'phone')

    def test_five_wrong_passwords_lock_even_correct_password(self):
        for _ in range(5):
            self.assertEqual(self.login(password='wrong').status_code, 401)
        r = self.login()                      # sahi password bhi ab lock
        self.assertEqual((r.status_code, r.json()['code']), (429, 'locked'))
        self.assertIn('10 minute', r.json()['message'])

    def test_lock_is_per_phone(self):
        for _ in range(5):
            self.login(password='wrong')
        self.assertEqual(self.login(PHONE_B).status_code, 200)

    def test_successful_login_resets_counter(self):
        for _ in range(4):
            self.login(password='wrong')
        self.assertEqual(self.login().status_code, 200)
        for _ in range(4):
            self.login(password='wrong')
        self.assertEqual(self.login().status_code, 200)

    def test_blocked_account_gets_clear_message_not_lock(self):
        self.a.user.is_active = False
        self.a.user.save()
        r = self.login()
        self.assertEqual((r.status_code, r.json()['code']), (403, 'blocked'))
        for _ in range(7):                    # sahi password par baar baar: lock nahi lagta
            self.assertEqual(self.login().json()['code'], 'blocked')

    def test_staff_account_cannot_login(self):
        self.a.user.is_staff = True
        self.a.user.save()
        self.assertEqual(self.login().status_code, 401)

    def test_get_not_allowed(self):
        self.assertEqual(self.client.get(reverse('customer_api_login')).status_code, 405)


class TokenTests(CustomerApiBase):
    def test_me_needs_token(self):
        for h in ({}, {'HTTP_AUTHORIZATION': 'Bearer junk'}, {'HTTP_AUTHORIZATION': 'Token abc'}):
            r = self.client.get(reverse('customer_api_me'), **h)
            self.assertEqual((r.status_code, r.json()['code']), (401, 'auth'))

    def test_me_returns_own_data_only(self):
        d = self.client.get(reverse('customer_api_me'), **self.bearer(self.a)).json()
        self.assertEqual(d['customer']['name'], 'Ali')
        d = self.client.get(reverse('customer_api_me'), **self.bearer(self.b)).json()
        self.assertEqual(d['customer']['name'], 'Bilal')
        self.assertTrue(d['order_otp_required'])
        self.assertFalse(d['order_verified'])

    def test_password_change_kills_old_token(self):
        h = self.bearer(self.a)
        self.assertEqual(self.client.get(reverse('customer_api_me'), **h).status_code, 200)
        self.a.user.set_password('Another-Pass-99')
        self.a.user.save()
        self.assertEqual(self.client.get(reverse('customer_api_me'), **h).status_code, 401)

    def test_token_from_other_api_is_rejected(self):
        from django.core import signing
        bad = signing.dumps({'cid': self.a.pk, 'pv': self.a.user.password[-12:]}, salt='vendor-api-v1')
        r = self.client.get(reverse('customer_api_me'), HTTP_AUTHORIZATION='Bearer ' + bad)
        self.assertEqual(r.status_code, 401)

    def test_expired_token_rejected(self):
        from django.core import signing
        h = self.bearer(self.a)
        tok = h['HTTP_AUTHORIZATION'][7:]
        orig = api.TOKEN_MAX_AGE
        try:
            api.TOKEN_MAX_AGE = -1
            self.assertEqual(self.client.get(reverse('customer_api_me'), **h).status_code, 401)
        finally:
            api.TOKEN_MAX_AGE = orig
        self.assertTrue(signing.loads(tok, salt=api.TOKEN_SALT, max_age=orig))

    def test_blocked_or_staff_user_token_rejected(self):
        h = self.bearer(self.a)
        self.a.user.is_active = False
        self.a.user.save()
        self.assertEqual(self.client.get(reverse('customer_api_me'), **h).status_code, 401)
        self.a.user.is_active, self.a.user.is_staff = True, True
        self.a.user.save()
        self.assertEqual(self.client.get(reverse('customer_api_me'), **h).status_code, 401)

    def test_logout_ok(self):
        r = self.client.post(reverse('customer_api_logout'), **self.bearer(self.a))
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['ok'])

    def test_security_headers(self):
        r = self.client.get(reverse('customer_api_me'), **self.bearer(self.a))
        self.assertEqual(r['Cache-Control'], 'no-store')
        self.assertEqual(r['X-Content-Type-Options'], 'nosniff')

    @override_settings(CUSTOMER_API_RATE_LIMIT=2, CUSTOMER_API_RATE_WINDOW=60)
    def test_rate_limit_per_customer(self):
        h = self.bearer(self.a)
        self.assertEqual(self.client.get(reverse('customer_api_me'), **h).status_code, 200)
        self.assertEqual(self.client.get(reverse('customer_api_me'), **h).status_code, 200)
        r = self.client.get(reverse('customer_api_me'), **h)
        self.assertEqual((r.status_code, r.json()['code']), (429, 'rate_limited'))
        self.assertEqual(self.client.get(reverse('customer_api_me'), **self.bearer(self.b)).status_code, 200)


class OwnershipTests(CustomerApiBase):
    def setUp(self):
        super().setUp()
        self.rf = RequestFactory()
        self.wh = Warehouse.objects.create(name='Main')
        self.order_a = SaleOrder.objects.create(customer=self.a.customer, warehouse=self.wh, status='pending',
                                                order_no='A0001')
        self.order_b = SaleOrder.objects.create(customer=self.b.customer, warehouse=self.wh, status='pending',
                                                order_no='B0001')

    def test_owned_order_helper(self):
        self.assertEqual(api.owned_order_or_404(self.a, self.order_a.pk).pk, self.order_a.pk)
        with self.assertRaises(Http404):
            api.owned_order_or_404(self.a, self.order_b.pk)       # customer A ka token B ka order nahi khol sakta

    def test_owned_address_helper(self):
        addr_b = CustomerAddress.objects.filter(customer=self.b.customer).first()
        with self.assertRaises(Http404):
            api.owned_address_or_404(self.a, addr_b.pk)

    def test_decorator_gives_view_the_right_profile(self):
        @api.customer_api(['GET'])
        def view(request, profile):
            return JsonResponse({'ok': True, 'customer': profile.customer_id})
        req = self.rf.get('/x/', **self.bearer(self.b))
        self.assertEqual(json.loads(view(req).content)['customer'], self.b.customer_id)
        self.assertEqual(view(self.rf.get('/x/')).status_code, 401)


class OtpTests(CustomerApiBase):
    def send(self, profile=None):
        return self.client.post(reverse('customer_api_otp_send'), **self.bearer(profile or self.a))

    def verify(self, code, profile=None):
        return self.post('customer_api_otp_verify', {'code': code}, **self.bearer(profile or self.a))

    def test_requires_login(self):
        self.assertEqual(self.client.post(reverse('customer_api_otp_send')).status_code, 401)
        self.assertEqual(self.post('customer_api_otp_verify', {'code': '123456'}).status_code, 401)

    def test_send_and_verify_flow(self):
        r = self.send()
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'] and not d['skip_otp'])
        self.assertEqual(d['expires_in'], 300)
        self.assertIn('***', d['email'])
        code = CustomerOTP.objects.filter(phone=self.a.customer.contact_number, purpose='order').latest('created_at').otp_code
        self.assertNotIn(code, json.dumps(d))
        v = self.verify(code)
        self.assertEqual(v.status_code, 200)
        self.assertTrue(v.json()['verified'])
        self.a.refresh_from_db()
        self.assertTrue(self.a.phone_verified)
        self.assertTrue(api.is_order_verified(self.a))
        me = self.client.get(reverse('customer_api_me'), **self.bearer(self.a)).json()
        self.assertTrue(me['order_verified'])
        self.assertFalse(api.is_order_verified(self.b))            # doosre customer par asar nahi

    def test_resend_cooldown(self):
        self.assertEqual(self.send().status_code, 200)
        r = self.send()
        self.assertEqual((r.status_code, r.json()['code']), (429, 'wait'))
        self.assertEqual(r.json()['resend_after'], 60)

    def test_wrong_code(self):
        self.send()
        r = self.verify('000000')
        self.assertEqual((r.status_code, r.json()['code']), (400, 'bad_code'))
        self.assertFalse(api.is_order_verified(self.a))
        self.assertEqual(self.verify('12').json()['code'], 'bad_code')
        self.assertEqual(self.verify('abcdef').json()['code'], 'bad_code')

    def test_code_cannot_be_reused(self):
        self.send()
        code = CustomerOTP.objects.filter(purpose='order').latest('created_at').otp_code
        self.assertEqual(self.verify(code).status_code, 200)
        self.assertEqual(self.verify(code).status_code, 400)

    def test_trusted_customer_skips_otp(self):
        t = make_customer('Trusted', '03004444444', trusted=True)
        r = self.send(t)
        self.assertTrue(r.json()['skip_otp'])
        self.assertTrue(api.is_order_verified(t))
        self.assertFalse(CustomerOTP.objects.filter(phone=t.customer.contact_number).exists())

    def test_email_required(self):
        self.a.customer.email = ''
        self.a.customer.save()
        r = self.send()
        self.assertEqual((r.status_code, r.json()['code']), (400, 'email_required'))

    def test_otp_for_one_customer_does_not_verify_other(self):
        self.send()
        code = CustomerOTP.objects.filter(phone=self.a.customer.contact_number).latest('created_at').otp_code
        r = self.verify(code, self.b)                  # B ke paas A ka code: B ka koi OTP hi nahi
        self.assertEqual(r.status_code, 400)
        self.assertFalse(api.is_order_verified(self.b))


class PasswordResetTests(CustomerApiBase):
    def forgot(self, phone):
        return self.post('customer_api_forgot_password', {'phone': phone})

    def reset(self, phone, code, password=NEW_PW, **extra):
        body = {'phone': phone, 'code': code, 'password': password, 'confirm_password': password}
        body.update(extra)
        return self.post('customer_api_reset_password', body)

    def code_for(self, phone):
        return CustomerOTP.objects.filter(phone=normalize_phone(phone),
                                          purpose='forgot_password').latest('created_at').otp_code

    def test_full_flow_and_old_token_dies(self):
        old = self.bearer(self.a)
        r = self.forgot(PHONE_A)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['ok'])
        r = self.reset(PHONE_A, self.code_for(PHONE_A))
        self.assertEqual(r.status_code, 200, r.content)
        self.a.user.refresh_from_db()
        self.assertTrue(self.a.user.check_password(NEW_PW))
        self.assertEqual(self.client.get(reverse('customer_api_me'), **old).status_code, 401)
        cache.clear()
        self.assertEqual(self.login(password=NEW_PW).status_code, 200)

    def test_same_answer_for_registered_and_unknown_phone(self):
        a = self.forgot(PHONE_A).json()
        b = self.forgot('03009990000').json()
        self.assertEqual(a['message'], b['message'])
        self.assertTrue(b['ok'])
        self.assertFalse(CustomerOTP.objects.filter(phone='+923009990000').exists())

    def test_wrong_code_does_not_change_password(self):
        self.forgot(PHONE_A)
        r = self.reset(PHONE_A, '000000')
        self.assertEqual((r.status_code, r.json()['code']), (400, 'bad_code'))
        self.a.user.refresh_from_db()
        self.assertTrue(self.a.user.check_password(PASSWORD))

    def test_weak_or_mismatched_password_rejected(self):
        self.forgot(PHONE_A)
        code = self.code_for(PHONE_A)
        self.assertEqual(self.reset(PHONE_A, code, 'abc').status_code, 400)
        self.assertEqual(self.reset(PHONE_A, code, NEW_PW, confirm_password='Different-1').status_code, 400)
        self.a.user.refresh_from_db()
        self.assertTrue(self.a.user.check_password(PASSWORD))

    def test_unknown_phone_reset_fails_generically(self):
        r = self.reset('03009990000', '123456')
        self.assertEqual((r.status_code, r.json()['code']), (400, 'bad_code'))

    def test_vendor_number_cannot_be_reset_through_customer_api(self):
        v = Vendor.objects.create(name='S', contact_number=normalize_phone('03007778888'))
        vu = User.objects.create_user('vv', 'v@x.com', PASSWORD)
        VendorProfile.objects.create(vendor=v, user=vu, business_name='S')
        self.forgot('03007778888')
        self.assertFalse(CustomerOTP.objects.filter(phone='+923007778888', purpose='forgot_password').exists())
        r = self.reset('03007778888', '123456')
        self.assertEqual(r.status_code, 400)
        vu.refresh_from_db()
        self.assertTrue(vu.check_password(PASSWORD))

    def test_bad_phone(self):
        self.assertEqual(self.forgot('12').json()['code'], 'phone')
        self.assertEqual(self.reset('12', '123456').json()['code'], 'phone')
