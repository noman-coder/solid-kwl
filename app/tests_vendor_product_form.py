"""
Phase V9-A tests: product add / edit API (form-data, add, edit, naya category/brand/unit).

Run:  python manage.py test app.tests_vendor_product_form
Asli FCM ko koi call nahi jati (push_async mock hota hai). Photo wale tests temp MEDIA_ROOT mein chalte hain.
"""
import json
import shutil
import tempfile
from decimal import Decimal
from io import BytesIO

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from django.urls import reverse

from app.models import Brand, Category, Inventory, Product, StockBatch, Unit
from app.tests_vendor_api import PHONE_A, PHONE_B, make_vendor
from app.tests_vendor_products import LOCMEM, ProductsBase


def png_file(name='p.png', size=(10, 10)):
    from PIL import Image
    buf = BytesIO()
    Image.new('RGB', size, 'red').save(buf, 'PNG')
    return SimpleUploadedFile(name, buf.getvalue(), content_type='image/png')


@override_settings(CACHES=LOCMEM)
class FormBase(ProductsBase):
    def setUp(self):
        super().setUp()
        from django.core.cache import cache
        cache.clear()                      # locmem cache tests ke beech bachta hai (request_key / master limit)
        self.cat = Category.objects.create(name='Grocery')
        self.cat2 = Category.objects.create(name='Dairy')
        self.brand = Brand.objects.create(name='National')
        self.unit = Unit.objects.create(name='Kg')

    def form(self, **over):
        d = {'name': 'Rice 5kg', 'category': self.cat.pk, 'brand': self.brand.pk, 'unit': self.unit.pk,
             'price': 1500, 'discount_percentage': 0, 'stock': 20}
        d.update(over)
        return d

    def add(self, body=None, profile=None):
        return self.client.post(reverse('vendor_api_products'), json.dumps(body if body is not None else self.form()),
                                content_type='application/json', **self.bearer(profile or self.a))

    def add_multipart(self, body, profile=None):
        return self.client.post(reverse('vendor_api_products'), body, **self.bearer(profile or self.a))

    def edit(self, pk, body, profile=None):
        return self.post('vendor_api_product_edit', body, profile, kwargs={'pk': pk})

    def edit_multipart(self, pk, body, profile=None):
        return self.client.post(reverse('vendor_api_product_edit', kwargs={'pk': pk}), body,
                                **self.bearer(profile or self.a))

    def form_data(self, profile=None, **params):
        return self.client.get(reverse('vendor_api_product_form_data'), params, **self.bearer(profile or self.a))


class FormDataTests(FormBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_product_form_data')).status_code, 401)

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.form_data(c).status_code, 403)

    def test_lists_masters_and_limits(self):
        d = self.form_data().json()
        self.assertTrue(d['ok'])
        self.assertEqual({c['name'] for c in d['categories']}, {'Grocery', 'Dairy'})
        self.assertEqual(d['brands'], [{'id': self.brand.pk, 'name': 'National'}])
        self.assertEqual(d['units'], [{'id': self.unit.pk, 'name': 'Kg'}])
        self.assertTrue(d['can_add'])
        self.assertFalse(d['auto_approve'])
        self.assertEqual(d['limits']['max_discount'], 90)
        self.assertEqual(d['limits']['max_image_mb'], 5)
        self.assertNotIn('product', d)

    def test_can_add_false_without_warehouse(self):
        self.wh.delete()
        self.assertFalse(self.form_data().json()['can_add'])

    def test_product_values_for_edit(self):
        p = self.mk(self.a, 'Aata', price='200', stock=7)
        Product.objects.filter(pk=p.pk).update(category=self.cat, discount_percentage=Decimal('10'))
        d = self.form_data(product=p.pk).json()['product']
        self.assertEqual((d['name'], d['category'], d['price'], d['current_stock']), ('Aata', self.cat.pk, 200, 7))
        self.assertEqual(d['discount_percentage'], 10)
        self.assertFalse(d['has_image'])

    def test_other_vendors_product_404(self):
        p = self.mk(self.b, 'Unka')
        self.assertEqual(self.form_data(product=p.pk).status_code, 404)

    def test_bad_product_param_404(self):
        self.assertEqual(self.form_data(product='abc').status_code, 404)


