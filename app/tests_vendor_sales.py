"""
Phase V11 tests: sales API (summary / COD vs online / profit / chart / top / slow), statement, orders drill-down,
export (CSV / PDF), custom date range, ownership, aur product add/edit mein `purchase_rate`.

Run:  python manage.py test app.tests_vendor_sales
Asli FCM ko koi call nahi jati (push_async mock hota hai).
"""
import json
from datetime import datetime, time as dtime, timedelta
from decimal import Decimal

from django.urls import reverse
from django.utils import timezone

from app.customer import views_vendor_tools as vtools
from app.models import Product, SaleOrder, SaleOrderItem
from app.tests_vendor_api import PHONE_A, PHONE_B, make_vendor
from app.tests_vendor_dashboard import DashBase
from app.tests_vendor_product_form import FormBase
from app.vendor_commission import vendor_earnings


class SalesBase(DashBase):
    def sale(self, amount, status='delivered', payment='cod', days_ago=0, qty=1, product=None, profile=None,
             customer=None):
        """Ek order, ek item: qty x (amount/qty) = amount."""
        self.n += 1
        profile = profile or self.a
        when = timezone.now() - timedelta(days=days_ago)
        o = SaleOrder.objects.create(customer=customer or self.customer, warehouse=self.wh, status=status,
                                     vendor=profile.vendor, payment_method=payment, order_date=when,
                                     order_no=f'SL{self.n:04d}')
        p = product or Product.objects.create(name=f'Item {self.n}', vendor=profile.vendor,
                                              approval_status='approved')
        SaleOrderItem.objects.create(order=o, product=p, qty=qty, price=Decimal(str(amount)) / Decimal(qty))
        return o

    def get(self, name, profile=None, **params):
        return self.client.get(reverse(name), params, **self.bearer(profile or self.a))

    def sj(self, profile=None, **params):
        r = self.get('vendor_api_sales', profile, **params)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()


class SalesAuthTests(SalesBase):
    def test_requires_token(self):
        for name in ('vendor_api_sales', 'vendor_api_sales_statement', 'vendor_api_sales_orders',
                     'vendor_api_sales_export'):
            self.assertEqual(self.client.get(reverse(name)).status_code, 401, name)

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Naya', '03005555555', approved=False)
        for name in ('vendor_api_sales', 'vendor_api_sales_statement', 'vendor_api_sales_orders',
                     'vendor_api_sales_export'):
            r = self.get(name, c)
            self.assertEqual(r.status_code, 403, name)
            self.assertEqual(r.json()['code'], 'pending')

    def test_post_not_allowed(self):
        self.assertEqual(self.client.post(reverse('vendor_api_sales'), {}, **self.bearer(self.a)).status_code, 405)


