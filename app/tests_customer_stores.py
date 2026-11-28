"""
Phase C5 tests: api/customer/stores/ (list, filters, sort, page) aur api/customer/stores/<id>/ (store detail).

Run:  python manage.py test app.tests_customer_stores -v 2

Cache locmem par override hai (Redis ki zaroorat nahi). Koi migration nahi.
"""
from datetime import time, timedelta
from decimal import Decimal
from unittest import mock

from django.urls import reverse
from django.utils import timezone

from app.models import (Category, Coupon, FavoriteStore, Inventory, Product, StoreCategory, VendorProfile,
                        Warehouse)
from app.tests_customer_home import HomeBase, make_store

D = Decimal
LIST = 'customer_api_stores'
DETAIL = 'customer_api_store_detail'


class StoresBase(HomeBase):
    def names(self, **params):
        return [s['name'] for s in self.get(LIST, **params).json()['stores']]

    def detail(self, pk, token=None, **params):
        extra = {'HTTP_AUTHORIZATION': f'Bearer {token}'} if token else {}
        return self.client.get(reverse(DETAIL, args=[pk]), params, **extra)

    def add_product(self, vp, name, category=None, price='100', **kw):
        return Product.objects.create(name=name, vendor=vp.vendor, price=D(price), is_active=True,
                                      approval_status='approved', category=category, **kw)


