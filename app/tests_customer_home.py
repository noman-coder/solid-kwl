"""
Phase C4 tests: api/customer/home/, areas/, area/, location/.

Run:  python manage.py test app.tests_customer_home -v 2

Cache locmem par override hai (Redis ki zaroorat nahi).
"""
import json
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth.models import User
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone

from app.customer.views_customer_auth import normalize_phone
from app.models import (Coupon, DeliveryArea, Product, RecentlyViewed, ShopBanner, StoreCategory, Vendor,
                        VendorProfile)
from app.tests_customer_api import PASSWORD, make_customer

LOCMEM = {'default': {'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'}}
D = Decimal


def make_store(name, city='Lahore', areas='', status='open', approved=True, with_product=True, lat=None, lng=None,
               fee=D('50')):
    v = Vendor.objects.create(name=name, contact_number=normalize_phone('03007778888'))
    user = User.objects.create_user(f'v_{name}'.replace(' ', '_'), f'{name}@x.com'.replace(' ', '_'), PASSWORD)
    vp = VendorProfile.objects.create(
        vendor=v, user=user, business_name=name, city=city, is_approved=approved, store_status=status,
        delivery_areas=areas, delivery_fee=fee,
        latitude=lat, longitude=lng, location_verified=lat is not None)
    p = None
    if with_product:
        p = Product.objects.create(name=f'{name} item', vendor=v, price=D('100'), is_active=True,
                                   approval_status='approved')
    return vp, p


@override_settings(CACHES=LOCMEM)
class HomeBase(TestCase):
    def setUp(self):
        cache.clear()
        self.a = make_customer('Ali', '03001111111')
        self.b = make_customer('Bilal', '03002222222')

    def token(self, phone='03001111111'):
        r = self.client.post(reverse('customer_api_login'), json.dumps({'phone': phone, 'password': PASSWORD}),
                             content_type='application/json')
        return r.json()['token']

    def get(self, name='customer_api_home', token=None, **params):
        extra = {'HTTP_AUTHORIZATION': f'Bearer {token}'} if token else {}
        return self.client.get(reverse(name), params, **extra)

    def post(self, name, body, token=None):
        extra = {'HTTP_AUTHORIZATION': f'Bearer {token}'} if token else {}
        return self.client.post(reverse(name), json.dumps(body), content_type='application/json', **extra)