class AddTests(FormBase):
    def test_requires_token(self):
        r = self.client.post(reverse('vendor_api_products'), '{}', content_type='application/json')
        self.assertEqual(r.status_code, 401)

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.add(profile=c).status_code, 403)

    def test_add_without_photo_is_pending_and_needs_photo(self):
        r = self.add()
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()
        self.assertTrue(d['ok'])
        self.assertTrue(d['needs_photo'])
        self.assertFalse(d['live'])
        p = Product.objects.get(name='Rice 5kg')
        self.assertEqual(p.vendor, self.a.vendor)
        self.assertEqual(p.created_by, self.a.user)
        self.assertEqual((p.approval_status, p.is_active), ('pending', False))
        self.assertEqual(Inventory.objects.get(product=p, warehouse=self.wh).stock, 20)
        b = StockBatch.objects.get(product=p)
        self.assertEqual((b.price, b.selling_price), (Decimal('1200'), Decimal('1500')))
        self.assertEqual(d['product']['id'], p.pk)
        self.assertEqual(d['product']['approval_status'], 'pending')
        self.assertEqual(d['counts']['pending'], 1)

    @override_settings(VENDOR_AUTO_APPROVE_PRODUCTS=True)
    def test_auto_approve_still_pending_without_photo(self):
        d = self.add().json()
        p = Product.objects.get(name='Rice 5kg')
        self.assertEqual((p.approval_status, p.is_active), ('pending', False))
        self.assertTrue(d['needs_photo'])

    def test_discount_alias_and_price_math(self):
        body = self.form(discount=10)
        del body['discount_percentage']
        self.add(body)
        p = Product.objects.get(name='Rice 5kg')
        self.assertEqual(p.discount_percentage, Decimal('10'))
        self.assertEqual(p.original_price, Decimal('1500'))
        self.assertEqual(p.price, Decimal('1350'))

    def test_brand_unit_optional(self):
        self.assertEqual(self.add(self.form(brand='', unit='')).status_code, 200)
        p = Product.objects.get(name='Rice 5kg')
        self.assertIsNone(p.brand)
        self.assertIsNone(p.unit)

    def test_validation_errors_listed_together(self):
        r = self.add({'name': 'ab', 'category': '', 'price': 'abc', 'stock': -1})
        self.assertEqual(r.status_code, 400)
        d = r.json()
        self.assertEqual(d['code'], 'validation')
        self.assertFalse(d['ok'])
        self.assertGreaterEqual(len(d['errors']), 4)
        self.assertEqual(d['error'], d['errors'][0])
        self.assertFalse(Product.objects.filter(vendor=self.a.vendor).exists())

    def test_zero_stock_rejected_on_add(self):
        r = self.add(self.form(stock=0))
        self.assertEqual(r.status_code, 400)

    def test_bad_numbers(self):
        for bad in ({'price': 0}, {'price': -5}, {'price': 'NaN'}, {'price': 'Infinity'},
                    {'discount_percentage': 95}, {'stock': 'nan'}, {'stock': 2_000_000}, {'price': True}):
            r = self.add(self.form(**bad))
            self.assertEqual(r.status_code, 400, bad)
        self.assertFalse(Product.objects.filter(vendor=self.a.vendor).exists())

    def test_unknown_category_rejected(self):
        self.assertEqual(self.add(self.form(category=99999)).status_code, 400)

    def test_margin_policy_error_is_clean_and_rolls_back(self):
        # discount 90% + commission: batch cost > selling ho to StockBatch.save ValidationError - product na bane
        from unittest import mock
        from django.core.exceptions import ValidationError
        with mock.patch('app.customer.views_vendor_portal._add_stock', side_effect=ValidationError('Margin kam hai')):
            r = self.add()
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['error'], 'Margin kam hai')
        self.assertFalse(Product.objects.filter(name='Rice 5kg').exists())

    def test_no_warehouse(self):
        self.wh.delete()
        r = self.add()
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'no_warehouse')

    def test_request_key_prevents_duplicate(self):
        body = self.form(request_key='abcd1234efgh')
        first = self.add(body).json()
        second = self.add(body).json()
        self.assertTrue(second['duplicate'])
        self.assertEqual(second['product']['id'], first['product']['id'])
        self.assertEqual(Product.objects.filter(vendor=self.a.vendor, name='Rice 5kg').count(), 1)
        self.assertEqual(Inventory.objects.get(product_id=first['product']['id']).stock, 20)

    def test_bad_request_key_is_ignored(self):
        body = self.form(request_key='x')
        self.add(body)
        self.add(body)
        self.assertEqual(Product.objects.filter(vendor=self.a.vendor, name='Rice 5kg').count(), 2)

    def test_vendor_cannot_use_other_vendors_request_key(self):
        body = self.form(request_key='abcd1234efgh')
        self.add(body, self.a)
        self.add(body, self.b)
        self.assertEqual(Product.objects.filter(name='Rice 5kg').count(), 2)


