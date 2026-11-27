"""
Phase V13 tests: vendor coupons API (list, create, edit, toggle, delete, ownership, validation, checkout engine).

Run:  python manage.py test app.tests_vendor_coupons
Asli FCM ko koi call nahi jati (VendorPushBase push mock karta hai).
"""
import json
from datetime import timedelta
from decimal import Decimal

from django.urls import reverse
from django.utils import timezone

from app.customer import coupons as engine
from app.models import Coupon, CouponRedemption
from app.tests_vendor_push import VendorPushBase

D = Decimal


def cart_for(vendor_id):
    return {'1': {'product_id': 1, 'vendor_id': vendor_id, 'quantity': 1, 'price': 1000}}


class CouponBase(VendorPushBase):
    def make(self, profile=None, **kw):
        profile = profile or self.a
        data = dict(code='SAVE10', discount_type='percent', value=D('10'), vendor=profile.vendor)
        data.update(kw)
        return Coupon.objects.create(**data)

    def redeem(self, coupon, order_status='pending', amount='100'):
        order = self._order(status=order_status)
        return CouponRedemption.objects.create(
            coupon=coupon, customer=self.customer, sale_order=order,
            discount_amount=D(amount), funded_by='vendor')

    def list(self, profile=None):
        return self.client.get(reverse('vendor_api_coupons'), **self.bearer(profile or self.a))

    def create(self, body, profile=None):
        return self.client.post(reverse('vendor_api_coupons'), json.dumps(body), content_type='application/json',
                                **self.bearer(profile or self.a))

    def edit(self, pk, body, profile=None):
        return self.client.post(reverse('vendor_api_coupon_edit', args=[pk]), json.dumps(body),
                                content_type='application/json', **self.bearer(profile or self.a))

    def toggle(self, pk, body=None, profile=None):
        return self.client.post(reverse('vendor_api_coupon_toggle', args=[pk]), json.dumps(body or {}),
                                content_type='application/json', **self.bearer(profile or self.a))

    def delete(self, pk, profile=None):
        return self.client.post(reverse('vendor_api_coupon_delete', args=[pk]), '{}',
                                content_type='application/json', **self.bearer(profile or self.a))

    def good(self, **kw):
        body = {'code': 'welcome50', 'title': 'Pehle order par', 'discount_type': 'percent', 'value': 20,
                'max_discount': 150, 'min_order': 500, 'usage_limit': 100, 'per_customer_limit': 1,
                'first_order_only': True}
        body.update(kw)
        return body


class AuthTests(CouponBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_coupons')).status_code, 401)
        self.assertEqual(self.client.post(reverse('vendor_api_coupons'), '{}', content_type='application/json').status_code, 401)

    def test_unapproved_vendor_blocked(self):
        from app.tests_vendor_api import make_vendor
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.list(c).status_code, 403)
        self.assertEqual(self.create(self.good(), c).status_code, 403)
        self.assertEqual(Coupon.objects.count(), 0)


class ListTests(CouponBase):
    def test_only_own_coupons(self):
        mine = self.make(code='MINE')
        self.make(self.b, code='THEIRS')
        self.make(None, code='SHOPWIDE', vendor=None)       # poori shop ka (admin) coupon
        d = self.list().json()
        self.assertTrue(d['ok'])
        self.assertEqual([c['id'] for c in d['coupons']], [mine.pk])
        self.assertEqual(d['summary']['total'], 1)
        self.assertEqual(d['summary']['max'], 50)

    def test_json_fields_and_remaining(self):
        c = self.make(code='LIM', usage_limit=5, min_order=D('300'), max_discount=D('80'),
                      valid_until=timezone.now() + timedelta(days=3))
        self.redeem(c, amount='40')
        self.redeem(c, amount='60')
        row = self.list().json()['coupons'][0]
        for k in ('id', 'code', 'title', 'label', 'discount_type', 'value', 'max_discount', 'min_order', 'usage_limit',
                  'per_customer_limit', 'first_order_only', 'valid_from', 'valid_until', 'is_active', 'status', 'used',
                  'remaining', 'given', 'core_locked', 'share_text'):
            self.assertIn(k, row)
        self.assertEqual(row['used'], 2)
        self.assertEqual(row['remaining'], 3)
        self.assertEqual(row['given'], 100.0)
        self.assertTrue(row['core_locked'])
        self.assertEqual(row['status'], 'active')
        self.assertIn('LIM', row['share_text'])
        self.assertEqual(len(row['valid_until']), 10)           # YYYY-MM-DD

    def test_unlimited_has_no_remaining(self):
        self.make(code='FREE')
        row = self.list().json()['coupons'][0]
        self.assertIsNone(row['remaining'])
        self.assertIsNone(row['usage_limit'])
        self.assertFalse(row['core_locked'])

    def test_cancelled_order_not_counted(self):
        c = self.make(code='CNC', usage_limit=2)
        self.redeem(c, 'delivered', '50')
        self.redeem(c, 'cancelled', '999')
        row = self.list().json()['coupons'][0]
        self.assertEqual(row['used'], 1)
        self.assertEqual(row['given'], 50.0)
        self.assertEqual(row['remaining'], 1)

    def test_summary_counts_by_status(self):
        now = timezone.now()
        self.make(code='ON')
        self.make(code='PAUSED', is_active=False)
        self.make(code='OLD', valid_until=now - timedelta(days=1))
        self.make(code='SOON', valid_from=now + timedelta(days=2))
        full = self.make(code='FULL', usage_limit=1)
        self.redeem(full)
        s = self.list().json()['summary']
        self.assertEqual(s['total'], 5)
        self.assertEqual(s['active'], 1)
        self.assertEqual(s['paused'], 1)
        self.assertEqual(s['scheduled'], 1)
        self.assertEqual(s['expired'], 2)                      # expired + used_up
        self.assertEqual(s['used_total'], 1)
        self.assertEqual(s['given_total'], 100.0)