class SalesNumbersTests(SalesBase):
    def test_empty_vendor_zeroes_and_profit_na(self):
        d = self.sj()
        self.assertTrue(d['ok'])
        self.assertEqual(d['summary']['sales'], 0)
        self.assertEqual(d['summary']['orders'], 0)
        self.assertEqual(d['summary']['avg_order'], 0)
        self.assertFalse(d['profit']['available'])
        self.assertIsNone(d['profit']['net'])
        self.assertEqual(len(d['chart']), 7)
        self.assertEqual(d['top'], [])

    def test_summary_matches_web_analytics(self):
        self.sale(500)
        self.sale(300, status='pending', payment='online', days_ago=2)
        self.sale(200, status='cancelled', days_ago=1)
        d = self.sj(period='week')
        today = timezone.localdate()
        start_date = today - timedelta(days=6)
        start = timezone.make_aware(datetime.combine(start_date, dtime.min))
        web = vtools._analytics_data(self.a.vendor, self.a, start_date, today, start)
        s = d['summary']
        self.assertEqual(s['sales'], float(web['sales']))
        self.assertEqual(s['orders'], web['total_orders'])
        self.assertEqual(s['cancelled'], web['cancelled'])
        self.assertEqual(s['avg_order'], float(web['avg_order']))
        self.assertEqual(s['net'], float(web['est_share']))
        self.assertEqual(s['sales'], 800.0)               # cancelled shamil nahi
        self.assertEqual(s['commission'], 80.0)           # default 10%
        self.assertEqual(s['net'], 720.0)
        self.assertEqual(d['commission_percent'], 10.0)

    def test_periods_today_week_month(self):
        self.sale(100, days_ago=0)
        self.sale(200, days_ago=3)
        self.sale(400, days_ago=20)
        self.assertEqual(self.sj(period='today')['summary']['sales'], 100.0)
        self.assertEqual(self.sj(period='week')['summary']['sales'], 300.0)
        self.assertEqual(self.sj(period='month')['summary']['sales'], 700.0)
        self.assertEqual(len(self.sj(period='month')['chart']), 30)
        self.assertEqual(self.sj(period='garbage')['period']['key'], 'week')       # ghalat -> week

    def test_chart_last_day_is_today_with_sale(self):
        self.sale(250)
        c = self.sj()['chart']
        self.assertEqual(c[-1]['date'], timezone.localdate().isoformat())
        self.assertEqual(c[-1]['sales'], 250.0)
        self.assertEqual(c[-1]['orders'], 1)

    def test_cod_vs_online_split(self):
        self.sale(600, payment='cod')
        self.sale(200, payment='')                       # khali == COD
        self.sale(400, payment='online')
        self.sale(100, payment='easypaisa')              # cod ke ilawa sab online
        p = self.sj()['payments']
        self.assertEqual(p['cod']['sales'], 800.0)
        self.assertEqual(p['cod']['orders'], 2)
        self.assertEqual(p['cod']['commission'], 80.0)
        self.assertEqual(p['cod']['net'], 720.0)
        self.assertEqual(p['online']['sales'], 500.0)
        self.assertEqual(p['online']['orders'], 2)

    def test_top_products_and_slow_products(self):
        big = Product.objects.create(name='Chawal', vendor=self.a.vendor, approval_status='approved')
        small = Product.objects.create(name='Namak', vendor=self.a.vendor, approval_status='approved')
        never = Product.objects.create(name='Kabhi Nahi', vendor=self.a.vendor, approval_status='approved')
        pending = Product.objects.create(name='Pending Item', vendor=self.a.vendor, approval_status='pending')
        self.sale(900, product=big, qty=3)
        self.sale(50, product=small, qty=1)
        d = self.sj()
        self.assertEqual(d['top'][0]['name'], 'Chawal')
        self.assertEqual(d['top'][0]['sales'], 900.0)
        self.assertEqual(d['top'][0]['qty'], 3)
        slow_names = [x['name'] for x in d['slow']]
        self.assertEqual(slow_names[0], 'Kabhi Nahi')        # 0 bikri sab se pehle
        self.assertNotIn('Pending Item', slow_names)         # sirf approved
        self.assertLess(slow_names.index('Namak'), slow_names.index('Chawal'))
        self.assertEqual(pending.approval_status, 'pending')
        self.assertEqual(never.pk, d['slow'][0]['product_id'])

    def test_lifetime_matches_vendor_earnings(self):
        e = vendor_earnings(self.a.vendor)
        d = self.sj()['lifetime']
        self.assertEqual(d['sales'], float(e['sales']))
        self.assertEqual(d['payable'], float(e['payable']))

    def test_other_vendor_orders_never_counted(self):
        self.sale(1000, profile=self.b)
        self.sale(100)
        self.assertEqual(self.sj()['summary']['sales'], 100.0)
        self.assertEqual(self.sj(self.b)['summary']['sales'], 1000.0)


