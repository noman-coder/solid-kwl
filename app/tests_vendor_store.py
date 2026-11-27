"""
Phase V15 tests: vendor store settings API (GET, section-wise save: basic / timing / delivery / branding)
aur location verify (blue tick) - validation, ownership, unapproved, web ke saath mel.

Run:  python manage.py test app.tests_vendor_store
Asli FCM / Cloudinary ko koi call nahi jati (push mock, MEDIA_ROOT temp folder).
"""
import shutil
import tempfile
from datetime import time as dtime
from decimal import Decimal
from unittest import mock

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from django.urls import reverse

from app.models import DeliveryArea, StoreCategory, VendorProfile
from app.tests_vendor_api import make_vendor
from app.tests_vendor_product_form import png_file
from app.tests_vendor_push import VendorPushBase


class StoreBase(VendorPushBase):
    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp()
        o = override_settings(MEDIA_ROOT=self.tmp)
        o.enable()
        self.addCleanup(o.disable)
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def get(self, profile=None):
        return self.client.get(reverse('vendor_api_store'), **self.bearer(profile or self.a))

    def save(self, section, profile=None, **fields):
        return self.post_json('vendor_api_store', dict(fields, section=section), profile or self.a)

    def fresh(self, profile=None):
        return VendorProfile.objects.get(pk=(profile or self.a).pk)

    def locate(self, data, profile=None):
        return self.post_json('vendor_api_store_location', data, profile or self.a)


class AuthTests(StoreBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_store')).status_code, 401)
        self.assertEqual(self.client.post(reverse('vendor_api_store_location'), '{}',
                                          content_type='application/json').status_code, 401)

    def test_unapproved_vendor_blocked(self):
        pending = make_vendor('Naya Store', '03005555555', approved=False)
        r = self.get(pending)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()['code'], 'pending')
        self.assertEqual(self.save('basic', pending, status='closed').status_code, 403)
        self.assertEqual(self.locate({'lat': 30.3, 'lng': 71.9, 'consent': True}, pending).status_code, 403)

    def test_wrong_method(self):
        self.assertEqual(self.client.put(reverse('vendor_api_store'), '{}', content_type='application/json',
                                         **self.bearer(self.a)).status_code, 405)
        self.assertEqual(self.client.get(reverse('vendor_api_store_location'), **self.bearer(self.a)).status_code, 405)


class GetTests(StoreBase):
    def test_defaults(self):
        d = self.get().json()
        self.assertTrue(d['ok'])
        st = d['settings']
        self.assertEqual(st['name'], 'Ali Store')
        self.assertEqual(st['status'], 'open')
        self.assertEqual(st['opens_at'], '')
        self.assertEqual(st['delivery_time_min'], 30)
        self.assertEqual(st['delivery_time_max'], 45)
        self.assertEqual(st['areas'], [])
        self.assertIsNone(st['logo'])
        self.assertFalse(st['location']['verified'])
        self.assertEqual(d['limits']['description_max'], 1000)
        self.assertEqual(d['limits']['minutes_max'], 600)

    def test_categories_only_active(self):
        StoreCategory.objects.create(name='Grocery', is_active=True)
        StoreCategory.objects.create(name='Purani', is_active=False)
        names = [c['name'] for c in self.get().json()['categories']]
        self.assertIn('Grocery', names)
        self.assertNotIn('Purani', names)

    def test_area_groups_selected_and_extra(self):
        DeliveryArea.objects.create(city='Khanewal', name='Mian Channu')
        DeliveryArea.objects.create(city='Khanewal', name='Jahanian')
        VendorProfile.objects.filter(pk=self.a.pk).update(delivery_areas='Jahanian (Khanewal), Mera Gaon')
        st = self.get().json()['settings']
        sel = {a['label']: a['selected'] for g in st['area_groups'] for a in g['areas']}
        self.assertTrue(sel['Jahanian (Khanewal)'])
        self.assertFalse(sel['Mian Channu (Khanewal)'])
        self.assertEqual(st['areas_extra'], 'Mera Gaon')

    def test_only_own_store(self):
        VendorProfile.objects.filter(pk=self.b.pk).update(store_description='Bilal ki dukaan')
        self.assertEqual(self.get(self.a).json()['settings']['description'], '')
        self.assertEqual(self.get(self.b).json()['settings']['description'], 'Bilal ki dukaan')


