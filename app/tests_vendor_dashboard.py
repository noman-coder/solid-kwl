"""
Phase V4 tests: vendor dashboard API (sale / orders / earnings / stock / chart / warnings) + store Open/Closed switch.

Run:  python manage.py test app.tests_vendor_dashboard
Asli FCM ko koi call nahi jati (push_async mock hota hai).
"""
import json
from datetime import datetime, time as dtime, timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth.models import User
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone

from app.customer import views_vendor_api as api
from app.customer import views_vendor_tools as vtools
from app.models import (Customer, Inventory, OrderReview, Product, RiderCashHandover, RiderProfile, SaleOrder,
                        SaleOrderItem, VendorProfile, Warehouse)
from app.tests_vendor_api import PHONE_A, PHONE_B, make_vendor
from app.vendor_commission import vendor_earnings

LOCMEM = {'default': {'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'}}

TOP_KEYS = ('ok', 'vendor', 'store', 'today', 'week', 'month', 'orders', 'new_orders', 'earnings',
            'commission_percent', 'rating', 'products', 'stock', 'rider_cash', 'chart', 'warnings')


@override_settings(CACHES=LOCMEM)
class DashBase(TestCase):
    def setUp(self):
        self.wh = Warehouse.objects.create(name='Main')
        self.customer = Customer.objects.create(name='Zara', contact_number='03003333333', address='Lahore')
        self.a = make_vendor('Ali Store', PHONE_A)
        self.b = make_vendor('Bilal Store', PHONE_B)
        self.n = 0
        mock.patch('app.vendor_push.push_async').start()
        mock.patch('app.rider_push.push_async').start()
        self.addCleanup(mock.patch.stopall)

    # ---- helpers
    def bearer(self, profile):
        return {'HTTP_AUTHORIZATION': 'Bearer ' + api._make_token(profile)}

    def dash(self, profile=None):
        profile = profile or self.a
        return self.client.get(reverse('vendor_api_dashboard'), **self.bearer(profile))

    def dj(self, profile=None):
        r = self.dash(profile)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def store_open(self, value, profile=None):
        kw = self.bearer(profile or self.a)
        return self.client.post(reverse('vendor_api_store_open'), json.dumps({'open': value}),
                                content_type='application/json', **kw)

    def order(self, profile=None, status='pending', amount=None, days_ago=0, product=None):
        """Order (status ke saath). amount diya ho to 1 item (qty 1) us raqam ka."""
        self.n += 1
        profile = profile or self.a
        when = timezone.now() - timedelta(days=days_ago)
        o = SaleOrder.objects.create(customer=self.customer, warehouse=self.wh, status=status,
                                     vendor=profile.vendor, payment_method='cod', order_date=when,
                                     order_no=f'VD{self.n:04d}')
        if amount is not None:
            p = product or Product.objects.create(name=f'Item {self.n}', vendor=profile.vendor)
            SaleOrderItem.objects.create(order=o, product=p, qty=1, price=Decimal(str(amount)))
        return o

    def product(self, profile=None, stock=50, threshold=10, status='approved', name=None):
        self.n += 1
        p = Product.objects.create(name=name or f'P{self.n}', vendor=(profile or self.a).vendor,
                                   low_stock_threshold=threshold, approval_status=status)
        Inventory.objects.create(product=p, warehouse=self.wh, stock=stock)
        return p

    def rider(self, name='rider1', phone='03007777777'):
        u = User.objects.create_user(name, f'{name}@x.com', 'secret12')
        return RiderProfile.objects.create(user=u, name=name.upper(), phone=phone)


# ---------------------------------------------------------------- auth / shape