class SalesCustomRangeTests(SalesBase):
    def test_custom_range_inclusive_and_exclusive(self):
        today = timezone.localdate()
        self.sale(100, days_ago=10)
        self.sale(200, days_ago=5)
        self.sale(400, days_ago=1)
        f = (today - timedelta(days=10)).isoformat()
        t = (today - timedelta(days=5)).isoformat()
        d = self.sj(period='custom', **{'from': f, 'to': t})
        self.assertEqual(d['summary']['sales'], 300.0)         # dono kinare shamil, 1 din pehle wala nahi
        self.assertEqual(d['period']['from'], f)
        self.assertEqual(d['period']['to'], t)
        self.assertEqual(d['period']['days'], 6)
        self.assertEqual(len(d['chart']), 6)

    def test_custom_validation_errors(self):
        today = timezone.localdate()
        r = self.get('vendor_api_sales', period='custom')
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'validation')
        r = self.get('vendor_api_sales', period='custom', **{'from': 'abc', 'to': today.isoformat()})
        self.assertEqual(r.status_code, 400)
        r = self.get('vendor_api_sales', period='custom',
                     **{'from': today.isoformat(), 'to': (today - timedelta(days=3)).isoformat()})
        self.assertEqual(r.status_code, 400)
        r = self.get('vendor_api_sales', period='custom',
                     **{'from': (today - timedelta(days=400)).isoformat(), 'to': today.isoformat()})
        self.assertEqual(r.status_code, 400)

    def test_custom_future_end_clamped_to_today(self):
        today = timezone.localdate()
        d = self.sj(period='custom', **{'from': today.isoformat(), 'to': (today + timedelta(days=9)).isoformat()})
        self.assertEqual(d['period']['to'], today.isoformat())

    def test_web_analytics_unchanged_without_end(self):
        """_analytics_data ko `end` na dein to purana rawayya (web)."""
        self.sale(100)
        today = timezone.localdate()
        sd = today - timedelta(days=6)
        start = timezone.make_aware(datetime.combine(sd, dtime.min))
        self.assertEqual(vtools._analytics_data(self.a.vendor, self.a, sd, today, start)['sales'], Decimal('100.00'))


class SalesProfitTests(SalesBase):
    def prod(self, rate, name='Cheeni'):
        return Product.objects.create(name=name, vendor=self.a.vendor, approval_status='approved',
                                      purchase_rate=None if rate is None else Decimal(str(rate)))

    def test_na_when_no_purchase_rate(self):
        self.sale(500, product=self.prod(None))
        p = self.sj()['profit']
        self.assertFalse(p['available'])
        self.assertIsNone(p['gross'])
        self.assertIsNone(p['net'])
        self.assertIsNone(p['margin_percent'])
        self.assertEqual(p['products_with_rate'], 0)

    def test_profit_with_rate(self):
        # 2 x Rs.100 = 200 sale, kharid 2 x 60 = 120 -> gross 80, commission 10% of 200 = 20, net 60
        self.sale(200, qty=2, product=self.prod(60))
        p = self.sj()['profit']
        self.assertTrue(p['available'])
        self.assertEqual(p['covered_sales'], 200.0)
        self.assertEqual(p['cost'], 120.0)
        self.assertEqual(p['gross'], 80.0)
        self.assertEqual(p['commission'], 20.0)
        self.assertEqual(p['net'], 60.0)
        self.assertEqual(p['margin_percent'], 30.0)
        self.assertEqual(p['products_with_rate'], 1)

    def test_partial_coverage_only_counts_products_with_rate(self):
        self.sale(200, qty=2, product=self.prod(60, 'A'))
        self.sale(1000, qty=1, product=self.prod(None, 'B'))
        d = self.sj()
        self.assertEqual(d['summary']['sales'], 1200.0)
        p = d['profit']
        self.assertEqual(p['covered_sales'], 200.0)          # sirf rate wale product ki sale
        self.assertEqual(p['net'], 60.0)
        self.assertEqual(p['products_total'], 2)
        self.assertEqual(p['products_with_rate'], 1)

    def test_cancelled_orders_not_in_profit(self):
        self.sale(200, qty=2, product=self.prod(60), status='cancelled')
        self.assertFalse(self.sj()['profit']['available'])

    def test_loss_shows_negative_net(self):
        self.sale(100, qty=1, product=self.prod(150))
        p = self.sj()['profit']
        self.assertEqual(p['gross'], -50.0)
        self.assertEqual(p['net'], -60.0)