class CreateTests(CouponBase):
    def test_create_percent_ok(self):
        r = self.create(self.good(valid_from='2026-12-01', valid_until='2026-12-31'))
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()
        self.assertTrue(d['ok'])
        c = Coupon.objects.get(code='WELCOME50')
        self.assertEqual(c.vendor_id, self.a.vendor_id)
        self.assertEqual(c.created_by_id, self.a.user_id)
        self.assertEqual(c.value, D('20'))
        self.assertEqual(c.max_discount, D('150'))
        self.assertEqual(c.min_order, D('500'))
        self.assertEqual(c.usage_limit, 100)
        self.assertTrue(c.first_order_only)
        self.assertEqual(d['coupon']['valid_from'], '2026-12-01')
        self.assertEqual(d['coupon']['valid_until'], '2026-12-31')
        self.assertEqual(d['summary']['total'], 1)
        self.assertEqual(c.funded_by, 'vendor')

    def test_create_fixed_and_free_delivery(self):
        self.assertEqual(self.create({'code': 'FLAT100', 'discount_type': 'fixed', 'value': '100'}).status_code, 200)
        self.assertEqual(self.create({'code': 'FREEDEL', 'discount_type': 'free_delivery'}).status_code, 200)
        self.assertEqual(Coupon.objects.get(code='FLAT100').value, D('100'))
        fd = Coupon.objects.get(code='FREEDEL')
        self.assertEqual(fd.discount_type, 'free_delivery')
        self.assertEqual(fd.value, D('0'))

    def test_defaults(self):
        self.create({'code': 'PLAIN', 'discount_type': 'fixed', 'value': 50})
        c = Coupon.objects.get(code='PLAIN')
        self.assertEqual(c.per_customer_limit, 1)
        self.assertIsNone(c.usage_limit)
        self.assertFalse(c.first_order_only)
        self.assertIsNone(c.valid_from)

    def test_validation_errors_return_all(self):
        r = self.create({'code': 'a b', 'discount_type': 'percent', 'value': 95})
        self.assertEqual(r.status_code, 400)
        d = r.json()
        self.assertEqual(d['code'], 'validation')
        self.assertFalse(d['ok'])
        self.assertGreaterEqual(len(d['errors']), 2)
        self.assertEqual(d['error'], d['errors'][0])
        self.assertEqual(Coupon.objects.count(), 0)

    def test_bad_inputs(self):
        for body in (
            self.good(code='AB'),                                    # bohat chhota
            self.good(code='BAD-CODE!'),                             # nishan
            self.good(discount_type='bogus'),
            self.good(value=0),
            self.good(value='abc'),
            self.good(value='NaN'),                                  # NaN par crash nahi, saaf error
            self.good(value='Infinity'),
            self.good(value=71),                                     # vendor ki hadd 70%
            self.good(discount_type='fixed', value=100001),
            self.good(valid_from='2026-12-31', valid_until='2026-12-01'),
            self.good(valid_from='31-12-2026'),
            self.good(usage_limit=0),
            self.good(min_order=-5),
        ):
            r = self.create(body)
            self.assertEqual(r.status_code, 400, body)
            self.assertEqual(r.json()['code'], 'validation', body)
        self.assertEqual(Coupon.objects.count(), 0)

    def test_duplicate_code_even_other_vendors(self):
        self.make(self.b, code='TAKEN')
        r = self.create(self.good(code='taken'))
        self.assertEqual(r.status_code, 400)
        self.assertIn('pehle se', r.json()['error'])
        self.assertEqual(Coupon.objects.filter(code='TAKEN').count(), 1)

    def test_limit_50(self):
        for i in range(50):
            self.make(code=f'C{i:03d}')
        r = self.create(self.good(code='EXTRA1'))
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'limit')
        self.assertFalse(Coupon.objects.filter(code='EXTRA1').exists())

    def test_other_vendors_coupons_not_counted_in_limit(self):
        for i in range(50):
            self.make(self.b, code=f'B{i:03d}')
        self.assertEqual(self.create(self.good(code='MINEOK')).status_code, 200)

    def test_request_key_makes_retry_safe(self):
        body = self.good(code='ONCE1234', request_key='abcdef12345')
        r1 = self.create(body)
        r2 = self.create(body)                                       # net toota, vendor ne dobara bheja
        self.assertEqual(r1.status_code, 200)
        self.assertEqual(r2.status_code, 200)
        self.assertTrue(r2.json().get('duplicate'))
        self.assertEqual(Coupon.objects.filter(code='ONCE1234').count(), 1)

    def test_first_order_flag_false_values(self):
        self.create(self.good(code='NOFIRST', first_order_only=False))
        self.assertFalse(Coupon.objects.get(code='NOFIRST').first_order_only)
        self.create(self.good(code='NOFIRST2', first_order_only='false'))
        self.assertFalse(Coupon.objects.get(code='NOFIRST2').first_order_only)