class DashboardAuthTests(DashBase):
    def test_requires_login(self):
        r = self.client.get(reverse('vendor_api_dashboard'))
        self.assertEqual(r.status_code, 401)
        self.assertFalse(r.json()['ok'])
        self.assertEqual(r.json()['code'], 'auth')

    def test_bad_token(self):
        r = self.client.get(reverse('vendor_api_dashboard'), HTTP_AUTHORIZATION='Bearer nonsense')
        self.assertEqual(r.status_code, 401)

    def test_unapproved_vendor_gets_pending(self):
        pending = make_vendor('Naya Store', '03005555555', approved=False)
        r = self.dash(pending)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()['code'], 'pending')

    def test_post_not_allowed(self):
        r = self.client.post(reverse('vendor_api_dashboard'), {}, **self.bearer(self.a))
        self.assertEqual(r.status_code, 405)

    def test_old_token_after_password_change_rejected(self):
        headers = self.bearer(self.a)
        self.a.user.set_password('brand-new-pass')
        self.a.user.save()
        r = self.client.get(reverse('vendor_api_dashboard'), **headers)
        self.assertEqual(r.status_code, 401)


class DashboardShapeTests(DashBase):
    def test_empty_vendor_has_every_key_and_zeros(self):
        d = self.dj()
        for k in TOP_KEYS:
            self.assertIn(k, d)
        for k in ('today', 'week', 'month'):
            self.assertEqual(d[k], {'sales': 0.0, 'orders': 0})
        self.assertEqual(d['orders']['new'], 0)
        self.assertEqual(d['new_orders'], 0)
        self.assertEqual(d['products'], {'approved': 0, 'pending': 0, 'rejected': 0, 'total': 0})
        self.assertEqual(d['stock']['low'], 0)
        self.assertEqual(d['stock']['out'], 0)
        self.assertEqual(d['rider_cash'], {'count': 0, 'amount': 0.0})
        self.assertEqual(d['rating'], {'avg': None, 'count': 0})
        self.assertEqual(d['earnings']['sales'], 0.0)

    def test_chart_is_7_days_oldest_first_ending_today(self):
        d = self.dj()
        self.assertEqual(len(d['chart']), 7)
        today = timezone.localdate()
        self.assertEqual(d['chart'][-1]['date'], today.isoformat())
        self.assertEqual(d['chart'][0]['date'], (today - timedelta(days=6)).isoformat())
        for row in d['chart']:
            for k in ('date', 'label', 'sales', 'orders'):
                self.assertIn(k, row)

    def test_vendor_block_matches_me(self):
        d = self.dj()
        me = self.client.get(reverse('vendor_api_me'), **self.bearer(self.a)).json()['vendor']
        self.assertEqual(d['vendor'], me)
        self.assertEqual(d['commission_percent'], me['commission_percent'])


# ---------------------------------------------------------------- sale numbers

class DashboardSalesTests(DashBase):
    def test_today_week_month_sale_and_orders(self):
        self.order(amount=1000)                           # aaj
        self.order(amount=200, days_ago=3)                # hafte ke andar
        self.order(amount=300, days_ago=20)               # mahine ke andar
        self.order(amount=5000, days_ago=45)              # bahut purana - kisi mein nahi
        d = self.dj()
        self.assertEqual(d['today'], {'sales': 1000.0, 'orders': 1})
        self.assertEqual(d['week'], {'sales': 1200.0, 'orders': 2})
        self.assertEqual(d['month'], {'sales': 1500.0, 'orders': 3})

    def test_cancelled_orders_not_counted_in_sale(self):
        self.order(amount=1000)
        self.order(amount=999, status='cancelled')
        d = self.dj()
        self.assertEqual(d['today'], {'sales': 1000.0, 'orders': 1})
        self.assertEqual(d['orders']['cancelled_30d'], 1)

    def test_chart_has_todays_sale_in_last_slot(self):
        self.order(amount=700)
        self.order(amount=100, days_ago=2)
        c = self.dj()['chart']
        self.assertEqual(c[-1]['sales'], 700.0)
        self.assertEqual(c[-1]['orders'], 1)
        self.assertEqual(c[-3]['sales'], 100.0)
        self.assertEqual(sum(r['sales'] for r in c), 800.0)

    def test_numbers_match_web_analytics(self):
        """Web 'Analytics' page ke 7 aur 30 din ke hisab se wohi numbers."""
        self.order(amount=1000)
        self.order(amount=250, days_ago=4)
        self.order(amount=640, days_ago=15)
        self.order(amount=77, status='cancelled', days_ago=1)
        d = self.dj()
        today = timezone.localdate()
        for key, days in (('week', 7), ('month', 30)):
            start_date = today - timedelta(days=days - 1)
            start = timezone.make_aware(datetime.combine(start_date, dtime.min))
            web = vtools._analytics_data(self.a.vendor, self.a, start_date, today, start)
            self.assertEqual(d[key]['sales'], float(web['sales']), key)
            self.assertEqual(d[key]['orders'], web['total_orders'] - web['cancelled'], key)

    def test_other_vendors_sales_never_leak(self):
        self.order(self.b, amount=9999)
        self.order(self.a, amount=100)
        da, db = self.dj(self.a), self.dj(self.b)
        self.assertEqual(da['today']['sales'], 100.0)
        self.assertEqual(db['today']['sales'], 9999.0)

    def test_earnings_match_vendor_earnings(self):
        e = vendor_earnings(self.a.vendor)
        d = self.dj()['earnings']
        self.assertEqual(d['sales'], float(e['sales']))
        self.assertEqual(d['commission'], float(e['commission']))
        self.assertEqual(d['payable'], float(e['payable']))
        self.assertEqual(d['units'], e['units'])