class StatementTests(SalesBase):
    def test_only_done_orders_day_wise_newest_first(self):
        self.sale(1000, status='delivered', days_ago=0)
        self.sale(500, status='invoiced', days_ago=0, payment='online')
        self.sale(300, status='delivered', days_ago=2)
        self.sale(999, status='pending', days_ago=0)
        self.sale(888, status='cancelled', days_ago=0)
        d = self.get('vendor_api_sales_statement').json()
        self.assertTrue(d['ok'])
        self.assertEqual([x['sales'] for x in d['days']], [1500.0, 300.0])
        self.assertEqual(d['days'][0]['orders'], 2)
        self.assertEqual(d['days'][0]['commission'], 150.0)
        self.assertEqual(d['days'][0]['net'], 1350.0)
        self.assertEqual(d['days'][0]['date'], timezone.localdate().isoformat())
        self.assertEqual(d['total']['sales'], 1800.0)
        self.assertEqual(d['total']['net'], 1620.0)
        self.assertEqual(d['total']['orders'], 3)
        self.assertIn('lifetime', d)

    def test_other_vendor_not_included_and_range_respected(self):
        self.sale(700, profile=self.b)
        self.sale(100, days_ago=20)
        d = self.get('vendor_api_sales_statement', period='week').json()
        self.assertEqual(d['days'], [])
        self.assertEqual(d['total']['sales'], 0.0)
        d = self.get('vendor_api_sales_statement', period='month').json()
        self.assertEqual(d['total']['sales'], 100.0)

    def test_bad_custom_range(self):
        self.assertEqual(self.get('vendor_api_sales_statement', period='custom').status_code, 400)


class DrillDownTests(SalesBase):
    def ids(self, **params):
        r = self.get('vendor_api_sales_orders', **params)
        self.assertEqual(r.status_code, 200, r.content)
        return [o['order_no'] for o in r.json()['orders']], r.json()

    def test_groups(self):
        a = self.sale(100, status='delivered')
        b = self.sale(100, status='pending')
        c = self.sale(100, status='cancelled')
        self.assertEqual(set(self.ids()[0]), {a.order_no, b.order_no})                    # default = sales (live)
        self.assertEqual(set(self.ids(group='all')[0]), {a.order_no, b.order_no, c.order_no})
        self.assertEqual(self.ids(group='done')[0], [a.order_no])
        self.assertEqual(self.ids(group='open')[0], [b.order_no])
        self.assertEqual(self.ids(group='cancelled')[0], [c.order_no])
        self.assertEqual(set(self.ids(group='junk')[0]), {a.order_no, b.order_no})

    def test_payment_filter(self):
        a = self.sale(100, payment='cod')
        b = self.sale(100, payment='online')
        c = self.sale(100, payment='')
        self.assertEqual(set(self.ids(payment='cod')[0]), {a.order_no, c.order_no})
        self.assertEqual(self.ids(payment='online')[0], [b.order_no])

    def test_day_filter(self):
        a = self.sale(100, days_ago=0)
        self.sale(100, days_ago=2)
        names, d = self.ids(day=timezone.localdate().isoformat())
        self.assertEqual(names, [a.order_no])
        self.assertEqual(d['count'], 1)
        r = self.get('vendor_api_sales_orders', day='nahi')
        self.assertEqual(r.status_code, 400)

    def test_ownership(self):
        mine = self.sale(100)
        theirs = self.sale(100, profile=self.b)
        names, _ = self.ids(group='all')
        self.assertIn(mine.order_no, names)
        self.assertNotIn(theirs.order_no, names)

    def test_order_json_shape_and_paging(self):
        for _ in range(23):
            self.sale(10)
        names, d = self.ids(group='all')
        self.assertEqual(len(names), 20)
        self.assertTrue(d['has_more'])
        self.assertEqual(d['count'], 23)
        names2, d2 = self.ids(group='all', page=2)
        self.assertEqual(len(names2), 3)
        self.assertFalse(d2['has_more'])
        self.assertFalse(set(names) & set(names2))
        o = d['orders'][0]
        for k in ('id', 'order_no', 'status', 'total', 'payment', 'customer', 'items_preview'):
            self.assertIn(k, o)