class HomeTests(HomeBase):
    def test_guest_can_open_home(self):
        r = self.get()
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'])
        self.assertFalse(d['logged_in'])
        for key in ('banners', 'store_types', 'categories', 'stores', 'offers', 'recently_viewed', 'coupons'):
            self.assertIn(key, d)

    def test_bad_token_is_401(self):
        r = self.get(token='garbage')
        self.assertEqual(r.status_code, 401)
        self.assertEqual(r.json()['code'], 'auth')

    def test_responses_not_cached(self):
        self.assertEqual(self.get()['Cache-Control'], 'no-store')

    def test_only_approved_live_stores(self):
        make_store('Live Store')
        make_store('Pending Store', approved=False)
        make_store('Empty Store', with_product=False)
        names = [s['name'] for s in self.get().json()['stores']]
        self.assertEqual(names, ['Live Store'])

    def test_inactive_or_unapproved_product_store_hidden(self):
        vp, p = make_store('Hidden')
        Product.objects.filter(pk=p.pk).update(approval_status='pending')
        self.assertEqual(self.get().json()['stores'], [])

    def test_area_filter_matches_web_rule(self):
        make_store('Lahore Shop', city='Lahore')
        make_store('Khanewal Shop', city='Khanewal')
        make_store('Gulberg Shop', city='Lahore', areas='Gulberg, DHA')
        d = self.get(area='Khanewal').json()
        self.assertEqual([s['name'] for s in d['stores']], ['Khanewal Shop'])
        self.assertEqual(d['stores_outside_count'], 2)
        self.assertEqual(d['area'], 'Khanewal')
        d = self.get(area='Gulberg (Lahore)').json()
        self.assertIn('Gulberg Shop', [s['name'] for s in d['stores']])
        self.assertNotIn('Khanewal Shop', [s['name'] for s in d['stores']])

    def test_empty_area_param_shows_all(self):
        make_store('A Shop', city='Lahore')
        make_store('B Shop', city='Khanewal')
        d = self.get(area='').json()
        self.assertEqual(len(d['stores']), 2)
        self.assertEqual(d['area'], '')

    def test_logged_in_default_area_from_address(self):
        make_store('Lahore Shop', city='Lahore')
        make_store('Khanewal Shop', city='Khanewal')
        d = self.get(token=self.token()).json()           # make_customer ka default address Lahore
        self.assertEqual(d['area'], 'Lahore')
        self.assertEqual(d['area_source'], 'address')
        self.assertEqual([s['name'] for s in d['stores']], ['Lahore Shop'])
        self.assertTrue(d['logged_in'])

    def test_closed_store_flagged_with_message_and_sorted_last(self):
        make_store('Aaa Closed', status='closed')
        make_store('Zzz Open', status='open')
        stores = self.get().json()['stores']
        self.assertEqual([s['name'] for s in stores], ['Zzz Open', 'Aaa Closed'])
        closed = stores[1]
        self.assertFalse(closed['is_open'])
        self.assertIn('abhi band hai', closed['closed_message'])
        self.assertEqual(stores[0]['closed_message'], '')

    def test_distance_only_with_location_and_no_coordinates_leak(self):
        make_store('Near Shop', lat=30.30, lng=71.93)
        r = self.get(lat='30.31', lng='71.94')
        s = r.json()['stores'][0]
        self.assertTrue(s['distance_text'])
        self.assertTrue(r.json()['has_location'])
        body = r.content.decode()
        self.assertNotIn('"latitude"', body)
        self.assertNotIn('"lng"', body)
        self.assertEqual(self.get().json()['stores'][0]['distance_text'], '')

    def test_bad_coordinates_ignored(self):
        make_store('Shop')
        d = self.get(lat='abc', lng='999').json()
        self.assertFalse(d['has_location'])

    def test_banner_actions(self):
        vp, _ = make_store('Banner Store')
        ShopBanner.objects.create(title='B1', image='shop_banners/b1.jpg', store=vp)
        ShopBanner.objects.create(title='B2', image='shop_banners/b2.jpg', link_url='/shop/stores/?free=1')
        ShopBanner.objects.create(title='B3', image='shop_banners/b3.jpg', link_url='https://example.com/x')
        ShopBanner.objects.create(title='Off', image='shop_banners/b4.jpg', is_active=False)
        ShopBanner.objects.create(title='Old', image='shop_banners/b5.jpg',
                                  ends_on=timezone.localdate() - timedelta(days=2))
        banners = self.get().json()['banners']
        self.assertEqual([b['title'] for b in banners], ['B1', 'B2', 'B3'])
        self.assertEqual(banners[0]['action'], {'type': 'store', 'store_id': vp.pk})
        self.assertEqual(banners[1]['action'], {'type': 'stores', 'params': {'free': '1'}})
        self.assertEqual(banners[2]['action']['type'], 'url')

    def test_store_types_counted(self):
        t = StoreCategory.objects.create(name='Grocery', icon='🛒')
        vp, _ = make_store('G Shop')
        vp.store_category = t
        vp.save()
        StoreCategory.objects.create(name='Empty Type')
        types = self.get().json()['store_types']
        self.assertEqual([(x['name'], x['count']) for x in types], [('Grocery', 1)])

    def test_recently_viewed_own_only_and_area_filtered(self):
        vp, p = make_store('Lahore Shop', city='Lahore')
        vp2, p2 = make_store('Khanewal Shop', city='Khanewal')
        RecentlyViewed.objects.create(customer=self.a.customer, product=p)
        RecentlyViewed.objects.create(customer=self.a.customer, product=p2)
        RecentlyViewed.objects.create(customer=self.b.customer, product=p)
        d = self.get(token=self.token(), area='Lahore').json()
        self.assertEqual([x['id'] for x in d['recently_viewed']], [p.pk])
        # guest ko kuch nahi
        self.assertEqual(self.get(area='Lahore').json()['recently_viewed'], [])
        # doosre customer ka view ka record A ko na dikhe
        d_b = self.get(token=self.token('03002222222'), area='Khanewal').json()
        self.assertEqual(d_b['recently_viewed'], [])

    def test_recently_viewed_hides_inactive_product(self):
        vp, p = make_store('Shop')
        RecentlyViewed.objects.create(customer=self.a.customer, product=p)
        Product.objects.filter(pk=p.pk).update(is_active=False)
        self.assertEqual(self.get(token=self.token(), area='').json()['recently_viewed'], [])

    def test_coupons_strip_shows_live_only(self):
        now = timezone.now()
        Coupon.objects.create(code='LIVE10', discount_type='percent', value=D('10'), title='10% off')
        Coupon.objects.create(code='OLD', discount_type='percent', value=D('10'), valid_until=now - timedelta(days=1))
        Coupon.objects.create(code='PAUSED', discount_type='percent', value=D('10'), is_active=False)
        codes = [c['code'] for c in self.get().json()['coupons']]
        self.assertEqual(codes, ['LIVE10'])

    def test_one_section_failing_does_not_break_home(self):
        from unittest import mock
        make_store('Shop')
        with mock.patch('app.customer.views_customer_home._banners_section', side_effect=RuntimeError('x')):
            r = self.get()
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['banners'], [])
        self.assertEqual(len(r.json()['stores']), 1)

    def test_post_not_allowed_on_home(self):
        self.assertEqual(self.post('customer_api_home', {}).status_code, 405)


