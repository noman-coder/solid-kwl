"""
Phase V9-B tests: product ki photo (camera / gallery se aayi compressed photo) - add / edit / errors.

Run:  python manage.py test app.tests_vendor_product_photo
Asli FCM / Cloudinary ko koi call nahi jati (push mock, MEDIA_ROOT temp folder).
"""
import shutil
import tempfile
from unittest import mock

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from django.urls import reverse

from app.models import Product
from app.tests_vendor_product_form import FormBase, png_file


class PhotoBase(FormBase):
    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp()
        o = override_settings(MEDIA_ROOT=self.tmp)
        o.enable()
        self.addCleanup(o.disable)
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def ready(self, profile, name='Aata', price='200', stock=10):
        """Edit ke liye tayyar product (category / brand / unit ke saath, bina photo)."""
        p = self.mk(profile, name, price=price, stock=stock)
        Product.objects.filter(pk=p.pk).update(category=self.cat, brand=self.brand, unit=self.unit,
                                               description='Acha maal')
        return Product.objects.get(pk=p.pk)

    def approved_with_photo(self, name='Aata'):
        p = self.mk(self.a, name, price='200', stock=10)
        Product.objects.filter(pk=p.pk).update(category=self.cat, brand=self.brand, unit=self.unit,
                                               description='Acha aata')
        # photo lagao (server processing ke saath)
        q = Product.objects.get(pk=p.pk)
        q.image.save('old.png', png_file('old.png'), save=False)
        q.save()
        return Product.objects.get(pk=p.pk)


class NeedsPhotoFlagTests(PhotoBase):
    def test_list_marks_products_without_photo(self):
        with_photo = self.approved_with_photo('Photo wala')
        no_photo = self.mk(self.a, 'Bina photo')
        rows = {r['id']: r for r in self.lst().json()['products']}
        self.assertFalse(rows[with_photo.pk]['needs_photo'])
        self.assertTrue(rows[no_photo.pk]['needs_photo'])

    def test_product_json_after_add_has_flag(self):
        d = self.add().json()
        self.assertTrue(d['product']['needs_photo'])
        d2 = self.add_multipart(dict(self.form(name='Daal 1kg'), image=png_file())).json()
        self.assertFalse(d2['product']['needs_photo'])


class AddWithPhotoTests(PhotoBase):
    def test_compressed_jpeg_is_accepted(self):
        from io import BytesIO
        from PIL import Image
        buf = BytesIO()
        Image.new('RGB', (1280, 960), 'blue').save(buf, 'JPEG', quality=80)
        f = SimpleUploadedFile('p.jpg', buf.getvalue(), content_type='image/jpeg')
        r = self.add_multipart(dict(self.form(), image=f))
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(r.json()['needs_photo'])
        self.assertFalse(r.json()['photo_failed'])

    def test_wrong_file_gives_clear_message_and_creates_nothing(self):
        bad = SimpleUploadedFile('x.jpg', b'%PDF-1.4 not an image', content_type='image/jpeg')
        r = self.add_multipart(dict(self.form(), image=bad))
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'validation')
        self.assertIn('Valid image', r.json()['message'])
        self.assertFalse(Product.objects.filter(vendor=self.a.vendor).exists())

    def test_oversize_gives_clear_message(self):
        big = SimpleUploadedFile('big.jpg', b'0' * (5 * 1024 * 1024 + 1), content_type='image/jpeg')
        r = self.add_multipart(dict(self.form(), image=big))
        self.assertEqual(r.status_code, 400)
        self.assertIn('5 MB', r.json()['message'])

    def test_retry_with_same_request_key_does_not_duplicate(self):
        body = dict(self.form(), request_key='photo-key-12345678')
        d1 = self.add_multipart(dict(body, image=png_file())).json()
        d2 = self.add_multipart(dict(body, image=png_file())).json()
        self.assertTrue(d2.get('duplicate'))
        self.assertEqual(d1['product']['id'], d2['product']['id'])
        self.assertEqual(Product.objects.filter(name='Rice 5kg').count(), 1)

    def test_photo_storage_failure_still_saves_product_without_photo(self):
        real_save = Product.save

        def flaky(self_, *a, **kw):
            if self_.image and not getattr(self_, '_boom_done', False):
                raise OSError('storage down')
            return real_save(self_, *a, **kw)

        with mock.patch.object(Product, 'save', flaky):
            r = self.add_multipart(dict(self.form(), image=png_file()))
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()
        self.assertTrue(d['ok'])
        self.assertTrue(d['photo_failed'])
        self.assertTrue(d['needs_photo'])
        self.assertFalse(d['live'])
        self.assertIn('Photo', d['message'])
        p = Product.objects.get(name='Rice 5kg')
        self.assertFalse(p.image)
        self.assertEqual(p.approval_status, 'pending')

    @override_settings(VENDOR_AUTO_APPROVE_PRODUCTS=True)
    def test_photo_storage_failure_never_goes_live(self):
        real_save = Product.save

        def flaky(self_, *a, **kw):
            if self_.image:
                raise OSError('storage down')
            return real_save(self_, *a, **kw)

        with mock.patch.object(Product, 'save', flaky):
            d = self.add_multipart(dict(self.form(), image=png_file())).json()
        self.assertFalse(d['live'])
        self.assertEqual(Product.objects.get(name='Rice 5kg').approval_status, 'pending')