# ---------------------------------------------------------------- orders / products / stock / cash / rating

class DashboardOrdersTests(DashBase):
    def test_status_counts_follow_web_tabs(self):
        for st in ('pending', 'pending', 'confirmed', 'processing', 'ready', 'delivered', 'cancelled'):
            self.order(status=st)
        self.order(self.b, status='pending')              # doosre vendor ka
        d = self.dj()
        self.assertEqual(d['orders']['new'], 2)
        self.assertEqual(d['orders']['active'], 3)
        self.assertEqual(d['orders']['done'], 2)
        self.assertEqual(d['new_orders'], 2)
        self.assertEqual(d['orders']['by_status']['pending'], 2)
        codes = [w['code'] for w in d['warnings']]
        self.assertIn('new_orders', codes)

    def test_no_new_orders_no_warning(self):
        self.order(status='delivered')
        self.assertNotIn('new_orders', [w['code'] for w in self.dj()['warnings']])


class DashboardProductsStockTests(DashBase):
    def test_product_counts_by_approval(self):
        self.product(status='approved')
        self.product(status='approved')
        self.product(status='pending')
        self.product(status='rejected')
        self.product(self.b, status='approved')
        self.assertEqual(self.dj()['products'], {'approved': 2, 'pending': 1, 'rejected': 1, 'total': 4})

    def test_low_and_out_of_stock(self):
        self.product(stock=3, threshold=10, name='Kam')
        self.product(stock=0, threshold=10, name='Khatam')
        self.product(stock=50, threshold=10, name='Theek')
        self.product(stock=0, status='pending', name='Pending')       # approved nahi: gina nahi jata
        self.product(self.b, stock=0, name='Doosre ka')
        s = self.dj()['stock']
        self.assertEqual(s['low'], 1)
        self.assertEqual(s['out'], 1)
        names = [i['name'] for i in s['items']]
        self.assertEqual(names, ['Khatam', 'Kam'])               # kam stock wala pehle
        self.assertTrue(s['items'][0]['out'])
        self.assertFalse(s['items'][1]['out'])

    def test_stock_items_limited_to_five(self):
        for i in range(8):
            self.product(stock=i, name=f'Kam{i}')
        s = self.dj()['stock']
        self.assertEqual(len(s['items']), 5)
        self.assertEqual(s['low'] + s['out'], 8)

    def test_stock_matches_web_stock_rows(self):
        self.product(stock=2)
        self.product(stock=0)
        self.product(stock=100)
        rows = vtools._stock_rows(self.a.vendor, Warehouse.objects.first())
        d = self.dj()['stock']
        self.assertEqual(d['low'] + d['out'], sum(1 for r in rows if r['low']))

    def test_warnings_for_stock_and_products(self):
        self.product(stock=0)
        self.product(stock=2)
        self.product(status='rejected')
        self.product(status='pending')
        codes = [w['code'] for w in self.dj()['warnings']]
        for c in ('out_of_stock', 'low_stock', 'rejected_products', 'pending_products'):
            self.assertIn(c, codes)