class StoreListTests(StoresBase):
    def test_guest_can_open_list_and_shape(self):
        make_store('Shop A')
        r = self.get(LIST)
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'])
        for key in ('stores', 'sorts', 'filters', 'store_types', 'categories', 'page', 'total', 'has_more',
                    'outside_count', 'area'):
            self.assertIn(key, d)
        s = d['stores'][0]
        for key in ('id', 'name', 'status', 'is_open', 'delivery_fee', 'free_delivery', 'min_order', 'is_new',
                    'product_count', 'tags'):
            self.assertIn(key, s)
        self.assertEqual(r['Cache-Control'], 'no-store')

    def test_bad_token_is_401(self):
        self.assertEqual(self.get(LIST, token='garbage').status_code, 401)

    def test_post_not_allowed(self):
        self.assertEqual(self.client.post(reverse(LIST)).status_code, 405)

    def test_only_approved_live_stores(self):
        make_store('Live Store')
        make_store('Pending Store', approved=False)
        make_store('Empty Store', with_product=False)
        self.assertEqual(self.names(), ['Live Store'])

    def test_area_filter_hides_outside_stores(self):
        make_store('Lahore Shop', city='Lahore')
        make_store('Khanewal Shop', city='Khanewal')
        d = self.get(LIST, area='Khanewal').json()
        self.assertEqual([s['name'] for s in d['stores']], ['Khanewal Shop'])
        self.assertEqual(d['outside_count'], 1)
        # khali area = sab
        self.assertEqual(len(self.get(LIST, area='').json()['stores']), 2)

    def test_logged_in_default_area_from_address(self):
        make_store('Lahore Shop', city='Lahore')
        make_store('Khanewal Shop', city='Khanewal')
        d = self.get(LIST, token=self.token()).json()
        self.assertEqual(d['area'], 'Lahore')
        self.assertEqual([s['name'] for s in d['stores']], ['Lahore Shop'])

    def test_search_by_store_name_city_and_product(self):
        make_store('Burger Hub', city='Lahore')
        vp, _ = make_store('Green Mart', city='Khanewal')
        self.add_product(vp, 'Basmati Rice')
        self.assertEqual(self.names(q='burger'), ['Burger Hub'])
        self.assertEqual(self.names(q='khanewal'), ['Green Mart'])
        self.assertEqual(self.names(q='basmati'), ['Green Mart'])
        self.assertEqual(self.names(q='nothingmatches'), [])

    def test_search_inactive_product_does_not_match(self):
        vp, _ = make_store('Green Mart')
        p = self.add_product(vp, 'Secret Item')
        Product.objects.filter(pk=p.pk).update(is_active=False)
        self.assertEqual(self.names(q='secret'), [])

    def test_open_filter(self):
        make_store('Open Shop', status='open')
        make_store('Busy Shop', status='busy')
        make_store('Closed Shop', status='closed')
        self.assertEqual(sorted(self.names(open='1')), ['Busy Shop', 'Open Shop'])
        self.assertEqual(len(self.names()), 3)

    def test_free_delivery_filter(self):
        make_store('Free Shop', fee=D('0'))
        make_store('Paid Shop', fee=D('80'))
        self.assertEqual(self.names(free='1'), ['Free Shop'])

    def test_top_rated_filter(self):
        a, _ = make_store('Great Shop')
        b, _ = make_store('Poor Shop')
        make_store('Unrated Shop')
        ratings = {a.vendor_id: {'avg': 4.6, 'count': 10}, b.vendor_id: {'avg': 3.1, 'count': 4}}
        with mock.patch('app.customer.views_customer_stores.store_rating_map', return_value=ratings):
            self.assertEqual(self.names(top='1'), ['Great Shop'])
            s = self.get(LIST, sort='rating').json()['stores']
            self.assertEqual([x['name'] for x in s][:2], ['Great Shop', 'Poor Shop'])
            self.assertEqual(s[0]['rating'], 4.6)

    def test_new_filter(self):
        old, _ = make_store('Old Shop')
        new, _ = make_store('New Shop')
        VendorProfile.objects.filter(pk=old.pk).update(approved_at=timezone.now() - timedelta(days=90))
        VendorProfile.objects.filter(pk=new.pk).update(approved_at=timezone.now() - timedelta(days=2))
        self.assertEqual(self.names(new='1'), ['New Shop'])

    def test_store_type_and_category_filters(self):
        t = StoreCategory.objects.create(name='Grocery', icon='x')
        g, _ = make_store('Grocer')
        VendorProfile.objects.filter(pk=g.pk).update(store_category=t)
        r, _ = make_store('Restaurant')
        cat = Category.objects.create(name='Drinks')
        self.add_product(r, 'Cola', category=cat)
        d = self.get(LIST, type=str(t.id)).json()
        self.assertEqual([s['name'] for s in d['stores']], ['Grocer'])
        self.assertEqual(d['filters']['type'], t.id)
        self.assertEqual(self.names(category=str(cat.id)), ['Restaurant'])
        self.assertIn('Drinks', [c['name'] for c in self.get(LIST).json()['categories']])
        # ghalat type id ignore
        self.assertEqual(len(self.names(type='99999')), 2)

    def test_closed_store_last_with_message(self):
        make_store('Aaa Closed', status='closed')
        make_store('Zzz Open', status='open')
        stores = self.get(LIST).json()['stores']
        self.assertEqual([s['name'] for s in stores], ['Zzz Open', 'Aaa Closed'])
        self.assertFalse(stores[1]['is_open'])
        self.assertIn('abhi band hai', stores[1]['closed_message'])

    def test_sort_fee_and_fastest(self):
        a, _ = make_store('A Shop', fee=D('90'))
        b, _ = make_store('B Shop', fee=D('10'))
        VendorProfile.objects.filter(pk=a.pk).update(delivery_time_min=10, delivery_time_max=15)
        VendorProfile.objects.filter(pk=b.pk).update(delivery_time_min=40, delivery_time_max=55)
        self.assertEqual(self.names(sort='fee'), ['B Shop', 'A Shop'])
        self.assertEqual(self.names(sort='fastest'), ['A Shop', 'B Shop'])

    def test_nearest_needs_location_and_never_leaks_coordinates(self):
        make_store('Far Shop', lat=31.50, lng=74.30)
        make_store('Near Shop', lat=30.30, lng=71.93)
        r = self.get(LIST, sort='nearest', lat='30.31', lng='71.94')
        d = r.json()
        self.assertEqual(d['sort'], 'nearest')
        self.assertEqual([s['name'] for s in d['stores']], ['Near Shop', 'Far Shop'])
        self.assertTrue(d['stores'][0]['distance_text'])
        self.assertNotIn('"latitude"', r.content.decode())
        # location ke baghair 'nearest' recommended ban jata hai
        d2 = self.get(LIST, sort='nearest').json()
        self.assertEqual(d2['sort'], 'recommended')
        self.assertNotIn('nearest', [x['key'] for x in d2['sorts']])

    def test_bad_sort_and_page_params_are_safe(self):
        make_store('Shop')
        d = self.get(LIST, sort='<script>', page='abc').json()
        self.assertEqual(d['sort'], 'recommended')
        self.assertEqual(d['page'], 1)
        self.assertEqual(len(d['stores']), 1)

    def test_pagination(self):
        for i in range(25):
            make_store(f'Shop {i:02d}')
        p1 = self.get(LIST).json()
        self.assertEqual((len(p1['stores']), p1['total'], p1['has_more']), (20, 25, True))
        p2 = self.get(LIST, page='2').json()
        self.assertEqual((len(p2['stores']), p2['has_more']), (5, False))
        ids = {s['id'] for s in p1['stores']} | {s['id'] for s in p2['stores']}
        self.assertEqual(len(ids), 25)                       # koi store dohraya nahi gaya
        self.assertEqual(self.get(LIST, page='9').json()['stores'], [])

    def test_card_tags_and_product_count(self):
        vp, _ = make_store('Shop')
        for cname in ('Zeta', 'Alpha', 'Mid', 'Beta'):
            self.add_product(vp, f'{cname} item', category=Category.objects.create(name=cname))
        s = self.get(LIST).json()['stores'][0]
        self.assertEqual(s['product_count'], 5)
        self.assertEqual(s['tags'], ['Alpha', 'Beta', 'Mid'])