class EditPhotoTests(PhotoBase):
    def test_photo_only_edit_keeps_every_other_field(self):
        p = self.ready(self.a, 'Aata')
        Product.objects.filter(pk=p.pk).update(description='Acha aata')
        r = self.edit_multipart(p.pk, {'image': png_file()})
        self.assertEqual(r.status_code, 200, r.content)
        q = Product.objects.get(pk=p.pk)
        self.assertEqual((q.name, q.description, q.category, q.brand, q.unit), ('Aata', 'Acha aata', self.cat,
                                                                             self.brand, self.unit))
        self.assertEqual(float(q.original_price), 200.0)
        self.assertTrue(q.image)

    def test_photo_completes_pending_message(self):
        pid = self.add().json()['product']['id']
        d = self.edit_multipart(pid, {'image': png_file()}).json()
        self.assertFalse(d['needs_photo'])
        self.assertFalse(d['live'])
        self.assertIn('Admin approval', d['message'])

    @override_settings(VENDOR_AUTO_APPROVE_PRODUCTS=True)
    def test_photo_completes_live_message(self):
        pid = self.add().json()['product']['id']
        d = self.edit_multipart(pid, {'image': png_file()}).json()
        self.assertTrue(d['live'])
        self.assertIn('live', d['message'].lower())

    def test_changing_photo_of_approved_product_goes_back_to_review(self):
        p = self.approved_with_photo()
        d = self.edit_multipart(p.pk, {'image': png_file('new.png', (20, 20))}).json()
        self.assertTrue(d['resubmitted'])
        self.assertIn('review', d['message'].lower())
        q = Product.objects.get(pk=p.pk)
        self.assertEqual((q.approval_status, q.is_active), ('pending', False))

    @override_settings(VENDOR_AUTO_APPROVE_PRODUCTS=True)
    def test_changing_photo_with_auto_approve_stays_live(self):
        p = self.approved_with_photo()
        d = self.edit_multipart(p.pk, {'image': png_file('new.png', (20, 20))}).json()
        self.assertFalse(d['resubmitted'])
        self.assertTrue(d['live'])

    def test_edit_without_image_keeps_old_photo(self):
        p = self.approved_with_photo()
        old = p.image.name
        r = self.edit(p.pk, {'price': 250})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(Product.objects.get(pk=p.pk).image.name, old)
        self.assertFalse(r.json()['needs_photo'])

    def test_bad_image_on_edit_changes_nothing(self):
        p = self.approved_with_photo()
        old = p.image.name
        bad = SimpleUploadedFile('x.jpg', b'garbage', content_type='image/jpeg')
        r = self.edit_multipart(p.pk, {'image': bad, 'name': 'Naya naam'})
        self.assertEqual(r.status_code, 400)
        q = Product.objects.get(pk=p.pk)
        self.assertEqual((q.name, q.image.name), ('Aata', old))

    def test_big_image_on_edit_rejected(self):
        p = self.ready(self.a, 'Aata')
        big = SimpleUploadedFile('big.jpg', b'0' * (5 * 1024 * 1024 + 1), content_type='image/jpeg')
        r = self.edit_multipart(p.pk, {'image': big})
        self.assertEqual(r.status_code, 400)
        self.assertIn('5 MB', r.json()['message'])

    def test_storage_failure_on_edit_gives_photo_message_and_changes_nothing(self):
        p = self.ready(self.a, 'Aata')
        real_save = Product.save

        def flaky(self_, *a, **kw):
            if self_.image:
                raise OSError('storage down')
            return real_save(self_, *a, **kw)

        with mock.patch.object(Product, 'save', flaky):
            r = self.edit_multipart(p.pk, {'image': png_file(), 'name': 'Naya naam'})
        self.assertEqual(r.status_code, 500)
        self.assertIn('Photo', r.json()['message'])
        q = Product.objects.get(pk=p.pk)
        self.assertEqual(q.name, 'Aata')
        self.assertFalse(q.image)

    def test_other_vendors_product_photo_404(self):
        p = self.mk(self.b, 'Unka')
        r = self.edit_multipart(p.pk, {'image': png_file()})
        self.assertEqual(r.status_code, 404)
        self.assertFalse(Product.objects.get(pk=p.pk).image)


class EditRetryTests(PhotoBase):
    def test_retry_with_same_request_key_does_not_add_stock_twice(self):
        from app.models import Inventory
        p = self.ready(self.a, 'Aata')
        body = {'stock': 5, 'request_key': 'edit-key-12345678'}
        d1 = self.edit(p.pk, body).json()
        d2 = self.edit(p.pk, body).json()
        self.assertTrue(d1['ok'])
        self.assertTrue(d2['ok'])
        self.assertTrue(d2.get('duplicate'))
        self.assertEqual(Inventory.objects.get(product=p, warehouse=self.wh).stock, 15)

    def test_failed_edit_can_be_retried_with_same_key(self):
        p = self.ready(self.a, 'Aata')
        bad = SimpleUploadedFile('x.jpg', b'garbage', content_type='image/jpeg')
        key = 'edit-key-87654321'
        r1 = self.edit_multipart(p.pk, {'image': bad, 'request_key': key})
        self.assertEqual(r1.status_code, 400)
        r2 = self.edit_multipart(p.pk, {'image': png_file(), 'request_key': key})
        self.assertEqual(r2.status_code, 200, r2.content)
        self.assertFalse(r2.json().get('duplicate', False))
        self.assertTrue(Product.objects.get(pk=p.pk).image)

    def test_other_vendors_key_does_not_block(self):
        p = self.ready(self.b, 'Unka')
        q = self.ready(self.a, 'Mera')
        self.edit(p.pk, {'stock': 1, 'request_key': 'shared-key-123456'}, profile=self.b)
        r = self.edit(q.pk, {'stock': 1, 'request_key': 'shared-key-123456'}, profile=self.a)
        self.assertFalse(r.json().get('duplicate', False))
