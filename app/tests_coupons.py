"""
Tests: coupons, migration 0056 safety.

Run:  python manage.py test app.tests_coupons -v 2

NOTE: Likhi gayi code padh kar, bina Django chalaye. Agar fixture line kisi field naam par fail ho
to setUp theek kar lein - assertions asal cheez hain.
"""
import re
from datetime import timedelta
from decimal import Decimal
from pathlib import Path

from django.test import TestCase
from django.utils import timezone

from app.customer import coupons as engine
from app.models import Coupon, Customer, SaleOrder, Vendor, Warehouse

D = Decimal


def cart_for(vendor_id=0):
    return {'1': {'product_id': 1, 'vendor_id': vendor_id, 'quantity': 1, 'price': 1000}}


class MigrationSafetyTests(TestCase):
    def test_migration_0056_has_no_destructive_operations(self):
        path = Path(__file__).parent / 'migrations' / '0056_coupons_favorites_review_reply.py'
        text = path.read_text(encoding='utf-8')
        code = re.sub(r'""".*?"""', '', text, flags=re.S)      # docstring mein likhe lafz ginti mein nahi
        for bad in ('RemoveField', 'DeleteModel', 'RunPython', 'RunSQL', 'AlterField', 'RenameField', 'RenameModel'):
            self.assertNotIn(bad, code, f'0056 mein {bad} nahi hona chahiye (data safe rehna chahiye)')


class CouponBase(TestCase):
    def setUp(self):
        self.wh = Warehouse.objects.create(name='Main')
        self.cust = Customer.objects.create(name='Ali', customer_code='C-001')
        self.vendor = Vendor.objects.create(name='Store A', vendor_code='V-001')

    def make(self, **kw):
        data = dict(code='SAVE10', discount_type='percent', value=D('10'))
        data.update(kw)
        return Coupon.objects.create(**data)

    def order(self, status='pending', n=1):
        return SaleOrder.objects.create(order_no=f'ORD-T-{n}', customer=self.cust, warehouse=self.wh, status=status)


class DiscountMathTests(CouponBase):
    def test_percent_with_cap(self):
        c = self.make(value=D('20'), max_discount=D('150'))
        self.assertEqual(c.compute_discount(D('1000')), D('150.00'))      # 200 -> cap 150
        self.assertEqual(c.compute_discount(D('500')), D('100.00'))

    def test_fixed_never_exceeds_subtotal(self):
        c = self.make(discount_type='fixed', value=D('300'))
        self.assertEqual(c.compute_discount(D('200')), D('200.00'))
        self.assertEqual(c.compute_discount(D('1000')), D('300.00'))

    def test_code_is_uppercased_and_trimmed(self):
        c = self.make(code=' welcome 50 ')
        self.assertEqual(c.code, 'WELCOME50')