class BasicTests(StoreBase):
    def test_save_basic(self):
        cat = StoreCategory.objects.create(name='Restaurant', is_active=True)
        r = self.save('basic', status='busy', description='  Taza khana  ', store_category=cat.pk)
        self.assertEqual(r.status_code, 200)
        p = self.fresh()
        self.assertEqual((p.store_status, p.store_description, p.store_category_id), ('busy', 'Taza khana', cat.pk))
        d = r.json()
        self.assertEqual(d['settings']['category']['name'], 'Restaurant')
        self.assertEqual(d['store']['status'], 'busy')
        self.assertTrue(d['store']['switch_on'])

    def test_closed_makes_store_not_open(self):
        d = self.save('basic', status='closed').json()
        self.assertFalse(d['store']['is_open'])
        self.assertFalse(d['vendor']['is_open'])

    def test_bad_status_rejected(self):
        r = self.save('basic', status='lunch')
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'validation')
        self.assertEqual(self.fresh().store_status, 'open')

    def test_description_too_long(self):
        r = self.save('basic', description='x' * 1001)
        self.assertEqual(r.status_code, 400)
        self.assertEqual(self.fresh().store_description, '')
        self.assertEqual(self.save('basic', description='x' * 1000).status_code, 200)

    def test_inactive_or_unknown_category_rejected(self):
        old = StoreCategory.objects.create(name='Band', is_active=False)
        self.assertEqual(self.save('basic', store_category=old.pk).status_code, 400)
        self.assertEqual(self.save('basic', store_category=9999).status_code, 400)
        self.assertEqual(self.save('basic', store_category='abc').status_code, 400)

    def test_empty_category_clears(self):
        cat = StoreCategory.objects.create(name='Grocery', is_active=True)
        self.save('basic', store_category=cat.pk)
        self.assertEqual(self.save('basic', store_category='').status_code, 200)
        self.assertIsNone(self.fresh().store_category_id)

    def test_missing_fields_dont_change(self):
        self.save('basic', status='busy', description='Pehli')
        self.save('basic', description='Doosri')
        p = self.fresh()
        self.assertEqual((p.store_status, p.store_description), ('busy', 'Doosri'))

    def test_unknown_section(self):
        self.assertEqual(self.save('colour').status_code, 400)
        self.assertEqual(self.post_json('vendor_api_store', {}, self.a).status_code, 400)

    def test_does_not_touch_other_vendor(self):
        self.save('basic', status='closed')
        self.assertEqual(self.fresh(self.b).store_status, 'open')


class TimingTests(StoreBase):
    def test_save_timing(self):
        r = self.save('timing', opens_at='09:00', closes_at='22:30')
        self.assertEqual(r.status_code, 200)
        p = self.fresh()
        self.assertEqual((p.opens_at, p.closes_at), (dtime(9, 0), dtime(22, 30)))
        self.assertEqual(r.json()['settings']['opens_at'], '09:00')
        self.assertEqual(r.json()['store']['closes_at'], '22:30')

    def test_overnight_time_allowed(self):
        self.assertEqual(self.save('timing', opens_at='18:00', closes_at='02:00').status_code, 200)

    def test_both_empty_means_always_open(self):
        self.save('timing', opens_at='09:00', closes_at='22:00')
        r = self.save('timing', opens_at='', closes_at='')
        self.assertEqual(r.status_code, 200)
        p = self.fresh()
        self.assertIsNone(p.opens_at)
        self.assertIsNone(p.closes_at)

    def test_only_one_time_rejected(self):
        r = self.save('timing', opens_at='09:00', closes_at='')
        self.assertEqual(r.status_code, 400)
        self.assertIsNone(self.fresh().opens_at)

    def test_bad_time_rejected(self):
        for bad in ('25:00', 'abc', '9', '12:75'):
            self.assertEqual(self.save('timing', opens_at=bad, closes_at='22:00').status_code, 400, bad)
        self.assertEqual(self.save('timing', opens_at=[1], closes_at='22:00').status_code, 400)

    def test_outside_hours_store_not_open(self):
        with mock.patch('django.utils.timezone.localtime') as lt:
            lt.return_value.time.return_value = dtime(3, 0)
            d = self.save('timing', opens_at='09:00', closes_at='22:00').json()
        self.assertFalse(d['store']['within_hours'])
        self.assertFalse(d['store']['is_open'])