class PhotoTests(FormBase):
    """Backend photo ko abhi se support karta hai (app mein photo V9-B mein aayegi)."""

    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp()
        o = override_settings(MEDIA_ROOT=self.tmp)
        o.enable()
        self.addCleanup(o.disable)
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_add_with_photo_multipart_pending(self):
        d = self.add_multipart(dict(self.form(), image=png_file())).json()
        self.assertFalse(d['needs_photo'])
        self.assertFalse(d['live'])
        p = Product.objects.get(name='Rice 5kg')
        self.assertTrue(p.image)
        self.assertEqual(p.approval_status, 'pending')
        self.assertTrue(d['product']['image'])

    @override_settings(VENDOR_AUTO_APPROVE_PRODUCTS=True)
    def test_add_with_photo_auto_approve_live(self):
        d = self.add_multipart(dict(self.form(), image=png_file())).json()
        self.assertTrue(d['live'])
        p = Product.objects.get(name='Rice 5kg')
        self.assertEqual((p.approval_status, p.is_active), ('approved', True))

    def test_bad_image_rejected(self):
        bad = SimpleUploadedFile('x.png', b'not an image', content_type='image/png')
        r = self.add_multipart(dict(self.form(), image=bad))
        self.assertEqual(r.status_code, 400)
        self.assertIn('image', r.json()['error'].lower())
        self.assertFalse(Product.objects.filter(vendor=self.a.vendor).exists())

    def test_big_image_rejected(self):
        big = SimpleUploadedFile('big.png', b'0' * (5 * 1024 * 1024 + 1), content_type='image/png')
        r = self.add_multipart(dict(self.form(), image=big))
        self.assertEqual(r.status_code, 400)
        self.assertIn('5 MB', r.json()['error'])

    def test_photo_only_edit_completes_imageless_product(self):
        pid = self.add().json()['product']['id']
        r = self.edit_multipart(pid, {'image': png_file()})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(r.json()['needs_photo'])
        self.assertTrue(Product.objects.get(pk=pid).image)

    @override_settings(VENDOR_AUTO_APPROVE_PRODUCTS=True)
    def test_photo_completes_and_goes_live_with_auto_approve(self):
        pid = self.add().json()['product']['id']
        self.edit_multipart(pid, {'image': png_file()})
        p = Product.objects.get(pk=pid)
        self.assertEqual((p.approval_status, p.is_active), ('approved', True))