class ExportTests(SalesBase):
    def test_csv_rows_and_headers(self):
        self.sale(500, payment='online')
        self.sale(300, status='cancelled')
        r = self.get('vendor_api_sales_export', period='week')
        self.assertEqual(r.status_code, 200)
        self.assertIn('text/csv', r['Content-Type'])
        self.assertIn('attachment; filename="sales_', r['Content-Disposition'])
        text = r.content.decode('utf-8-sig')
        lines = [l for l in text.splitlines() if l.strip()]
        self.assertEqual(lines[0], 'Order No,Date,Customer,Status,Payment,Items,Total (Rs.),Commission (Rs.),Net (Rs.)')
        self.assertEqual(len(lines), 3)
        joined = '\n'.join(lines)
        self.assertIn('Online', joined)
        self.assertIn('500.00,50.00,450.00', joined)
        self.assertIn('300.00,0.00,0.00', joined)           # cancelled: commission/net 0

    def test_csv_blocks_formula_injection(self):
        from app.models import Customer
        evil = Customer.objects.create(name='=HYPERLINK("x")', contact_number='03001112222', address='x')
        self.sale(100, customer=evil)
        text = self.get('vendor_api_sales_export').content.decode('utf-8-sig')
        self.assertIn("'=HYPERLINK", text)

    def test_csv_other_vendor_not_included(self):
        theirs = self.sale(100, profile=self.b)
        text = self.get('vendor_api_sales_export').content.decode('utf-8-sig')
        self.assertNotIn(theirs.order_no, text)

    def test_pdf(self):
        self.sale(500)
        r = self.get('vendor_api_sales_export', period='month', format='pdf')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r['Content-Type'], 'application/pdf')
        self.assertTrue(r.content.startswith(b'%PDF'))
        self.assertIn('.pdf"', r['Content-Disposition'])

    def test_export_bad_range(self):
        self.assertEqual(self.get('vendor_api_sales_export', period='custom').status_code, 400)


class PurchaseRateFormTests(FormBase):
    def mkc(self, profile, name, **kw):
        p = self.mk(profile, name, **kw)
        Product.objects.filter(pk=p.pk).update(category=self.cat)      # edit form ko category chahiye
        return p

    def test_add_with_purchase_rate_and_form_data_returns_it(self):
        r = self.add(self.form(purchase_rate=1200))
        self.assertEqual(r.status_code, 200, r.content)
        p = Product.objects.get(pk=r.json()['product']['id'])
        self.assertEqual(p.purchase_rate, Decimal('1200.00'))
        d = self.form_data(product=p.pk).json()
        self.assertEqual(d['product']['purchase_rate'], 1200.0)

    def test_add_without_purchase_rate_is_null(self):
        r = self.add()
        p = Product.objects.get(pk=r.json()['product']['id'])
        self.assertIsNone(p.purchase_rate)
        self.assertIsNone(self.form_data(product=p.pk).json()['product']['purchase_rate'])

    def test_invalid_purchase_rate_rejected_and_nothing_created(self):
        before = Product.objects.count()
        for bad in ('abc', -5, 0):
            r = self.add(self.form(purchase_rate=bad))
            self.assertEqual(r.status_code, 400, bad)
            self.assertEqual(r.json()['code'], 'validation')
        self.assertEqual(Product.objects.count(), before)

    def test_edit_sets_keeps_and_clears(self):
        p = self.mkc(self.a, 'Aata', price='200', stock=5)
        self.assertEqual(self.edit(p.pk, {'purchase_rate': 150}).status_code, 200)
        p.refresh_from_db()
        self.assertEqual(p.purchase_rate, Decimal('150.00'))
        self.assertEqual(self.edit(p.pk, {'name': 'Aata Fine'}).status_code, 200)      # key nahi -> waisi hi
        p.refresh_from_db()
        self.assertEqual(p.purchase_rate, Decimal('150.00'))
        self.assertEqual(self.edit(p.pk, {'purchase_rate': ''}).status_code, 200)      # khali -> hata do
        p.refresh_from_db()
        self.assertIsNone(p.purchase_rate)

    def test_edit_invalid_rate_changes_nothing(self):
        p = self.mkc(self.a, 'Aata', price='200', stock=5)
        Product.objects.filter(pk=p.pk).update(purchase_rate=Decimal('10'))
        r = self.edit(p.pk, {'purchase_rate': 'xyz', 'name': 'Naya Naam'})
        self.assertEqual(r.status_code, 400)
        p.refresh_from_db()
        self.assertEqual(p.purchase_rate, Decimal('10.00'))
        self.assertEqual(p.name, 'Aata')

    def test_edit_other_vendor_product_404(self):
        p = self.mk(self.b, 'Doosra', price='200', stock=5)
        self.assertEqual(self.edit(p.pk, {'purchase_rate': 50}).status_code, 404)
        p.refresh_from_db()
        self.assertIsNone(p.purchase_rate)