class DeliveryTests(StoreBase):
    def test_save_delivery(self):
        r = self.save('delivery', min_order_amount='300', delivery_fee=50.5,
                      delivery_time_min=20, delivery_time_max=40)
        self.assertEqual(r.status_code, 200)
        p = self.fresh()
        self.assertEqual(p.min_order_amount, Decimal('300.00'))
        self.assertEqual(p.delivery_fee, Decimal('50.50'))
        self.assertEqual((p.delivery_time_min, p.delivery_time_max), (20, 40))
        self.assertEqual(r.json()['settings']['delivery_fee'], 50.5)

    def test_bad_money_rejected(self):
        for bad in ('-5', 'abc', '100000'):
            r = self.save('delivery', min_order_amount=bad)
            self.assertEqual(r.status_code, 400, bad)
        self.assertEqual(self.save('delivery', delivery_fee=True).status_code, 400)
        self.assertEqual(self.fresh().min_order_amount, Decimal('0'))

    def test_bad_minutes_rejected(self):
        for lo, hi in ((4, 40), (20, 601), (50, 40)):
            r = self.save('delivery', delivery_time_min=lo, delivery_time_max=hi)
            self.assertEqual(r.status_code, 400, (lo, hi))
        self.assertEqual(self.save('delivery', delivery_time_min='abc').status_code, 400)
        p = self.fresh()
        self.assertEqual((p.delivery_time_min, p.delivery_time_max), (30, 45))

    def test_min_above_stored_max_rejected(self):
        # sirf min bheja, par maujooda max (45) se bara
        self.assertEqual(self.save('delivery', delivery_time_min=60).status_code, 400)

    def test_error_saves_nothing(self):
        r = self.save('delivery', min_order_amount='300', delivery_fee='abc')
        self.assertEqual(r.status_code, 400)
        self.assertEqual(self.fresh().min_order_amount, Decimal('0'))

    def test_areas_pick_from_admin_list_and_extra(self):
        DeliveryArea.objects.create(city='Khanewal', name='Jahanian')
        r = self.save('delivery', areas=['Jahanian (Khanewal)', 'Nakli Area (Lahore)'], areas_extra='Mera Gaon, Dusra Gaon')
        self.assertEqual(r.status_code, 200)
        # admin list mein na hone wala "picked" area chupke hat jata hai (web jaisa); likha hua extra rehta hai
        self.assertEqual(self.fresh().delivery_areas, 'Jahanian (Khanewal), Mera Gaon, Dusra Gaon')
        st = r.json()['settings']
        self.assertEqual(st['areas_extra'], 'Mera Gaon, Dusra Gaon')

    def test_areas_cleared(self):
        self.save('delivery', areas_extra='Mera Gaon')
        self.assertEqual(self.save('delivery', areas=[], areas_extra='').status_code, 200)
        self.assertEqual(self.fresh().delivery_areas, '')

    def test_too_many_areas(self):
        extra = ', '.join(f'Gaon{i}' for i in range(VendorProfile.MAX_AREAS + 1))
        self.assertEqual(self.save('delivery', areas_extra=extra).status_code, 400)
        self.assertEqual(self.fresh().delivery_areas, '')

    def test_bad_areas_type(self):
        self.assertEqual(self.save('delivery', areas='Jahanian').status_code, 400)
        self.assertEqual(self.save('delivery', areas=[1, 2]).status_code, 400)

    def test_areas_untouched_when_not_sent(self):
        self.save('delivery', areas_extra='Mera Gaon')
        self.save('delivery', delivery_fee='10')
        self.assertEqual(self.fresh().delivery_areas, 'Mera Gaon')


class BrandingTests(StoreBase):
    def upload(self, **files):
        data = dict(section='branding', **files)
        return self.client.post(reverse('vendor_api_store'), data, **self.bearer(self.a))

    def test_upload_logo_and_cover(self):
        r = self.upload(logo=png_file('logo.png'), cover_image=png_file('cover.png'))
        self.assertEqual(r.status_code, 200, r.content)
        p = self.fresh()
        self.assertTrue(p.logo)
        self.assertTrue(p.cover_image)
        st = r.json()['settings']
        self.assertTrue(st['logo'])
        self.assertTrue(st['cover'])
        self.assertTrue(r.json()['vendor']['logo'])

    def test_only_logo_keeps_cover(self):
        self.upload(cover_image=png_file('cover.png'))
        cover = self.fresh().cover_image.name
        self.upload(logo=png_file('logo.png'))
        self.assertEqual(self.fresh().cover_image.name, cover)

    def test_remove_logo(self):
        self.upload(logo=png_file('logo.png'))
        r = self.upload(remove_logo='1')
        self.assertEqual(r.status_code, 200)
        self.assertFalse(self.fresh().logo)

    def test_new_file_wins_over_remove(self):
        self.upload(logo=png_file('logo.png'))
        r = self.upload(logo=png_file('new.png'), remove_logo='1')
        self.assertEqual(r.status_code, 200)
        self.assertTrue(self.fresh().logo)

    def test_not_an_image_rejected(self):
        bad = SimpleUploadedFile('x.png', b'not an image', content_type='image/png')
        r = self.upload(logo=bad)
        self.assertEqual(r.status_code, 400)
        self.assertIn('image', r.json()['error'].lower())
        self.assertFalse(self.fresh().logo)

    def test_too_big_rejected(self):
        big = SimpleUploadedFile('big.png', b'0' * (5 * 1024 * 1024 + 1), content_type='image/png')
        r = self.upload(logo=big)
        self.assertEqual(r.status_code, 400)
        self.assertIn('5 MB', r.json()['error'])

    def test_nothing_sent_is_error(self):
        self.assertEqual(self.upload().status_code, 400)

    def test_bad_cover_saves_nothing(self):
        bad = SimpleUploadedFile('x.png', b'nope', content_type='image/png')
        r = self.upload(logo=png_file('logo.png'), cover_image=bad)
        self.assertEqual(r.status_code, 400)
        self.assertFalse(self.fresh().logo)


