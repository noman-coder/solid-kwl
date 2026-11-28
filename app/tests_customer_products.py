"""
Phase C6 tests: api/customer/products/ (search, typo correction, filters, sort, page), products/<id>/ (detail) aur
search/suggest/.

Run:  python manage.py test app.tests_customer_products -v 2

Cache locmem par override hai (Redis ki zaroorat nahi). Koi migration nahi.
"""
from datetime import timedelta
from decimal import Decimal

from django.urls import reverse
from django.utils import timezone

from app.models import (Category, Inventory, Product, ProductOffer, RecentlyViewed, ShopSearchLog, VendorProfile,
                        Warehouse)
from app.tests_customer_home import HomeBase, make_store

D = Decimal
LIST = 'customer_api_products'
DETAIL = 'customer_api_product_detail'
SUGGEST = 'customer_api_suggest'


class ProductsBase(HomeBase):
    def names(self, **params):
        return [p['name'] for p in self.get(LIST, **params).json()['products']]

    def detail(self, pk, token=None, **params):
        extra = {'HTTP_AUTHORIZATION': f'Bearer {token}'} if token else {}
        return self.client.get(reverse(DETAIL, args=[pk]), params, **extra)

    def add_product(self, vp, name, category=None, price='100', stock=None, **kw):
        p = Product.objects.create(name=name, vendor=vp.vendor, price=D(price), is_active=True,
                                   approval_status='approved', category=category, **kw)
        if stock is not None:
            Inventory.objects.create(product=p, warehouse=Warehouse.objects.get_or_create(name='Main')[0], stock=stock)
        return p