class EditTests(CouponBase):
    def test_edit_own_code_not_flagged_duplicate_and_code_locked(self):
        c = self.make(code='KEEP10')
        r = self.edit(c.pk, self.good(code='SOMETHINGELSE', title='Naya title', value=15))
        self.assertEqual(r.status_code, 200, r.content)
        c.refresh_from_db()
        self.assertEqual(c.code, 'KEEP10')                          # code nahi badla
        self.assertEqual(c.title, 'Naya title')
        self.assertEqual(c.value, D('15'))
        self.assertEqual(c.min_order, D('500'))
        self.assertTrue(r.json()['ok'])

    def test_edit_other_vendors_coupon_404(self):
        c = self.make(self.b, code='BCOUP')
        r = self.edit(c.pk, self.good(value=5))
        self.assertEqual(r.status_code, 404)
        c.refresh_from_db()
        self.assertEqual(c.value, D('10'))

    def test_edit_shop_coupon_404(self):
        c = self.make(None, code='SHOP1', vendor=None)
        self.assertEqual(self.edit(c.pk, self.good()).status_code, 404)

    def test_edit_validation(self):
        c = self.make(code='VAL10')
        r = self.edit(c.pk, self.good(value=99))
        self.assertEqual(r.status_code, 400)
        c.refresh_from_db()
        self.assertEqual(c.value, D('10'))

    def test_used_coupon_core_fields_locked(self):
        c = self.make(code='USED10', max_discount=D('50'))
        self.redeem(c)
        r = self.edit(c.pk, self.good(discount_type='fixed', value=500, max_discount=999, title='Naya', min_order=700))
        self.assertEqual(r.status_code, 200, r.content)
        c.refresh_from_db()
        self.assertEqual(c.discount_type, 'percent')                # type nahi badla
        self.assertEqual(c.value, D('10'))                          # value nahi badli
        self.assertEqual(c.max_discount, D('50'))
        self.assertEqual(c.title, 'Naya')                           # baqi badal gaya
        self.assertEqual(c.min_order, D('700'))
        self.assertTrue(r.json()['coupon']['core_locked'])

    def test_usage_limit_cannot_go_below_used(self):
        c = self.make(code='LIM10', usage_limit=10)
        self.redeem(c)
        self.redeem(c)
        r = self.edit(c.pk, self.good(value=10, usage_limit=1))
        self.assertEqual(r.status_code, 400)
        self.assertIn('2', r.json()['error'])
        self.assertEqual(self.edit(c.pk, self.good(value=10, usage_limit=2)).status_code, 200)

    def test_clear_optional_fields(self):
        c = self.make(code='CLR10', usage_limit=5, min_order=D('200'), valid_until=timezone.now() + timedelta(days=5))
        r = self.edit(c.pk, {'discount_type': 'percent', 'value': 10, 'usage_limit': '', 'min_order': '', 'valid_until': ''})
        self.assertEqual(r.status_code, 200, r.content)
        c.refresh_from_db()
        self.assertIsNone(c.usage_limit)
        self.assertEqual(c.min_order, D('0'))
        self.assertIsNone(c.valid_until)