class EditTests(FormBase):
    def approved(self, name='Aata', **kw):
        p = self.mk(self.a, name, price='200', stock=10, **kw)
        Product.objects.filter(pk=p.pk).update(category=self.cat, brand=self.brand, unit=self.unit,
                                               description='Acha aata')
        return Product.objects.get(pk=p.pk)

    def test_requires_token(self):
        p = self.approved()
        r = self.client.post(reverse('vendor_api_product_edit', kwargs={'pk': p.pk}), '{}',
                             content_type='application/json')
        self.assertEqual(r.status_code, 401)

    def test_other_vendors_product_404(self):
        p = self.mk(self.b, 'Unka')
        r = self.edit(p.pk, {'name': 'Hacked product'})
        self.assertEqual(r.status_code, 404)
        p.refresh_from_db()
        self.assertEqual(p.name, 'Unka')

    def test_get_not_allowed(self):
        p = self.approved()
        r = self.client.get(reverse('vendor_api_product_edit', kwargs={'pk': p.pk}), **self.bearer(self.a))
        self.assertEqual(r.status_code, 405)

    def test_price_only_edit_needs_no_review(self):
        p = self.approved()
        r = self.edit(p.pk, {'price': 250})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(r.json()['resubmitted'])
        p.refresh_from_db()
        self.assertEqual((p.approval_status, p.is_active), ('approved', True))
        self.assertEqual(p.price, Decimal('250'))
        self.assertEqual(p.name, 'Aata')            # bheji nahi gayi field waisi hi

    def test_name_change_sends_back_to_review(self):
        p = self.approved()
        r = self.edit(p.pk, {'name': 'Aata Special'})
        self.assertTrue(r.json()['resubmitted'])
        p.refresh_from_db()
        self.assertEqual((p.name, p.approval_status, p.is_active), ('Aata Special', 'pending', False))

    @override_settings(VENDOR_AUTO_APPROVE_PRODUCTS=True)
    def test_name_change_stays_live_with_auto_approve(self):
        p = self.approved()
        r = self.edit(p.pk, {'name': 'Aata Special'})
        self.assertFalse(r.json()['resubmitted'])
        p.refresh_from_db()
        self.assertEqual(p.approval_status, 'approved')

    def test_rejected_product_resubmitted(self):
        p = self.approved('Rad', status='rejected', active=False, reason='Naam theek nahi')
        r = self.edit(p.pk, {'name': 'Aata Fine'})
        self.assertTrue(r.json()['resubmitted'])
        p.refresh_from_db()
        self.assertEqual((p.approval_status, p.rejection_reason), ('pending', ''))

    def test_stock_is_added_not_replaced(self):
        p = self.approved()
        r = self.edit(p.pk, {'stock': 5})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(Inventory.objects.get(product=p, warehouse=self.wh).stock, 15)
        self.assertEqual(r.json()['product']['stock'], 15)

    def test_discount_reprices_open_batches(self):
        p = self.approved()
        StockBatch(product=p, qty=10, remaining_qty=10, price=Decimal('160'), warehouse=self.wh,
                   selling_price=Decimal('200')).save()
        self.edit(p.pk, {'price': 300, 'discount_percentage': 0})
        b = StockBatch.objects.get(product=p)
        self.assertEqual(b.selling_price, Decimal('300'))
        self.assertEqual(b.price, Decimal('240'))

    def test_validation_error_changes_nothing(self):
        p = self.approved()
        r = self.edit(p.pk, {'name': 'ab', 'price': 'xyz'})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'validation')
        p.refresh_from_db()
        self.assertEqual((p.name, p.price), ('Aata', Decimal('200')))

    def test_brand_can_be_cleared(self):
        p = self.approved()
        self.edit(p.pk, {'brand': ''})
        p.refresh_from_db()
        self.assertIsNone(p.brand)

    def test_empty_name_key_is_an_error_but_missing_is_not(self):
        p = self.approved()
        self.assertEqual(self.edit(p.pk, {'name': ''}).status_code, 400)
        self.assertEqual(self.edit(p.pk, {}).status_code, 200)


class MasterTests(FormBase):
    def mk_master(self, kind, name, profile=None):
        return self.post('vendor_api_create_master', {'name': name}, profile, kwargs={'kind': kind})

    def test_requires_token(self):
        r = self.client.post(reverse('vendor_api_create_master', kwargs={'kind': 'brand'}), '{}',
                             content_type='application/json')
        self.assertEqual(r.status_code, 401)

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.mk_master('brand', 'Shan', c).status_code, 403)

    def test_creates_each_kind(self):
        for kind, model in (('category', Category), ('brand', Brand), ('unit', Unit)):
            r = self.mk_master(kind, f'  Naya   {kind} ')
            self.assertEqual(r.status_code, 200, r.content)
            d = r.json()
            self.assertTrue(d['ok'])
            self.assertFalse(d['existed'])
            self.assertEqual(d['name'], f'Naya {kind}')
            self.assertTrue(model.objects.filter(pk=d['id']).exists())

    def test_same_name_returns_existing(self):
        r = self.mk_master('brand', 'national')
        d = r.json()
        self.assertTrue(d['existed'])
        self.assertEqual(d['id'], self.brand.pk)
        self.assertEqual(Brand.objects.count(), 1)

    def test_short_name_rejected(self):
        r = self.mk_master('brand', 'a')
        self.assertEqual(r.status_code, 400)
        self.assertFalse(r.json()['ok'])

    def test_bad_kind_404(self):
        self.assertEqual(self.mk_master('store', 'Kuch').status_code, 404)

    def test_hourly_limit(self):
        from app.customer.views_vendor_portal import MASTER_CREATE_LIMIT
        for i in range(MASTER_CREATE_LIMIT):
            self.assertEqual(self.mk_master('brand', f'Brand {i:03d}').status_code, 200)
        r = self.mk_master('brand', 'Brand extra')
        self.assertEqual(r.status_code, 400)
        self.assertFalse(Brand.objects.filter(name='Brand extra').exists())

    def test_new_master_usable_in_add(self):
        mid = self.mk_master('category', 'Masale').json()['id']
        r = self.add(self.form(category=mid))
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(Product.objects.get(name='Rice 5kg').category_id, mid)
