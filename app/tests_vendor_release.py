"""
Phase V17 tests: rate limit, security headers, token/ownership audit, thumbnails, logging (koi secret nahi).

Run:  python manage.py test app.tests_vendor_release
"""
import json
import os
import re
import shutil
import tempfile
from pathlib import Path

from django.conf import settings
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import NoReverseMatch, get_resolver, reverse

from app.customer import views_vendor_api as api
from app.customer.thumbs import THUMB_SIZE, thumb_url
from app.tests_vendor_api import PASSWORD, PHONE_A, PHONE_B, VendorApiBase

LOCMEM = {'default': {'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'}}


@override_settings(CACHES=LOCMEM)
class RateLimitTests(VendorApiBase):
    def setUp(self):
        super().setUp()
        cache.clear()

    @override_settings(VENDOR_API_RATE_LIMIT=3, VENDOR_API_RATE_WINDOW=60)
    def test_limit_hit_returns_429_with_retry_after(self):
        url = reverse('vendor_api_me')
        for _ in range(3):
            self.assertEqual(self.client.get(url, **self.bearer(self.a)).status_code, 200)
        r = self.client.get(url, **self.bearer(self.a))
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()['code'], 'rate_limited')
        self.assertFalse(r.json()['ok'])
        self.assertEqual(r['Retry-After'], '60')

    @override_settings(VENDOR_API_RATE_LIMIT=3, VENDOR_API_RATE_WINDOW=60)
    def test_limit_is_per_vendor(self):
        url = reverse('vendor_api_me')
        for _ in range(4):
            self.client.get(url, **self.bearer(self.a))
        self.assertEqual(self.client.get(url, **self.bearer(self.a)).status_code, 429)
        self.assertEqual(self.client.get(url, **self.bearer(self.b)).status_code, 200)

    @override_settings(VENDOR_API_RATE_LIMIT=2, VENDOR_API_RATE_WINDOW=60)
    def test_bad_token_not_counted_and_still_401(self):
        url = reverse('vendor_api_me')
        for _ in range(5):
            self.assertEqual(self.client.get(url, HTTP_AUTHORIZATION='Bearer nonsense').status_code, 401)
        self.assertEqual(self.client.get(url, **self.bearer(self.a)).status_code, 200)

    @override_settings(VENDOR_API_RATE_LIMIT=0)
    def test_limit_zero_means_off(self):
        url = reverse('vendor_api_me')
        for _ in range(30):
            self.assertEqual(self.client.get(url, **self.bearer(self.a)).status_code, 200)

    @override_settings(VENDOR_LOGIN_IP_LIMIT=3, VENDOR_LOGIN_IP_WINDOW=300)
    def test_login_ip_limit(self):
        for ph in ('03007770001', '03007770002', '03007770003'):
            self.assertEqual(self.login(phone=ph).status_code, 401)       # phone alag alag: phone-lockout nahi, IP hadd
        r = self.login()
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()['code'], 'locked')


@override_settings(CACHES=LOCMEM)
class SecurityHeaderTests(VendorApiBase):
    def test_api_response_not_cacheable(self):
        r = self.client.get(reverse('vendor_api_me'), **self.bearer(self.a))
        self.assertEqual(r['Cache-Control'], 'no-store')
        self.assertEqual(r['X-Content-Type-Options'], 'nosniff')

    def test_login_response_not_cacheable(self):
        r = self.login()
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r['Cache-Control'], 'no-store')

    def test_401_not_cacheable(self):
        r = self.client.get(reverse('vendor_api_me'))
        self.assertEqual(r.status_code, 401)
        self.assertEqual(r['Cache-Control'], 'no-store')


def _vendor_api_urls():
    """urls.py ke sab `vendor_api_*` naam (login ke ilawa) aur unke reverse kwargs."""
    names = sorted({k for k in get_resolver().reverse_dict.keys() if isinstance(k, str) and k.startswith('vendor_api_')})
    out = []
    for name in names:
        if name == 'vendor_api_login':
            continue
        for kwargs in ({}, {'pk': 1}, {'pk': 1, 'action': 'accept'}, {'kind': 'category'}):
            try:
                out.append((name, reverse(name, kwargs=kwargs)))
                break
            except NoReverseMatch:
                continue
    return out


