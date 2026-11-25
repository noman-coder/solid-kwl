"""
Phase V8 tests: products tab API (list + search/filter/page, toggle, quick-update).

Run:  python manage.py test app.tests_vendor_products
Asli FCM ko koi call nahi jati (push_async mock hota hai).
"""
import json
from decimal import Decimal
from unittest import mock

from django.test import TestCase, override_settings
from django.urls import reverse

from app.customer import views_vendor_api as api
from app.models import Inventory, Product, Warehouse
from app.tests_vendor_api import PHONE_A, PHONE_B, make_vendor

LOCMEM = {'default': {'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'}}


@override_settings(CACHES=LOCMEM)
class ProductsBase(TestCase):
    def setUp(self):
        self.wh = Warehouse.objects.create(name='Main')
        self.a = make_vendor('Ali Store', PHONE_A)
        self.b = make_vendor('Bilal Store', PHONE_B)
        mock.patch('app.vendor_push.push_async').start()
        mock.patch('app.rider_push.push_async').start()
        self.addCleanup(mock.patch.stopall)

    def bearer(self, profile):
        return {'HTTP_AUTHORIZATION': 'Bearer ' + api._make_token(profile)}

    def mk(self, profile, name, price='100', stock=20, status='approved', active=True, threshold=10.0, reason=''):
        p = Product(name=name, vendor=profile.vendor, original_price=Decimal(price), price=Decimal(price),
                    approval_status=status, is_active=active, low_stock_threshold=threshold,
                    rejection_reason=reason)
        p._image_processed = True
        p.save()
        if stock:
            Inventory.objects.update_or_create(product=p, warehouse=self.wh, defaults={'stock': stock})
        return p

    def lst(self, profile=None, **params):
        return self.client.get(reverse('vendor_api_products'), params, **self.bearer(profile or self.a))

    def post(self, name, body, profile=None, **kw):
        return self.client.post(reverse(name, **kw), json.dumps(body), content_type='application/json',
                                **self.bearer(profile or self.a))


class ListTests(ProductsBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_products')).status_code, 401)

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.lst(c).status_code, 403)

    def test_only_own_products(self):
        self.mk(self.a, 'Aata')
        self.mk(self.b, 'Chawal')
        d = self.lst().json()
        self.assertTrue(d['ok'])
        self.assertEqual([p['name'] for p in d['products']], ['Aata'])
        self.assertEqual(d['counts']['all'], 1)

    def test_fields(self):
        self.mk(self.a, 'Aata', price='250', stock=7)
        p = self.lst().json()['products'][0]
        for k in ('id', 'name', 'image', 'category', 'price', 'original_price', 'discount_percent', 'stock',
                  'stock_state', 'approval_status', 'rejection_reason', 'is_active', 'visible', 'can_toggle'):
            self.assertIn(k, p)
        self.assertEqual(p['price'], 250.0)
        self.assertEqual(p['stock'], 7)
        self.assertTrue(p['visible'])

    def test_search_by_name(self):
        self.mk(self.a, 'Basmati Chawal')
        self.mk(self.a, 'Aata')
        names = [p['name'] for p in self.lst(q='chaw').json()['products']]
        self.assertEqual(names, ['Basmati Chawal'])

    def test_status_filter_and_counts(self):
        self.mk(self.a, 'A1')
        self.mk(self.a, 'P1', status='pending')
        self.mk(self.a, 'R1', status='rejected', reason='Photo saaf nahi')
        d = self.lst(status='rejected').json()
        self.assertEqual([p['name'] for p in d['products']], ['R1'])
        self.assertEqual(d['products'][0]['rejection_reason'], 'Photo saaf nahi')
        self.assertEqual(d['counts'], {'all': 3, 'approved': 1, 'pending': 1, 'rejected': 1, 'low': 0, 'out': 0})

    def test_stock_filters_match_dashboard_rules(self):
        self.mk(self.a, 'Theek', stock=50)
        self.mk(self.a, 'Kam', stock=3)
        self.mk(self.a, 'Khatam', stock=0)
        self.mk(self.a, 'Pending kam', stock=1, status='pending')       # pending: low mein nahi
        low = [p['name'] for p in self.lst(stock='low').json()['products']]
        out = [p['name'] for p in self.lst(stock='out').json()['products']]
        self.assertEqual(low, ['Kam'])
        self.assertEqual(out, ['Khatam'])
        counts = self.lst().json()['counts']
        self.assertEqual((counts['low'], counts['out']), (1, 1))
        dash = self.client.get(reverse('vendor_api_dashboard'), **self.bearer(self.a)).json()
        self.assertEqual((dash['stock']['low'], dash['stock']['out']), (1, 1))

    def test_zero_threshold_uses_default_ten(self):
        self.mk(self.a, 'Zero thr', stock=8, threshold=0.0)
        self.assertEqual(self.lst().json()['products'][0]['stock_state'], 'low')

    def test_bad_filters_ignored(self):
        self.mk(self.a, 'Aata')
        d = self.lst(status='zzz', stock='zzz').json()
        self.assertEqual(len(d['products']), 1)
        self.assertEqual((d['status'], d['stock']), ('', ''))

    def test_pagination(self):
        for i in range(25):
            self.mk(self.a, f'P{i:02d}')
        d1 = self.lst().json()
        d2 = self.lst(page=2).json()
        self.assertEqual(len(d1['products']), 20)
        self.assertTrue(d1['has_more'])
        self.assertEqual(len(d2['products']), 5)
        self.assertFalse(d2['has_more'])
        self.assertFalse({p['id'] for p in d1['products']} & {p['id'] for p in d2['products']})