class EvaluateRulesTests(CouponBase):
    def ev(self, code='SAVE10', cart=None, subtotal=D('1000'), delivery=D('100'), customer='default'):
        customer = self.cust if customer == 'default' else customer
        return engine.evaluate(code, customer, cart if cart is not None else cart_for(0), subtotal, delivery)

    def test_unknown_code(self):
        self.assertFalse(self.ev('NOPE').ok)

    def test_success_percent(self):
        self.make()
        r = self.ev()
        self.assertTrue(r.ok)
        self.assertEqual(r.discount, D('100.00'))

    def test_inactive_expired_and_scheduled(self):
        now = timezone.now()
        self.make(code='OFF', is_active=False)
        self.make(code='OLD', valid_until=now - timedelta(days=1))
        self.make(code='SOON', valid_from=now + timedelta(days=1))
        for code in ('OFF', 'OLD', 'SOON'):
            self.assertFalse(self.ev(code).ok, code)

    def test_min_order(self):
        self.make(min_order=D('1500'))
        self.assertFalse(self.ev().ok)
        self.assertTrue(self.ev(subtotal=D('1600')).ok)

    def test_vendor_coupon_only_for_that_store(self):
        self.make(code='STORE5', vendor=self.vendor)
        self.assertFalse(self.ev('STORE5', cart=cart_for(0)).ok)
        self.assertFalse(self.ev('STORE5', cart=cart_for(self.vendor.id + 99)).ok)
        self.assertTrue(self.ev('STORE5', cart=cart_for(self.vendor.id)).ok)

    def test_shop_coupon_works_for_any_store_cart(self):
        self.make()
        self.assertTrue(self.ev(cart=cart_for(self.vendor.id)).ok)

    def test_free_delivery(self):
        self.make(code='FREEDEL', discount_type='free_delivery', value=D('0'))
        r = self.ev('FREEDEL')
        self.assertTrue(r.ok)
        self.assertTrue(r.free_delivery)
        self.assertEqual(r.delivery_waived, D('100'))
        self.assertFalse(self.ev('FREEDEL', delivery=D('0')).ok)         # delivery pehle se free

    def test_per_customer_limit_and_cancelled_order_gives_coupon_back(self):
        c = self.make(per_customer_limit=1)
        r = self.ev()
        order = self.order()
        self.assertTrue(engine.redeem(r, order, self.cust))
        self.assertFalse(self.ev().ok)                                   # ek dafa istemal ho chuka
        order.status = 'cancelled'
        order.save()
        self.assertTrue(self.ev().ok)                                    # cancel hone par wapis mil gaya
        self.assertEqual(c.used_count, 0)

    def test_total_usage_limit(self):
        self.make(usage_limit=1, per_customer_limit=0)
        r = self.ev()
        self.assertTrue(engine.redeem(r, self.order(n=1), self.cust))
        other = Customer.objects.create(name='Sara', customer_code='C-002')
        self.assertFalse(engine.evaluate('SAVE10', other, cart_for(0), D('1000'), D('100')).ok)

    def test_first_order_only(self):
        self.make(first_order_only=True, per_customer_limit=0)
        self.assertTrue(self.ev().ok)
        self.order(n=7)                                                  # ab pehla order nahi raha
        self.assertFalse(self.ev().ok)


class ApplyToOrderTests(CouponBase):
    def test_redeem_records_and_sets_code(self):
        self.make(vendor=self.vendor)
        r = engine.evaluate('SAVE10', self.cust, cart_for(self.vendor.id), D('1000'), D('50'))
        order = self.order()
        order.discount_value = r.discount
        order.save()
        applied, disc, fee = engine.apply_to_new_order(r, order, self.cust, D('50'))
        self.assertTrue(applied)
        order.refresh_from_db()
        self.assertEqual(order.coupon_code, 'SAVE10')
        self.assertEqual(order.coupon_redemption.discount_amount, D('100.00'))
        self.assertEqual(order.coupon_redemption.funded_by, 'vendor')
        self.assertEqual(order.discount_value, D('100.00'))

    def test_failed_redeem_removes_discount_but_keeps_order(self):
        c = self.make(usage_limit=1, per_customer_limit=0)
        r = engine.evaluate('SAVE10', self.cust, cart_for(0), D('1000'), D('50'))
        # koi aur order pehle ye aakhri istemal le jata hai (race)
        other = Customer.objects.create(name='Sara', customer_code='C-002')
        o1 = SaleOrder.objects.create(order_no='ORD-T-1', customer=other, warehouse=self.wh)
        self.assertTrue(engine.redeem(r, o1, other))
        o2 = self.order(n=2)
        o2.discount_value = r.discount
        o2.save()
        applied, disc, fee = engine.apply_to_new_order(r, o2, self.cust, D('50'))
        self.assertFalse(applied)
        o2.refresh_from_db()
        self.assertEqual(o2.discount_value, D('0.00'))
        self.assertEqual(o2.coupon_code, '')