class DashboardCashRatingTests(DashBase):
    def test_pending_rider_cash_only_for_this_vendor(self):
        r = self.rider()
        RiderCashHandover.objects.create(rider=r, receiver='vendor', vendor=self.a.vendor, amount=Decimal('500'))
        RiderCashHandover.objects.create(rider=r, receiver='vendor', vendor=self.a.vendor, amount=Decimal('250.50'))
        RiderCashHandover.objects.create(rider=r, receiver='vendor', vendor=self.b.vendor, amount=Decimal('999'))
        RiderCashHandover.objects.create(rider=r, receiver='vendor', vendor=self.a.vendor, amount=Decimal('111'),
                                         status='confirmed')
        RiderCashHandover.objects.create(rider=r, receiver='admin', amount=Decimal('222'))
        d = self.dj()
        self.assertEqual(d['rider_cash'], {'count': 2, 'amount': 750.5})
        self.assertIn('rider_cash', [w['code'] for w in d['warnings']])

    def test_rating_from_reviews(self):
        for stars in (5, 4):
            o = self.order(status='delivered')
            OrderReview.objects.create(sale_order=o, vendor=self.a.vendor, vendor_rating=stars)
        o = self.order(self.b, status='delivered')
        OrderReview.objects.create(sale_order=o, vendor=self.b.vendor, vendor_rating=1)
        d = self.dj()
        self.assertEqual(d['rating'], {'avg': 4.5, 'count': 2})
        self.assertEqual(d['vendor']['rating'], 4.5)


# ---------------------------------------------------------------- store open / closed

class StoreStateTests(DashBase):
    def test_open_by_default(self):
        s = self.dj()['store']
        self.assertEqual(s['status'], 'open')
        self.assertTrue(s['switch_on'])
        self.assertTrue(s['is_open'])
        self.assertTrue(s['within_hours'])
        codes = [w['code'] for w in self.dj()['warnings']]
        self.assertNotIn('store_closed', codes)

    def test_closed_store_warning(self):
        VendorProfile.objects.filter(pk=self.a.pk).update(store_status='closed')
        d = self.dj()
        self.assertFalse(d['store']['switch_on'])
        self.assertFalse(d['store']['is_open'])
        self.assertIn('store_closed', [w['code'] for w in d['warnings']])

    def test_outside_hours_switch_on_but_not_open(self):
        now_t = timezone.localtime()
        opens = (now_t + timedelta(hours=2)).time().replace(second=0, microsecond=0)
        closes = (now_t + timedelta(hours=3)).time().replace(second=0, microsecond=0)
        VendorProfile.objects.filter(pk=self.a.pk).update(opens_at=opens, closes_at=closes)
        d = self.dj()
        self.assertTrue(d['store']['switch_on'])
        self.assertFalse(d['store']['within_hours'])
        self.assertFalse(d['store']['is_open'])
        self.assertEqual(d['store']['opens_at'], opens.strftime('%H:%M'))
        self.assertIn('outside_hours', [w['code'] for w in d['warnings']])

    def test_busy_store_info(self):
        VendorProfile.objects.filter(pk=self.a.pk).update(store_status='busy')
        d = self.dj()
        self.assertTrue(d['store']['switch_on'])
        self.assertIn('store_busy', [w['code'] for w in d['warnings']])

    def test_location_unverified_info_then_verified(self):
        self.assertIn('location_unverified', [w['code'] for w in self.dj()['warnings']])
        VendorProfile.objects.filter(pk=self.a.pk).update(location_verified=True)
        d = self.dj()
        self.assertTrue(d['store']['location_verified'])
        self.assertNotIn('location_unverified', [w['code'] for w in d['warnings']])