class LocationTests(StoreBase):
    def good(self, **kw):
        return dict({'lat': 30.3011, 'lng': 71.9322, 'accuracy': 25, 'consent': True}, **kw)

    def test_verify_sets_blue_tick(self):
        r = self.locate(self.good())
        self.assertEqual(r.status_code, 200, r.content)
        p = self.fresh()
        self.assertTrue(p.location_verified)
        self.assertAlmostEqual(p.latitude, 30.3011)
        self.assertAlmostEqual(p.longitude, 71.9322)
        self.assertEqual(p.location_accuracy_m, 25)
        self.assertIsNotNone(p.location_consent_at)
        self.assertIsNotNone(p.location_verified_at)
        d = r.json()
        self.assertTrue(d['vendor']['location_verified'])
        self.assertTrue(d['store']['location_verified'])
        self.assertTrue(d['settings']['location']['has_location'])

    def test_consent_required(self):
        for bad in ({}, {'consent': False}, {'consent': 'no'}, {'consent': 0}):
            r = self.locate(self.good(**bad) if bad else {k: v for k, v in self.good().items() if k != 'consent'})
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.json()['code'], 'consent')
        self.assertFalse(self.fresh().location_verified)

    def test_string_consent_ok(self):
        self.assertEqual(self.locate(self.good(consent='1')).status_code, 200)

    def test_bad_coordinates(self):
        for bad in ({'lat': 'x'}, {'lat': 95}, {'lng': 200}, {'lat': 0, 'lng': 0}, {'lat': None}):
            r = self.locate(self.good(**bad))
            self.assertEqual(r.status_code, 400, bad)
        self.assertFalse(self.fresh().location_verified)

    def test_poor_accuracy_rejected(self):
        r = self.locate(self.good(accuracy=900))
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'accuracy')
        self.assertIn('900', r.json()['error'])
        self.assertFalse(self.fresh().location_verified)

    def test_accuracy_optional(self):
        d = self.good()
        d.pop('accuracy')
        self.assertEqual(self.locate(d).status_code, 200)

    def test_reverify_updates_location(self):
        self.locate(self.good())
        self.assertEqual(self.locate(self.good(lat=30.5, lng=72.0)).status_code, 200)
        self.assertAlmostEqual(self.fresh().latitude, 30.5)

    def test_other_vendor_untouched(self):
        self.locate(self.good())
        self.assertFalse(self.fresh(self.b).location_verified)
        self.assertIsNone(self.fresh(self.b).latitude)

    def test_dashboard_warning_goes_away(self):
        def codes():
            r = self.client.get(reverse('vendor_api_dashboard'), **self.bearer(self.a))
            return [w['code'] for w in r.json()['warnings']]
        before = codes()
        self.locate(self.good())
        after = codes()
        self.assertLessEqual(len(after), len(before))
        self.assertFalse(any('location' in c for c in after))


class WebMatchTests(StoreBase):
    def test_app_changes_visible_on_web_form_values(self):
        """App se badli settings wahi columns hain jo web `vendor_store_settings` padhta hai."""
        self.save('basic', status='busy', description='Mazedaar')
        self.save('timing', opens_at='10:00', closes_at='23:00')
        self.save('delivery', min_order_amount='250', delivery_fee='40', delivery_time_min=25, delivery_time_max=50)
        p = self.fresh()
        self.assertEqual(p.store_status, 'busy')
        self.assertEqual(p.store_description, 'Mazedaar')
        self.assertEqual((p.opens_at, p.closes_at), (dtime(10, 0), dtime(23, 0)))
        self.assertEqual((p.min_order_amount, p.delivery_fee), (Decimal('250.00'), Decimal('40.00')))
        self.assertEqual((p.delivery_time_min, p.delivery_time_max), (25, 50))
        # purani web ka status switch (V4) bhi naye status ko samajhta hai
        d = self.client.get(reverse('vendor_api_dashboard'), **self.bearer(self.a)).json()
        self.assertEqual(d['store']['status'], 'busy')