class AreaTests(HomeBase):
    def test_areas_grouped_by_city(self):
        DeliveryArea.objects.create(city='Lahore', name='Gulberg')
        DeliveryArea.objects.create(city='Lahore', name='DHA')
        DeliveryArea.objects.create(city='Multan', name='Cantt', is_active=False)
        groups = self.get('customer_api_areas').json()['groups']
        lahore = [g for g in groups if g['city'] == 'Lahore'][0]
        self.assertEqual({a['label'] for a in lahore['areas']}, {'Gulberg (Lahore)', 'DHA (Lahore)'})
        self.assertFalse([a for g in groups for a in g['areas'] if a['name'] == 'Cantt'])

    def test_area_set_known_and_count(self):
        DeliveryArea.objects.create(city='Lahore', name='Gulberg')
        make_store('Gulberg Shop', city='Lahore', areas='Gulberg')
        make_store('Other Shop', city='Khanewal')
        d = self.post('customer_api_area_set', {'area': '  Gulberg   (Lahore) '}).json()
        self.assertEqual(d['area'], 'Gulberg (Lahore)')          # extra spaces saaf
        self.assertTrue(d['known'])
        self.assertEqual(d['stores_count'], 1)

    def test_area_set_unknown_still_accepted_like_web(self):
        d = self.post('customer_api_area_set', {'area': 'Kisi Gaon'}).json()
        self.assertTrue(d['ok'])
        self.assertFalse(d['known'])

    def test_area_set_empty_clears(self):
        d = self.post('customer_api_area_set', {'area': ''}).json()
        self.assertTrue(d['ok'])
        self.assertEqual(d['area'], '')

    def test_area_length_capped(self):
        d = self.post('customer_api_area_set', {'area': 'x' * 300}).json()
        self.assertEqual(len(d['area']), 100)

    def test_area_non_string_ignored(self):
        d = self.post('customer_api_area_set', {'area': ['a']}).json()
        self.assertEqual(d['area'], '')


class LocationTests(HomeBase):
    def test_location_saved_for_logged_in_and_suggests_city(self):
        make_store('Khanewal Shop', city='Khanewal', lat=30.3017, lng=71.9321)
        tok = self.token()
        d = self.post('customer_api_location', {'lat': 30.30, 'lng': 71.93}, token=tok).json()
        self.assertTrue(d['saved'])
        self.assertEqual(d['suggested_area'], 'Khanewal')
        self.assertEqual(d['nearest_store']['name'], 'Khanewal Shop')
        self.assertNotIn('lat', d)
        self.a.refresh_from_db()
        self.assertAlmostEqual(self.a.latitude, 30.30, places=3)

    def test_location_guest_not_saved_but_suggests(self):
        make_store('Khanewal Shop', city='Khanewal', lat=30.3017, lng=71.9321)
        d = self.post('customer_api_location', {'lat': 30.30, 'lng': 71.93}).json()
        self.assertFalse(d['saved'])
        self.assertEqual(d['suggested_area'], 'Khanewal')

    def test_far_location_no_suggestion(self):
        make_store('Khanewal Shop', city='Khanewal', lat=30.3017, lng=71.9321)
        d = self.post('customer_api_location', {'lat': 24.86, 'lng': 67.00}).json()     # Karachi
        self.assertEqual(d['suggested_area'], '')
        self.assertTrue(d['message'])

    def test_bad_coordinates_rejected(self):
        for body in ({'lat': 'x', 'lng': 1}, {'lat': 0, 'lng': 0}, {'lat': 95, 'lng': 10}, {}):
            r = self.post('customer_api_location', body)
            self.assertEqual(r.status_code, 400, body)
            self.assertFalse(r.json()['ok'])

    def test_delete_clears_only_own_location(self):
        tok_a = self.token()
        self.post('customer_api_location', {'lat': 30.30, 'lng': 71.93}, token=tok_a)
        tok_b = self.token('03002222222')
        self.post('customer_api_location', {'lat': 31.50, 'lng': 74.30}, token=tok_b)
        r = self.client.delete(reverse('customer_api_location'), HTTP_AUTHORIZATION=f'Bearer {tok_a}')
        self.assertEqual(r.status_code, 200)
        self.a.refresh_from_db()
        self.b.refresh_from_db()
        self.assertIsNone(self.a.latitude)
        self.assertIsNotNone(self.b.latitude)

    def test_saved_location_used_for_distance_in_home(self):
        make_store('Near Shop', lat=30.3017, lng=71.9321)
        tok = self.token()
        self.post('customer_api_location', {'lat': 30.30, 'lng': 71.93}, token=tok)
        s = self.get(token=tok, area='').json()['stores'][0]
        self.assertTrue(s['distance_text'])

    def test_get_not_allowed_on_location(self):
        self.assertEqual(self.get('customer_api_location').status_code, 405)