class ToggleTests(CouponBase):
    def test_flip(self):
        c = self.make(code='TGL10')
        r = self.toggle(c.pk)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()['coupon']['is_active'])
        self.assertEqual(r.json()['coupon']['status'], 'paused')
        r = self.toggle(c.pk)
        self.assertTrue(r.json()['coupon']['is_active'])

    def test_explicit_value_is_idempotent(self):
        c = self.make(code='TGL20')
        self.toggle(c.pk, {'active': False})
        self.toggle(c.pk, {'active': False})                         # retry: wapis chalu nahi hona chahiye
        c.refresh_from_db()
        self.assertFalse(c.is_active)
        self.toggle(c.pk, {'active': True})
        c.refresh_from_db()
        self.assertTrue(c.is_active)

    def test_other_vendor_404(self):
        c = self.make(self.b, code='BTGL')
        self.assertEqual(self.toggle(c.pk).status_code, 404)
        c.refresh_from_db()
        self.assertTrue(c.is_active)


class DeleteTests(CouponBase):
    def test_unused_is_deleted(self):
        c = self.make(code='DEL10')
        r = self.delete(c.pk)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['deleted'])
        self.assertFalse(Coupon.objects.filter(pk=c.pk).exists())
        self.assertEqual(r.json()['summary']['total'], 0)

    def test_used_is_only_paused_and_record_survives(self):
        c = self.make(code='DEL20')
        red = self.redeem(c)
        r = self.delete(c.pk)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()['deleted'])
        self.assertIn('band kar diya', r.json()['message'])
        self.assertFalse(r.json()['coupon']['is_active'])
        self.assertTrue(Coupon.objects.filter(pk=c.pk).exists())
        self.assertTrue(CouponRedemption.objects.filter(pk=red.pk).exists())      # purane order ka record bacha

    def test_other_vendor_404(self):
        c = self.make(self.b, code='BDEL')
        self.assertEqual(self.delete(c.pk).status_code, 404)
        self.assertTrue(Coupon.objects.filter(pk=c.pk).exists())

    def test_requires_post(self):
        c = self.make(code='DEL30')
        r = self.client.get(reverse('vendor_api_coupon_delete', args=[c.pk]), **self.bearer(self.a))
        self.assertEqual(r.status_code, 405)


class CheckoutEngineTests(CouponBase):
    """App se bana coupon customer checkout par (coupons.evaluate) wahi chalna chahiye."""

    def test_app_created_coupon_works_at_checkout(self):
        self.assertEqual(self.create(self.good(code='CHK20', first_order_only=False, min_order=500)).status_code, 200)
        ok = engine.evaluate('CHK20', self.customer, cart_for(self.a.vendor_id), D('1000'), D('100'))
        self.assertTrue(ok.ok, ok.message)
        self.assertEqual(ok.discount, D('150.00'))                  # 20% = 200, max 150
        self.assertEqual(ok.coupon.funded_by, 'vendor')
        # doosre store ke cart par nahi chalta
        self.assertFalse(engine.evaluate('CHK20', self.customer, cart_for(self.b.vendor_id), D('1000'), D('100')).ok)
        # min order se kam par nahi
        self.assertFalse(engine.evaluate('CHK20', self.customer, cart_for(self.a.vendor_id), D('400'), D('100')).ok)

    def test_paused_and_expired_do_not_apply(self):
        self.create(self.good(code='PAUSE1', first_order_only=False))
        c = Coupon.objects.get(code='PAUSE1')
        self.toggle(c.pk, {'active': False})
        self.assertFalse(engine.evaluate('PAUSE1', self.customer, cart_for(self.a.vendor_id), D('1000'), D('0')).ok)
        self.make(code='OLDONE', valid_until=timezone.now() - timedelta(days=1))
        self.assertFalse(engine.evaluate('OLDONE', self.customer, cart_for(self.a.vendor_id), D('1000'), D('0')).ok)

    def test_usage_limit_reached_stops_coupon(self):
        c = self.make(code='ONEUSE', usage_limit=1)
        self.redeem(c)
        self.assertFalse(engine.evaluate('ONEUSE', self.customer, cart_for(self.a.vendor_id), D('1000'), D('0')).ok)
        row = self.list().json()['coupons'][0]
        self.assertEqual(row['status'], 'used_up')
        self.assertEqual(row['remaining'], 0)
