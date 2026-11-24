"""
Phase V1 tests: vendor API foundation (login / logout / me, token, lockout, approval, ownership).

Run:  python manage.py test app.tests_vendor_api
"""
import json

from django.contrib.auth.models import User
from django.core import signing
from django.core.cache import cache
from django.http import Http404, JsonResponse
from django.test import RequestFactory, TestCase
from django.urls import reverse

from app.customer import views_rider_api
from app.customer import views_vendor_api as api
from app.customer.views_customer_auth import normalize_phone
from app.customer.views_vendor_portal import _login_key
from app.models import Customer, SaleOrder, Vendor, VendorProfile, Warehouse

PHONE_A = '03001111111'
PHONE_B = '03002222222'
PASSWORD = 'secret12'


def make_vendor(name, phone, approved=True, username=None):
    # Vendor.contact_number web login ki tarah normalize hoke save hota hai (+92...)
    vendor = Vendor.objects.create(name=name, contact_number=normalize_phone(phone))
    user = User.objects.create_user(username or f'u_{phone}', f'{phone}@x.com', PASSWORD)
    profile = VendorProfile.objects.create(vendor=vendor, user=user, business_name=name, is_approved=approved)
    return profile


class VendorApiBase(TestCase):
    def setUp(self):
        self.a = make_vendor('Ali Store', PHONE_A)
        self.b = make_vendor('Bilal Store', PHONE_B)
        # cache file-based hai: purani lock keys saaf karein
        for ph in (PHONE_A, PHONE_B):
            for ip in ('', '127.0.0.1'):
                cache.delete(_login_key(normalize_phone(ph), ip))

    def login(self, phone=PHONE_A, password=PASSWORD):
        return self.client.post(reverse('vendor_api_login'), json.dumps({'phone': phone, 'password': password}),
                                content_type='application/json')

    def bearer(self, profile):
        return {'HTTP_AUTHORIZATION': 'Bearer ' + api._make_token(profile)}


class LoginTests(VendorApiBase):
    def test_login_ok_returns_token_and_store_info(self):
        r = self.login()
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'])
        self.assertTrue(d['token'])
        self.assertEqual(d['vendor']['name'], 'Ali Store')
        self.assertTrue(d['vendor']['approved'])
        for k in ('rating', 'rating_count', 'commission_percent', 'is_open', 'store_status'):
            self.assertIn(k, d['vendor'])
        self.a.refresh_from_db()
        self.assertIsNotNone(self.a.last_login_at)

    def test_login_works_with_phone_formats(self):
        for ph in ('03001111111', '+923001111111', '923001111111', '0300 1111111'):
            cache.delete(_login_key(normalize_phone(ph), ''))
            self.assertEqual(self.login(phone=ph).status_code, 200, ph)

    def test_login_form_post_also_works(self):
        r = self.client.post(reverse('vendor_api_login'), {'phone': PHONE_A, 'password': PASSWORD})
        self.assertEqual(r.status_code, 200)

    def test_wrong_password_error_format(self):
        r = self.login(password='nope')
        self.assertEqual(r.status_code, 401)
        d = r.json()
        self.assertFalse(d['ok'])
        self.assertTrue(d['error'])

    def test_missing_fields(self):
        r = self.client.post(reverse('vendor_api_login'), '{}', content_type='application/json')
        self.assertEqual(r.status_code, 400)
        self.assertFalse(r.json()['ok'])

    def test_unknown_phone_same_error_as_wrong_password(self):
        r = self.login(phone='03009999999')
        self.assertEqual(r.status_code, 401)
        self.assertEqual(r.json()['error'], self.login(password='nope').json()['error'])

    def test_five_wrong_passwords_lock(self):
        for _ in range(5):
            self.assertEqual(self.login(password='bad').status_code, 401)
        r = self.login(password='bad')
        self.assertEqual(r.status_code, 429)
        self.assertFalse(r.json()['ok'])
        # lock ke dauran sahi password bhi nahi chalta
        self.assertEqual(self.login().status_code, 429)

    def test_success_resets_failures(self):
        for _ in range(3):
            self.login(password='bad')
        self.assertEqual(self.login().status_code, 200)
        for _ in range(4):
            self.assertEqual(self.login(password='bad').status_code, 401)

    def test_unapproved_vendor_gets_clear_message_not_crash(self):
        c = make_vendor('Naya Store', '03003333333', approved=False)
        r = self.login(phone='03003333333')
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertFalse(d['vendor']['approved'])
        self.assertIn('approval', d['message'])
        me = self.client.get(reverse('vendor_api_me'), **self.bearer(c))
        self.assertEqual(me.status_code, 200)
        self.assertFalse(me.json()['vendor']['approved'])

    def test_staff_user_cannot_login_as_vendor(self):
        self.a.user.is_staff = True
        self.a.user.save()
        self.assertEqual(self.login().status_code, 401)

    def test_get_not_allowed(self):
        self.assertEqual(self.client.get(reverse('vendor_api_login')).status_code, 405)