class StoreDetailTests(StoresBase):
    def test_unknown_unapproved_store_is_json_404(self):
        vp, _ = make_store('Pending', approved=False)
        for pk in (vp.pk, 99999):
            r = self.detail(pk)
            self.assertEqual(r.status_code, 404)
            self.assertFalse(r.json()['ok'])
            self.assertEqual(r.json()['code'], 'not_found')

    def test_bad_token_is_401(self):
        vp, _ = make_store('Shop')
        self.assertEqual(self.detail(vp.pk, token='garbage').status_code, 401)

    def test_guest_detail_info(self):
        vp, _ = make_store('Shop', city='Lahore', fee=D('60'))
        VendorProfile.objects.filter(pk=vp.pk).update(
            store_description='Taza khana', min_order_amount=D('300'), delivery_time_min=20, delivery_time_max=35,
            opens_at=time(9, 0), closes_at=time(23, 30))
        r = self.detail(vp.pk)
        self.assertEqual(r.status_code, 200)
        d = r.json()
        st = d['store']
        self.assertEqual(st['name'], 'Shop')
        self.assertEqual(st['description'], 'Taza khana')
        self.assertEqual(st['delivery_fee'], 60.0)
        self.assertFalse(st['free_delivery'])
        self.assertEqual(st['min_order'], 300.0)
        self.assertEqual((st['delivery_time_min'], st['delivery_time_max']), (20, 35))
        self.assertEqual(st['hours_text'], '9:00 AM - 11:30 PM')
        self.assertFalse(st['is_favorite'])
        self.assertEqual(st['share_path'], f'/shop/stores/{vp.pk}/')
        self.assertIn('delivery', d)
        self.assertEqual(len(st['rating_bars']), 5)
        self.assertFalse(d['logged_in'])
        self.assertEqual(r['Cache-Control'], 'no-store')

    def test_no_coordinates_leak_and_distance_text(self):
        vp, _ = make_store('Near Shop', lat=30.30, lng=71.93)
        r = self.detail(vp.pk, lat='30.31', lng='71.94')
        self.assertTrue(r.json()['store']['distance_text'])
        body = r.content.decode()
        self.assertNotIn('"latitude"', body)
        self.assertNotIn('"longitude"', body)

    def test_products_only_live_and_with_menu(self):
        vp, first = make_store('Shop')
        cat = Category.objects.create(name='Drinks')
        self.add_product(vp, 'Cola', category=cat)
        pending = self.add_product(vp, 'Pending Item', category=cat)
        Product.objects.filter(pk=pending.pk).update(approval_status='pending')
        off = self.add_product(vp, 'Off Item')
        Product.objects.filter(pk=off.pk).update(is_active=False)
        rejected = self.add_product(vp, 'Rejected Item')
        Product.objects.filter(pk=rejected.pk).update(approval_status='rejected')
        other_vp, _ = make_store('Other Shop')                        # doosre store ka product is mein na aaye
        d = self.detail(vp.pk).json()
        names = sorted(p['name'] for p in d['products'])
        self.assertEqual(names, ['Cola', 'Shop item'])
        self.assertEqual(d['total'], 2)
        menu = {m['name']: m['count'] for m in d['menu']}
        self.assertEqual(menu, {'Drinks': 1, 'Doosra': 1})
        self.assertEqual(d['menu'][-1]['id'], 0)                      # bina category wale aakhir mein
        self.assertEqual(d['menu_total'], 2)

    def test_category_and_search_filters(self):
        vp, _ = make_store('Shop')
        drinks = Category.objects.create(name='Drinks')
        self.add_product(vp, 'Cola', category=drinks)
        self.add_product(vp, 'Pepsi', category=drinks, description='thanda')
        d = self.detail(vp.pk, category=str(drinks.id)).json()
        self.assertEqual(sorted(p['name'] for p in d['products']), ['Cola', 'Pepsi'])
        self.assertEqual([p['name'] for p in self.detail(vp.pk, q='thanda').json()['products']], ['Pepsi'])
        self.assertEqual([p['name'] for p in self.detail(vp.pk, category='0').json()['products']], ['Shop item'])

    def test_product_pagination(self):
        vp, _ = make_store('Shop')
        for i in range(30):
            self.add_product(vp, f'Item {i:02d}')
        d1 = self.detail(vp.pk).json()
        self.assertEqual((len(d1['products']), d1['total'], d1['has_more']), (24, 31, True))
        d2 = self.detail(vp.pk, page='2').json()
        self.assertEqual((len(d2['products']), d2['has_more']), (7, False))
        ids = {p['id'] for p in d1['products']} | {p['id'] for p in d2['products']}
        self.assertEqual(len(ids), 31)

    def test_closed_store_blocks_add(self):
        vp, _ = make_store('Closed Shop', status='closed')
        d = self.detail(vp.pk).json()
        self.assertFalse(d['store']['is_open'])
        self.assertIn('abhi band hai', d['store']['closed_message'])
        self.assertTrue(d['products'])
        self.assertTrue(all(p['can_add'] is False for p in d['products']))

    def test_outside_hours_store_is_closed(self):
        vp, _ = make_store('Night Shop')
        now = timezone.localtime()
        later = (now + timedelta(hours=2)).time().replace(microsecond=0)
        much_later = (now + timedelta(hours=3)).time().replace(microsecond=0)
        if later < now.time().replace(microsecond=0):       # raat 12 ke paar: test ka dobara intezam
            self.skipTest('midnight ke qareeb waqt')
        VendorProfile.objects.filter(pk=vp.pk).update(opens_at=later, closes_at=much_later)
        self.assertFalse(self.detail(vp.pk).json()['store']['is_open'])

    def test_out_of_stock_cannot_be_added(self):
        vp, p = make_store('Shop')                                   # koi inventory nahi = stock 0
        d = self.detail(vp.pk).json()
        item = d['products'][0]
        self.assertFalse(item['in_stock'])
        self.assertFalse(item['can_add'])
        self.assertEqual(item['stock'], 0)

    def test_in_stock_open_store_can_add(self):
        vp, p = make_store('Shop')
        Inventory.objects.create(product=p, warehouse=Warehouse.objects.create(name='Main'), stock=5)
        item = self.detail(vp.pk).json()['products'][0]
        self.assertTrue(item['in_stock'])
        self.assertTrue(item['can_add'])
        self.assertEqual(item['stock'], 5)

    def test_serves_area_flag_instead_of_404(self):
        vp, _ = make_store('Lahore Shop', city='Lahore')
        d = self.detail(vp.pk, area='Khanewal').json()
        self.assertEqual(self.detail(vp.pk, area='Khanewal').status_code, 200)
        self.assertFalse(d['store']['serves_area'])
        self.assertIn('Khanewal', d['store']['area_message'])
        d2 = self.detail(vp.pk, area='Lahore').json()
        self.assertTrue(d2['store']['serves_area'])
        self.assertEqual(d2['store']['area_message'], '')

    def test_favorite_flag_is_per_customer(self):
        vp, _ = make_store('Shop')
        FavoriteStore.objects.create(customer=self.a.customer, store=vp)
        self.assertTrue(self.detail(vp.pk, token=self.token()).json()['store']['is_favorite'])
        self.assertFalse(self.detail(vp.pk, token=self.token('03002222222')).json()['store']['is_favorite'])
        self.assertFalse(self.detail(vp.pk).json()['store']['is_favorite'])

    def test_store_coupons(self):
        vp, _ = make_store('Shop')
        other, _ = make_store('Other')
        Coupon.objects.create(code='SHOP10', discount_type='percent', value=D('10'), vendor=vp.vendor)
        Coupon.objects.create(code='OTHER5', discount_type='percent', value=D('5'), vendor=other.vendor)
        Coupon.objects.create(code='ALL20', discount_type='percent', value=D('20'))
        codes = sorted(c['code'] for c in self.detail(vp.pk).json()['store']['coupons'])
        self.assertEqual(codes, ['ALL20', 'SHOP10'])