class StoreOpenApiTests(DashBase):
    def status(self, profile=None):
        return VendorProfile.objects.get(pk=(profile or self.a).pk).store_status

    def test_close_then_open(self):
        r = self.store_open(False)
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'])
        self.assertFalse(d['store']['switch_on'])
        self.assertFalse(d['store']['is_open'])
        self.assertFalse(d['vendor']['is_open'])
        self.assertEqual(self.status(), 'closed')

        r = self.store_open(True)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['store']['is_open'])
        self.assertEqual(self.status(), 'open')

    def test_closing_is_visible_on_dashboard_and_me(self):
        self.store_open(False)
        self.assertFalse(self.dj()['store']['is_open'])
        me = self.client.get(reverse('vendor_api_me'), **self.bearer(self.a)).json()['vendor']
        self.assertEqual(me['store_status'], 'closed')
        self.assertFalse(me['is_open'])

    def test_open_keeps_busy(self):
        VendorProfile.objects.filter(pk=self.a.pk).update(store_status='busy')
        r = self.store_open(True)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.status(), 'busy')

    def test_string_values_accepted(self):
        self.assertEqual(self.store_open('false').status_code, 200)
        self.assertEqual(self.status(), 'closed')
        self.assertEqual(self.store_open('true').status_code, 200)
        self.assertEqual(self.status(), 'open')

    def test_form_post_accepted(self):
        r = self.client.post(reverse('vendor_api_store_open'), {'open': '0'}, **self.bearer(self.a))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.status(), 'closed')

    def test_bad_value_rejected_and_nothing_changes(self):
        for bad in (None, '', 'maybe', 7, [], {}):
            r = self.store_open(bad)
            self.assertEqual(r.status_code, 400, repr(bad))
            self.assertFalse(r.json()['ok'])
        self.assertEqual(self.status(), 'open')

    def test_missing_body_rejected(self):
        r = self.client.post(reverse('vendor_api_store_open'), **self.bearer(self.a))
        self.assertEqual(r.status_code, 400)

    def test_repeat_is_harmless(self):
        self.store_open(False)
        r = self.store_open(False)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.status(), 'closed')

    def test_only_this_vendors_store_changes(self):
        self.store_open(False, self.a)
        self.assertEqual(self.status(self.a), 'closed')
        self.assertEqual(self.status(self.b), 'open')

    def test_does_not_touch_other_profile_fields(self):
        VendorProfile.objects.filter(pk=self.a.pk).update(min_order_amount=Decimal('250'), delivery_fee=Decimal('40'))
        self.store_open(False)
        p = VendorProfile.objects.get(pk=self.a.pk)
        self.assertEqual(p.min_order_amount, Decimal('250'))
        self.assertEqual(p.delivery_fee, Decimal('40'))

    def test_requires_login(self):
        r = self.client.post(reverse('vendor_api_store_open'), json.dumps({'open': False}),
                             content_type='application/json')
        self.assertEqual(r.status_code, 401)
        self.assertEqual(self.status(), 'open')

    def test_unapproved_vendor_cannot_switch(self):
        pending = make_vendor('Naya Store', '03005555555', approved=False)
        r = self.store_open(False, pending)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()['code'], 'pending')
        self.assertEqual(self.status(pending), 'open')

    def test_get_not_allowed(self):
        r = self.client.get(reverse('vendor_api_store_open'), **self.bearer(self.a))
        self.assertEqual(r.status_code, 405)

    def test_message_mentions_timing_when_opened_outside_hours(self):
        now_t = timezone.localtime()
        opens = (now_t + timedelta(hours=2)).time().replace(second=0, microsecond=0)
        closes = (now_t + timedelta(hours=3)).time().replace(second=0, microsecond=0)
        VendorProfile.objects.filter(pk=self.a.pk).update(store_status='closed', opens_at=opens, closes_at=closes)
        d = self.store_open(True).json()
        self.assertTrue(d['store']['switch_on'])
        self.assertFalse(d['store']['is_open'])
        self.assertIn('timing', d['message'])