class ProductListTests(ProductsBase):
    def test_guest_can_open_list_and_shape(self):
        make_store('Shop A')
        r = self.get(LIST)
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'])
        for key in ('products', 'sorts', 'filters', 'categories', 'page', 'total', 'has_more', 'area', 'q',
                    'did_you_mean', 'sort'):
            self.assertIn(key, d)
        p = d['products'][0]
        for key in ('id', 'name', 'price', 'unit', 'in_stock', 'stock', 'can_add', 'store_id', 'store_name',
                    'store_open', 'category_name', 'old_price', 'discount_percent'):
            self.assertIn(key, p)
        self.assertFalse(d['logged_in'])
        self.assertEqual(r['Cache-Control'], 'no-store')

    def test_bad_token_is_401(self):
        self.assertEqual(self.get(LIST, token='garbage').status_code, 401)

    def test_post_not_allowed(self):
        self.assertEqual(self.client.post(reverse(LIST)).status_code, 405)

    def test_inactive_rejected_pending_never_listed(self):
        vp, first = make_store('Shop')
        off = self.add_product(vp, 'Off Item')
        Product.objects.filter(pk=off.pk).update(is_active=False)
        rej = self.add_product(vp, 'Rejected Item')
        Product.objects.filter(pk=rej.pk).update(approval_status='rejected')
        pen = self.add_product(vp, 'Pending Item')
        Product.objects.filter(pk=pen.pk).update(approval_status='pending')
        self.assertEqual(self.names(), ['Shop item'])

    def test_unapproved_store_products_hidden(self):
        make_store('Live Shop')
        make_store('Pending Shop', approved=False)
        self.assertEqual(self.names(), ['Live Shop item'])

    def test_search_by_name_and_description(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Cola')
        self.add_product(vp, 'Pepsi', description='thanda paani')
        self.assertEqual(self.names(q='cola'), ['Cola'])
        self.assertEqual(self.names(q='thanda'), ['Pepsi'])

    def test_search_relevance_name_first(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Dahi Bhalla', description='cola ke saath')
        self.add_product(vp, 'Cola Max')
        self.add_product(vp, 'Diet Cola')
        self.assertEqual(self.names(q='cola'), ['Cola Max', 'Diet Cola', 'Dahi Bhalla'])

    def test_wrong_spelling_gets_did_you_mean(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Pepsi')
        d = self.get(LIST, q='Pepsii').json()
        self.assertEqual(d['did_you_mean'], 'pepsi')
        self.assertTrue(d['typo_corrected'])
        self.assertEqual([p['name'] for p in d['products']], ['Pepsi'])
        self.assertEqual(d['q'], 'Pepsii')

    def test_exact_search_has_no_did_you_mean(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Pepsi')
        d = self.get(LIST, q='pepsi').json()
        self.assertEqual(d['did_you_mean'], '')
        self.assertFalse(d['typo_corrected'])

    def test_nonsense_search_is_empty_not_error(self):
        make_store('Shop')
        d = self.get(LIST, q='zzzzqqqq').json()
        self.assertEqual((d['products'], d['total'], d['did_you_mean']), ([], 0, ''))

    def test_category_filter(self):
        vp, _ = make_store('Shop')
        drinks = Category.objects.create(name='Drinks')
        self.add_product(vp, 'Cola', category=drinks)
        self.assertEqual(self.names(category=str(drinks.id)), ['Cola'])
        self.assertEqual(self.names(category='99999'), [])

    def test_store_filter(self):
        a, _ = make_store('Shop A')
        b, _ = make_store('Shop B')
        self.add_product(b, 'B Special')
        self.assertEqual(sorted(self.names(store=str(b.pk))), ['B Special', 'Shop B item'])
        self.assertEqual(self.names(store=str(a.pk)), ['Shop A item'])

    def test_area_filter_hides_outside_products(self):
        make_store('Lahore Shop', city='Lahore')
        make_store('Khanewal Shop', city='Khanewal')
        self.assertEqual(self.names(area='Khanewal'), ['Khanewal Shop item'])
        self.assertEqual(len(self.names(area='')), 2)

    def test_in_stock_filter(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Available', stock=5)
        self.assertEqual(self.names(in_stock='1'), ['Available'])
        self.assertEqual(len(self.names()), 2)

    def test_out_of_stock_cannot_be_added(self):
        make_store('Shop')                                          # koi inventory nahi = stock 0
        item = self.get(LIST).json()['products'][0]
        self.assertFalse(item['in_stock'])
        self.assertFalse(item['can_add'])

    def test_closed_store_blocks_add(self):
        vp, p = make_store('Closed Shop', status='closed')
        Inventory.objects.create(product=p, warehouse=Warehouse.objects.create(name='Main'), stock=5)
        item = self.get(LIST).json()['products'][0]
        self.assertFalse(item['store_open'])
        self.assertFalse(item['can_add'])
        self.assertIn('abhi band hai', item['closed_message'])

    def test_price_includes_product_discount(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Cola', price='200', discount_percentage=D('10'))
        item = [p for p in self.get(LIST).json()['products'] if p['name'] == 'Cola'][0]
        self.assertEqual(item['price'], 180.0)
        self.assertEqual(item['old_price'], 200.0)
        self.assertEqual(item['discount_percent'], 10.0)

    def test_price_includes_live_offer(self):
        vp, _ = make_store('Shop')
        p = self.add_product(vp, 'Cola', price='100')
        now = timezone.now()
        ProductOffer.objects.create(product=p, profile=vp, discount_percent=D('20'),
                                    starts_at=now - timedelta(hours=1), ends_at=now + timedelta(hours=5))
        item = [x for x in self.get(LIST).json()['products'] if x['name'] == 'Cola'][0]
        self.assertEqual(item['price'], 80.0)

    def test_sort_by_price_uses_final_price(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Cheap', price='50')
        self.add_product(vp, 'Mid', price='100')
        self.add_product(vp, 'Pricey', price='300', discount_percentage=D('50'))     # final 150
        low = [p for p in self.names(sort='price_low') if p != 'Shop item']
        high = [p for p in self.names(sort='price_high') if p != 'Shop item']
        self.assertEqual(low, ['Cheap', 'Mid', 'Pricey'])
        self.assertEqual(high, ['Pricey', 'Mid', 'Cheap'])

    def test_price_range_filter_on_final_price(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Cheap', price='50')
        self.add_product(vp, 'Pricey', price='300', discount_percentage=D('50'))     # final 150
        self.assertEqual(self.names(price_min='120', price_max='200'), ['Pricey'])
        self.assertEqual(self.names(price_max='60'), ['Cheap'])
        self.assertEqual(self.names(price_min='200', price_max='120'), ['Pricey'])   # ulte hon to khud theek

    def test_bad_params_do_not_crash(self):
        make_store('Shop')
        r = self.get(LIST, price_min='abc', price_max='-5', category='x', store='y', page='zz', sort='bogus')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['sort'], 'newest')

    def test_pagination(self):
        vp, _ = make_store('Shop')
        for i in range(30):
            self.add_product(vp, f'Item {i:02d}')
        d1 = self.get(LIST).json()
        self.assertEqual((len(d1['products']), d1['total'], d1['has_more']), (24, 31, True))
        d2 = self.get(LIST, page='2').json()
        self.assertEqual((len(d2['products']), d2['has_more']), (7, False))
        ids = {p['id'] for p in d1['products']} | {p['id'] for p in d2['products']}
        self.assertEqual(len(ids), 31)

    def test_no_coordinates_leak(self):
        make_store('Near Shop', lat=30.30, lng=71.93)
        body = self.get(LIST).content.decode()
        self.assertNotIn('"latitude"', body)
        self.assertNotIn('"longitude"', body)

    def test_search_is_logged_for_analytics(self):
        make_store('Shop')
        self.client.get(reverse(LIST), {'q': 'cola'}, HTTP_USER_AGENT='Mozilla/5.0 (Linux; Android 14) Mobile')
        self.assertEqual(ShopSearchLog.objects.filter(keyword_norm='cola').count(), 1)


class ProductDetailTests(ProductsBase):
    def test_not_live_products_are_json_404(self):
        vp, p = make_store('Shop')
        pen = self.add_product(vp, 'Pending')
        Product.objects.filter(pk=pen.pk).update(approval_status='pending')
        off = self.add_product(vp, 'Off')
        Product.objects.filter(pk=off.pk).update(is_active=False)
        rej = self.add_product(vp, 'Rejected')
        Product.objects.filter(pk=rej.pk).update(approval_status='rejected')
        hidden_vp, hidden = make_store('Hidden Shop', approved=False)
        for pk in (pen.pk, off.pk, rej.pk, hidden.pk, 99999):
            r = self.detail(pk)
            self.assertEqual(r.status_code, 404, pk)
            self.assertFalse(r.json()['ok'])
            self.assertEqual(r.json()['code'], 'not_found')

    def test_bad_token_is_401(self):
        vp, p = make_store('Shop')
        self.assertEqual(self.detail(p.pk, token='garbage').status_code, 401)

    def test_guest_detail_shape(self):
        vp, _ = make_store('Shop', fee=D('60'))
        cat = Category.objects.create(name='Drinks')
        p = self.add_product(vp, 'Cola', category=cat, price='200', stock=50, description='Thanda cola',
                             discount_percentage=D('10'))
        r = self.detail(p.pk)
        self.assertEqual(r.status_code, 200)
        d = r.json()['product']
        self.assertEqual(d['name'], 'Cola')
        self.assertEqual(d['description'], 'Thanda cola')
        self.assertEqual((d['price'], d['old_price'], d['discount_percent']), (180.0, 200.0, 10.0))
        self.assertTrue(d['in_stock'])
        self.assertTrue(d['can_add'])
        self.assertEqual(d['max_qty'], 50)
        self.assertFalse(d['low_stock'])
        self.assertEqual(d['category_name'], 'Drinks')
        self.assertEqual(d['store']['name'], 'Shop')
        self.assertEqual(d['store']['delivery_fee'], 60.0)
        self.assertEqual(d['share_path'], f'/shop/product/{p.pk}/')
        self.assertIn('images', d)
        self.assertIn('related', d)
        self.assertFalse(r.json()['logged_in'])
        self.assertEqual(r['Cache-Control'], 'no-store')

    def test_low_stock_shows_count_only_when_low(self):
        vp, _ = make_store('Shop')
        low = self.add_product(vp, 'Low', stock=3)
        plenty = self.add_product(vp, 'Plenty', stock=500)
        a = self.detail(low.pk).json()['product']
        b = self.detail(plenty.pk).json()['product']
        self.assertTrue(a['low_stock'])
        self.assertIn('3', a['stock_text'])
        self.assertFalse(b['low_stock'])
        self.assertEqual(b['stock_text'], 'Stock mein hai')

    def test_out_of_stock_cannot_be_added(self):
        vp, p = make_store('Shop')
        d = self.detail(p.pk).json()['product']
        self.assertFalse(d['in_stock'])
        self.assertFalse(d['can_add'])
        self.assertEqual(d['max_qty'], 0)
        self.assertEqual(d['stock_text'], 'Abhi available nahi')

    def test_closed_store_blocks_add(self):
        vp, p = make_store('Closed Shop', status='closed')
        Inventory.objects.create(product=p, warehouse=Warehouse.objects.create(name='Main'), stock=5)
        d = self.detail(p.pk).json()['product']
        self.assertFalse(d['store']['is_open'])
        self.assertIn('abhi band hai', d['store']['closed_message'])
        self.assertFalse(d['can_add'])

    def test_serves_area_flag_instead_of_404(self):
        vp, p = make_store('Lahore Shop', city='Lahore')
        Inventory.objects.create(product=p, warehouse=Warehouse.objects.create(name='Main'), stock=5)
        r = self.detail(p.pk, area='Khanewal')
        self.assertEqual(r.status_code, 200)
        d = r.json()['product']
        self.assertFalse(d['serves_area'])
        self.assertFalse(d['can_add'])
        self.assertIn('Khanewal', d['area_message'])
        d2 = self.detail(p.pk, area='Lahore').json()['product']
        self.assertTrue(d2['serves_area'])
        self.assertTrue(d2['can_add'])

    def test_offer_price_and_badge(self):
        vp, _ = make_store('Shop')
        p = self.add_product(vp, 'Cola', price='100', stock=9)
        now = timezone.now()
        ends = now + timedelta(hours=5)
        ProductOffer.objects.create(product=p, profile=vp, discount_percent=D('25'),
                                    starts_at=now - timedelta(hours=1), ends_at=ends)
        d = self.detail(p.pk).json()['product']
        self.assertTrue(d['has_offer'])
        self.assertEqual(d['offer_percent'], 25.0)
        self.assertEqual(d['price'], 75.0)
        self.assertEqual(d['old_price'], 100.0)
        self.assertTrue(d['offer_ends_at'])

    def test_expired_offer_not_applied(self):
        vp, _ = make_store('Shop')
        p = self.add_product(vp, 'Cola', price='100')
        now = timezone.now()
        ProductOffer.objects.create(product=p, profile=vp, discount_percent=D('25'),
                                    starts_at=now - timedelta(days=2), ends_at=now - timedelta(days=1))
        d = self.detail(p.pk).json()['product']
        self.assertFalse(d['has_offer'])
        self.assertEqual(d['price'], 100.0)

    def test_related_same_category_excludes_self_and_hidden(self):
        vp, _ = make_store('Shop')
        cat = Category.objects.create(name='Drinks')
        main = self.add_product(vp, 'Cola', category=cat)
        self.add_product(vp, 'Pepsi', category=cat)
        hidden = self.add_product(vp, 'Hidden Soda', category=cat)
        Product.objects.filter(pk=hidden.pk).update(approval_status='pending')
        self.add_product(vp, 'Biscuit')                                     # doosri category: nahi aana chahiye
        names = [p['name'] for p in self.detail(main.pk).json()['product']['related']]
        self.assertEqual(names, ['Pepsi'])

    def test_recently_viewed_recorded_for_login_customer_only(self):
        vp, p = make_store('Shop')
        self.detail(p.pk)                                                   # guest: koi record nahi
        self.assertEqual(RecentlyViewed.objects.count(), 0)
        self.detail(p.pk, token=self.token())
        self.assertEqual(RecentlyViewed.objects.filter(customer=self.a.customer, product=p).count(), 1)
        self.detail(p.pk, token=self.token())                               # dobara dekhne se duplicate nahi
        self.assertEqual(RecentlyViewed.objects.filter(customer=self.a.customer, product=p).count(), 1)

    def test_recently_viewed_is_per_customer_and_capped(self):
        vp, _ = make_store('Shop')
        tok = self.token()
        for i in range(25):
            self.detail(self.add_product(vp, f'Item {i}').pk, token=tok)
        self.assertEqual(RecentlyViewed.objects.filter(customer=self.a.customer).count(), 20)
        self.assertEqual(RecentlyViewed.objects.filter(customer=self.b.customer).count(), 0)
        names = [p['name'] for p in self.get('customer_api_home', token=tok).json()['recently_viewed']]
        self.assertEqual(names[0], 'Item 24')
        self.assertEqual(self.get('customer_api_home', token=self.token('03002222222')).json()['recently_viewed'], [])

    def test_no_coordinates_leak(self):
        vp, p = make_store('Near Shop', lat=30.30, lng=71.93)
        body = self.detail(p.pk).content.decode()
        self.assertNotIn('"latitude"', body)
        self.assertNotIn('"longitude"', body)


class SuggestTests(ProductsBase):
    def test_short_query_is_empty(self):
        make_store('Shop')
        d = self.get(SUGGEST, q='a').json()
        self.assertTrue(d['ok'])
        self.assertEqual((d['products'], d['stores'], d['categories']), ([], [], []))

    def test_guest_gets_products_stores_categories(self):
        vp, _ = make_store('Cola House')
        cat = Category.objects.create(name='Cola Drinks')
        self.add_product(vp, 'Cola Max', category=cat)
        d = self.get(SUGGEST, q='cola').json()
        self.assertEqual([p['name'] for p in d['products']], ['Cola Max'])
        self.assertEqual([s['name'] for s in d['stores']], ['Cola House'])
        self.assertEqual([c['name'] for c in d['categories']], ['Cola Drinks'])

    def test_hidden_products_never_suggested(self):
        vp, _ = make_store('Shop')
        pen = self.add_product(vp, 'Cola Secret')
        Product.objects.filter(pk=pen.pk).update(approval_status='pending')
        self.assertEqual(self.get(SUGGEST, q='cola').json()['products'], [])

    def test_wrong_spelling_suggests_did_you_mean(self):
        vp, _ = make_store('Shop')
        self.add_product(vp, 'Pepsi')
        d = self.get(SUGGEST, q='Pepsii').json()
        self.assertEqual(d['did_you_mean'], 'pepsi')
        self.assertEqual([p['name'] for p in d['products']], ['Pepsi'])

    def test_bad_token_is_401(self):
        self.assertEqual(self.get(SUGGEST, q='cola', token='garbage').status_code, 401)