class ToggleTests(ProductsBase):
    def test_toggle_flips(self):
        p = self.mk(self.a, 'Aata')
        r = self.post('vendor_api_product_toggle', {}, kwargs={'pk': p.pk})
        self.assertEqual(r.status_code, 200)
        p.refresh_from_db()
        self.assertFalse(p.is_active)
        self.assertFalse(r.json()['product']['visible'])
        self.post('vendor_api_product_toggle', {}, kwargs={'pk': p.pk})
        p.refresh_from_db()
        self.assertTrue(p.is_active)

    def test_explicit_active_is_idempotent(self):
        p = self.mk(self.a, 'Aata')
        self.post('vendor_api_product_toggle', {'active': False}, kwargs={'pk': p.pk})
        self.post('vendor_api_product_toggle', {'active': False}, kwargs={'pk': p.pk})   # double tap
        p.refresh_from_db()
        self.assertFalse(p.is_active)

    def test_other_vendor_gets_404(self):
        p = self.mk(self.b, 'Chawal')
        r = self.post('vendor_api_product_toggle', {}, kwargs={'pk': p.pk})
        self.assertEqual(r.status_code, 404)
        p.refresh_from_db()
        self.assertTrue(p.is_active)

    def test_only_approved(self):
        p = self.mk(self.a, 'Pending', status='pending')
        r = self.post('vendor_api_product_toggle', {}, kwargs={'pk': p.pk})
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'not_approved')

    def test_get_not_allowed(self):
        p = self.mk(self.a, 'Aata')
        r = self.client.get(reverse('vendor_api_product_toggle', kwargs={'pk': p.pk}), **self.bearer(self.a))
        self.assertEqual(r.status_code, 405)


class QuickUpdateTests(ProductsBase):
    def qu(self, items, profile=None):
        return self.post('vendor_api_products_quick_update', {'items': items}, profile)

    def test_price_and_stock(self):
        p = self.mk(self.a, 'Aata', price='100', stock=5)
        r = self.qu([{'id': p.pk, 'price': '120', 'discount': 0, 'add': 10}])
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()
        self.assertEqual(d['changed'], 1)
        p.refresh_from_db()
        self.assertEqual(p.original_price, Decimal('120.00'))
        self.assertEqual(Inventory.objects.get(product=p, warehouse=self.wh).stock, 15)
        self.assertEqual(d['results'][0]['product']['stock'], 15)

    def test_discount_applied(self):
        p = self.mk(self.a, 'Aata', price='100')
        self.qu([{'id': p.pk, 'price': '200', 'discount': 10}])
        p.refresh_from_db()
        self.assertEqual(p.price, Decimal('180.00'))

    def test_same_values_no_change(self):
        p = self.mk(self.a, 'Aata', price='100')
        d = self.qu([{'id': p.pk, 'price': '100'}]).json()
        self.assertEqual(d['changed'], 0)
        self.assertEqual(d['results'][0]['status'], 'same')
        self.assertEqual(d['message'], 'Koi tabdeeli nahi mili.')

    def test_validation_limits_like_web(self):
        p = self.mk(self.a, 'Aata', price='100', stock=5)
        for bad in ({'price': '0'}, {'price': '-5'}, {'price': 'abc'}, {'price': '100', 'discount': 95},
                    {'price': '100', 'add': -1}, {'price': '100', 'add': 2000000}):
            r = self.qu([dict(bad, id=p.pk)])
            self.assertEqual(r.status_code, 400, bad)
            self.assertFalse(r.json()['ok'])
        p.refresh_from_db()
        self.assertEqual(p.original_price, Decimal('100.00'))
        self.assertEqual(Inventory.objects.get(product=p, warehouse=self.wh).stock, 5)   # negative/ghalat se stock na badla

    def test_other_vendor_product_untouched(self):
        p = self.mk(self.b, 'Chawal', price='100')
        r = self.qu([{'id': p.pk, 'price': '999'}])
        self.assertEqual(r.status_code, 400)
        p.refresh_from_db()
        self.assertEqual(p.original_price, Decimal('100.00'))

    def test_partial_success(self):
        good = self.mk(self.a, 'Aata', price='100')
        bad = self.mk(self.a, 'Daal', price='50')
        d = self.qu([{'id': good.pk, 'price': '110'}, {'id': bad.pk, 'price': '0'}]).json()
        self.assertEqual(d['changed'], 1)
        self.assertTrue(d['ok'])
        self.assertEqual({r['id']: r['status'] for r in d['results']}, {good.pk: 'changed', bad.pk: 'error'})
        good.refresh_from_db()
        self.assertEqual(good.original_price, Decimal('110.00'))

    def test_stock_only_keeps_price(self):
        p = self.mk(self.a, 'Aata', price='100', stock=1)
        d = self.qu([{'id': p.pk, 'add': 4}]).json()
        self.assertEqual(d['changed'], 1)
        p.refresh_from_db()
        self.assertEqual(p.original_price, Decimal('100.00'))
        self.assertEqual(Inventory.objects.get(product=p, warehouse=self.wh).stock, 5)

    def test_single_item_shortcut_and_empty(self):
        p = self.mk(self.a, 'Aata', price='100')
        r = self.post('vendor_api_products_quick_update', {'id': p.pk, 'price': '105'})
        self.assertEqual(r.json()['changed'], 1)
        self.assertEqual(self.qu([]).status_code, 400)

    def test_too_many_items(self):
        r = self.qu([{'id': i, 'price': '1'} for i in range(1, api.QUICK_UPDATE_MAX_ITEMS + 2)])
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'too_many')

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.qu([{'id': 1, 'price': '1'}], c).status_code, 403)