@override_settings(CACHES=LOCMEM)
class TokenAuditTests(VendorApiBase):
    def test_every_vendor_api_endpoint_needs_a_token(self):
        urls = _vendor_api_urls()
        self.assertGreater(len(urls), 30)          # poori list mili (kuch gum nahi hui)
        for name, url in urls:
            codes = {self.client.get(url).status_code, self.client.post(url, '{}', content_type='application/json').status_code}
            self.assertIn(401, codes, f'{name} bina token ke khula hai')
            self.assertFalse(codes - {401, 405}, f'{name} bina token ke {codes}')

    def test_tampered_token_rejected(self):
        tok = api._make_token(self.a)
        bad = tok[:-3] + ('abc' if not tok.endswith('abc') else 'xyz')
        r = self.client.get(reverse('vendor_api_me'), HTTP_AUTHORIZATION='Bearer ' + bad)
        self.assertEqual(r.status_code, 401)

    def test_expired_token_rejected(self):
        tok = api._make_token(self.a)
        orig = api.TOKEN_MAX_AGE
        api.TOKEN_MAX_AGE = -1
        try:
            r = self.client.get(reverse('vendor_api_me'), HTTP_AUTHORIZATION='Bearer ' + tok)
        finally:
            api.TOKEN_MAX_AGE = orig
        self.assertEqual(r.status_code, 401)
        self.assertEqual(r.json()['code'], 'auth')

    def test_other_vendor_order_is_404(self):
        from app.models import Customer, SaleOrder, Warehouse
        wh = Warehouse.objects.create(name='Main')
        cust = Customer.objects.create(name='Zara', contact_number='03003333333', address='Lahore')
        order = SaleOrder.objects.create(customer=cust, warehouse=wh, status='pending', vendor=self.b.vendor,
                                         payment_method='cod', order_no='REL0001')
        self.assertEqual(self.client.get(reverse('vendor_api_order_detail', args=[order.pk]), **self.bearer(self.a)).status_code, 404)
        self.assertEqual(self.client.get(reverse('vendor_api_order_track', args=[order.pk]), **self.bearer(self.a)).status_code, 404)
        r = self.client.post(reverse('vendor_api_order_action', args=[order.pk, 'accept']), '{}',
                             content_type='application/json', **self.bearer(self.a))
        self.assertEqual(r.status_code, 404)


class LoggingTests(TestCase):
    """Source scan: logger / print mein password ya token kabhi na jaye."""
    FILES = ['customer/views_vendor_api.py', 'vendor_push.py', 'vendor_push_signals.py', 'customer/thumbs.py']

    def test_no_secret_in_log_calls(self):
        base = Path(__file__).resolve().parent
        pat = re.compile(r'(logger\.\w+|print)\((.*)', re.I)
        for rel in self.FILES:
            for n, line in enumerate((base / rel).read_text(encoding='utf-8').splitlines(), 1):
                m = pat.search(line)
                if not m:
                    continue
                args = m.group(2)
                # message ke andar lafz theek hai (jaise 'Vendor push token ...'); variable/argument nahi hona chahiye
                self.assertNotRegex(args, r',\s*(password|token|push_token|request\.body|d\b)', f'{rel}:{n} secret log ho sakta hai')


class ThumbTests(TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _field(self, name='products/a.png', size=(800, 600), make=True):
        from PIL import Image
        path = os.path.join(self.tmp, *name.split('/'))
        if make:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            Image.new('RGBA', size, (200, 30, 30, 255)).save(path)

        class F:
            def __init__(s):
                s.name = name
                s.path = path
                s.url = '/media/' + name

            def __bool__(s):
                return True
        return F()

    def test_none_when_no_image(self):
        self.assertIsNone(thumb_url(None))
        self.assertIsNone(thumb_url(''))

    def test_thumb_created_small_and_cached(self):
        from PIL import Image
        with override_settings(MEDIA_ROOT=self.tmp, MEDIA_URL='/media/'):
            f = self._field()
            url = thumb_url(f)
            self.assertTrue(url.startswith('/media/thumbs/%d/' % THUMB_SIZE))
            dst = os.path.join(self.tmp, *url[len('/media/'):].split('/'))
            self.assertTrue(os.path.isfile(dst))
            with Image.open(dst) as im:
                self.assertEqual(im.format, 'JPEG')
                self.assertLessEqual(max(im.size), THUMB_SIZE)
            m1 = os.path.getmtime(dst)
            self.assertEqual(thumb_url(f), url)
            self.assertEqual(os.path.getmtime(dst), m1)              # dobara nahi bani
            # asli photo bachi hui
            self.assertTrue(os.path.isfile(f.path))

    def test_missing_file_falls_back_to_original(self):
        with override_settings(MEDIA_ROOT=self.tmp, MEDIA_URL='/media/'):
            f = self._field(make=False)
            self.assertEqual(thumb_url(f), '/media/products/a.png')

    def test_cloud_storage_falls_back_to_original(self):
        class Cloud:
            name = 'products/c.png'
            url = 'https://cdn.example.com/products/c.png'

            @property
            def path(self):
                raise NotImplementedError

            def __bool__(self):
                return True
        self.assertEqual(thumb_url(Cloud()), 'https://cdn.example.com/products/c.png')

    def test_corrupt_image_falls_back_to_original(self):
        with override_settings(MEDIA_ROOT=self.tmp, MEDIA_URL='/media/'):
            f = self._field(make=False)
            os.makedirs(os.path.dirname(f.path), exist_ok=True)
            Path(f.path).write_bytes(b'not an image')
            self.assertEqual(thumb_url(f), '/media/products/a.png')