class TokenTests(VendorApiBase):
    def test_me_with_token(self):
        token = self.login().json()['token']
        r = self.client.get(reverse('vendor_api_me'), HTTP_AUTHORIZATION='Bearer ' + token)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['vendor']['id'], self.a.vendor_id)
        self.assertEqual(r.json()['vendor']['name'], 'Ali Store')

    def test_no_or_bad_token_401(self):
        self.assertEqual(self.client.get(reverse('vendor_api_me')).status_code, 401)
        r = self.client.get(reverse('vendor_api_me'), HTTP_AUTHORIZATION='Bearer abc.def')
        self.assertEqual(r.status_code, 401)
        self.assertFalse(r.json()['ok'])
        self.assertEqual(r.json()['code'], 'auth')

    def test_old_token_dies_after_password_change(self):
        token = self.login().json()['token']
        h = {'HTTP_AUTHORIZATION': 'Bearer ' + token}
        self.assertEqual(self.client.get(reverse('vendor_api_me'), **h).status_code, 200)
        self.a.user.set_password('newpass99')
        self.a.user.save()
        self.assertEqual(self.client.get(reverse('vendor_api_me'), **h).status_code, 401)

    def test_expired_token_401(self):
        token = api._make_token(self.a)
        real_loads = signing.loads

        def expired(value, **kw):
            raise signing.SignatureExpired('old')
        signing.loads = expired
        try:
            r = self.client.get(reverse('vendor_api_me'), HTTP_AUTHORIZATION='Bearer ' + token)
        finally:
            signing.loads = real_loads
        self.assertEqual(r.status_code, 401)

    def test_rider_token_not_accepted(self):
        # rider ka token (salt rider-api-v1) vendor API par nahi chalna chahiye
        token = signing.dumps({'rid': 1, 'pv': 'x'}, salt=views_rider_api.TOKEN_SALT)
        r = self.client.get(reverse('vendor_api_me'), HTTP_AUTHORIZATION='Bearer ' + token)
        self.assertEqual(r.status_code, 401)

    def test_token_salt_is_vendor_api_v1(self):
        self.assertEqual(api.TOKEN_SALT, 'vendor-api-v1')
        payload = signing.loads(api._make_token(self.a), salt='vendor-api-v1')
        self.assertEqual(payload['vid'], self.a.pk)

    def test_token_of_deactivated_user_401(self):
        h = self.bearer(self.a)
        self.a.user.is_active = False
        self.a.user.save()
        self.assertEqual(self.client.get(reverse('vendor_api_me'), **h).status_code, 401)

    def test_logout_ok(self):
        r = self.client.post(reverse('vendor_api_logout'), **self.bearer(self.a))
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['ok'])
        self.assertEqual(self.client.post(reverse('vendor_api_logout')).status_code, 401)


class ApprovalAndOwnershipTests(VendorApiBase):
    """Aglay phases ke liye bunyadi hifazat: @vendor_api approval + owned_order_or_404."""

    def setUp(self):
        super().setUp()
        self.rf = RequestFactory()
        self.wh = Warehouse.objects.create(name='Main')
        self.cust = Customer.objects.create(name='Zara', contact_number='03003333333', address='Lahore')
        self.order_b = SaleOrder.objects.create(customer=self.cust, warehouse=self.wh, status='pending',
                                                vendor=self.b.vendor, order_no='B0001')
        self.order_a = SaleOrder.objects.create(customer=self.cust, warehouse=self.wh, status='pending',
                                                vendor=self.a.vendor, order_no='A0001')

    def _dummy(self):
        @api.vendor_api(['GET'])
        def view(request, profile):
            return JsonResponse({'ok': True, 'vendor': profile.vendor_id})
        return view

    def test_unapproved_vendor_blocked_on_protected_view(self):
        c = make_vendor('Naya Store', '03004444444', approved=False)
        req = self.rf.get('/x/', **self.bearer(c))
        r = self._dummy()(req)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(json.loads(r.content)['code'], 'pending')

    def test_approved_vendor_allowed_on_protected_view(self):
        r = self._dummy()(self.rf.get('/x/', **self.bearer(self.a)))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(json.loads(r.content)['vendor'], self.a.vendor_id)

    def test_protected_view_requires_token(self):
        self.assertEqual(self._dummy()(self.rf.get('/x/')).status_code, 401)

    def test_vendor_a_cannot_open_vendor_b_order(self):
        with self.assertRaises(Http404):
            api.owned_order_or_404(self.a, self.order_b.pk)
        with self.assertRaises(Http404):
            api.owned_order_or_404(self.b, self.order_a.pk)
        self.assertEqual(api.owned_order_or_404(self.a, self.order_a.pk), self.order_a)

    def test_each_token_sees_only_own_store(self):
        ra = self.client.get(reverse('vendor_api_me'), **self.bearer(self.a)).json()
        rb = self.client.get(reverse('vendor_api_me'), **self.bearer(self.b)).json()
        self.assertEqual(ra['vendor']['name'], 'Ali Store')
        self.assertEqual(rb['vendor']['name'], 'Bilal Store')
