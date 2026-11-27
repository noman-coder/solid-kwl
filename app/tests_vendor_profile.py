"""
Phase V16 tests: vendor profile (GET/POST), password change, account delete, support links.

Run:  python manage.py test app.tests_vendor_profile
Asli FCM ko koi call nahi jati (VendorPushBase push mock karta hai).
"""
import json

from django.contrib.auth.models import User
from django.core.cache import cache
from django.urls import reverse

from app.models import Product, VendorProfile, VendorPushToken
from app.tests_vendor_api import PASSWORD, PHONE_A, PHONE_B, make_vendor
from app.tests_vendor_push import VendorPushBase

TOK_A1 = 'a' * 40
TOK_A2 = 'b' * 40
TOK_B1 = 'c' * 40


class ProfileBase(VendorPushBase):
    def get(self, name, profile=None, **params):
        kw = self.bearer(profile) if profile is not None else {}
        return self.client.get(reverse(name), params, **kw)

    def profile(self, profile=None):
        return self.get('vendor_api_profile', profile or self.a)

    def change_pw(self, old=PASSWORD, new='newpass1', profile=None, **extra):
        return self.post_json('vendor_api_password', dict(old_password=old, new_password=new, **extra),
                              profile or self.a)

    def delete(self, password=PASSWORD, confirm=True, profile=None):
        return self.post_json('vendor_api_account_delete', {'password': password, 'confirm': confirm},
                              profile or self.a)


class AuthTests(ProfileBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_profile')).status_code, 401)
        self.assertEqual(self.post_json('vendor_api_profile', {}).status_code, 401)
        self.assertEqual(self.post_json('vendor_api_password', {}).status_code, 401)
        self.assertEqual(self.post_json('vendor_api_account_delete', {}).status_code, 401)

    def test_unapproved_vendor_blocked(self):
        pending = make_vendor('Naya Store', '03005555555', approved=False)
        self.assertEqual(self.profile(pending).status_code, 403)
        self.assertEqual(self.profile(pending).json()['code'], 'pending')
        self.assertEqual(self.change_pw(profile=pending).status_code, 403)
        self.assertEqual(self.delete(profile=pending).status_code, 403)

    def test_wrong_method(self):
        self.assertEqual(self.client.get(reverse('vendor_api_password'), **self.bearer(self.a)).status_code, 405)
        self.assertEqual(self.client.get(reverse('vendor_api_account_delete'), **self.bearer(self.a)).status_code, 405)
        self.assertEqual(self.client.put(reverse('vendor_api_profile'), '{}', content_type='application/json',
                                         **self.bearer(self.a)).status_code, 405)


class ProfileGetTests(ProfileBase):
    def test_get_profile(self):
        self.a.user.first_name, self.a.user.last_name, self.a.user.email = 'Ali', 'Raza Khan', 'ali@x.com'
        self.a.user.save()
        self.a.city = 'Khanewal'
        self.a.save()
        self.a.vendor.address = 'Chowk Bazar, Khanewal'
        self.a.vendor.save()
        d = self.profile().json()
        self.assertTrue(d['ok'])
        p = d['profile']
        self.assertEqual(p['store_name'], 'Ali Store')
        self.assertEqual(p['owner_name'], 'Ali Raza Khan')
        self.assertEqual(p['email'], 'ali@x.com')
        self.assertEqual(p['city'], 'Khanewal')
        self.assertEqual(p['address'], 'Chowk Bazar, Khanewal')
        self.assertEqual(p['phone'], self.a.vendor.contact_number)
        self.assertTrue(p['approved'])
        self.assertEqual(p['open_orders'], 0)
        self.assertTrue(p['can_delete'])
        self.assertEqual(d['vendor']['name'], 'Ali Store')

    def test_support_links(self):
        s = self.profile().json()['support']
        for k in ('name', 'phone', 'email', 'whatsapp_url', 'privacy_url', 'delete_url'):
            self.assertIn(k, s)
        self.assertTrue(s['privacy_url'].endswith(reverse('privacy_policy')))
        self.assertTrue(s['delete_url'].endswith(reverse('delete_account_info')))

    def test_open_orders_block_delete_flag(self):
        self._order(vendor=self.a, status='pending')
        self._order(vendor=self.a, status='delivered')
        self._order(vendor=self.b, status='pending')
        p = self.profile().json()['profile']
        self.assertEqual(p['open_orders'], 1)
        self.assertFalse(p['can_delete'])


class ProfilePostTests(ProfileBase):
    def post(self, data, profile=None):
        return self.post_json('vendor_api_profile', data, profile or self.a)

    def test_update_all_fields(self):
        r = self.post({'owner_name': 'Ali Raza Khan', 'email': 'Ali@Example.com', 'city': ' Khanewal ',
                       'address': 'Chowk Bazar, Khanewal, Punjab'})
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'])
        self.assertEqual(d['profile']['owner_name'], 'Ali Raza Khan')
        self.assertEqual(d['profile']['city'], 'Khanewal')
        self.a.refresh_from_db()
        self.a.user.refresh_from_db()
        self.a.vendor.refresh_from_db()
        self.assertEqual((self.a.user.first_name, self.a.user.last_name), ('Ali', 'Raza Khan'))
        self.assertEqual(self.a.user.email, 'Ali@Example.com')
        self.assertEqual(self.a.city, 'Khanewal')
        self.assertEqual(self.a.vendor.address, 'Chowk Bazar, Khanewal, Punjab')

    def test_only_sent_fields_change(self):
        self.a.city = 'Multan'
        self.a.save()
        self.post({'owner_name': 'Ali Raza'})
        self.a.refresh_from_db()
        self.assertEqual(self.a.city, 'Multan')

    def test_phone_and_store_name_cannot_change(self):
        phone = self.a.vendor.contact_number
        self.post({'owner_name': 'Ali Raza', 'phone': '03009998888', 'business_name': 'Hacked', 'store_name': 'Hacked'})
        self.a.refresh_from_db()
        self.a.vendor.refresh_from_db()
        self.assertEqual(self.a.vendor.contact_number, phone)
        self.assertEqual(self.a.business_name, 'Ali Store')
        self.assertEqual(self.a.vendor.name, 'Ali Store')

    def test_validation_errors_listed_and_nothing_saved(self):
        r = self.post({'owner_name': 'Al', 'email': 'not-an-email', 'city': '', 'address': 'short'})
        self.assertEqual(r.status_code, 400)
        d = r.json()
        self.assertFalse(d['ok'])
        self.assertEqual(d['code'], 'validation')
        self.assertEqual(len(d['errors']), 4)
        self.assertEqual(d['error'], d['errors'][0])
        self.a.refresh_from_db()
        self.assertEqual(self.a.business_name, 'Ali Store')

    def test_one_bad_field_saves_nothing(self):
        self.a.city = 'Multan'
        self.a.save()
        r = self.post({'city': 'Khanewal', 'email': 'bad'})
        self.assertEqual(r.status_code, 400)
        self.a.refresh_from_db()
        self.assertEqual(self.a.city, 'Multan')

    def test_duplicate_email_rejected_but_own_email_ok(self):
        self.b.user.email = 'bilal@x.com'
        self.b.user.save()
        self.a.user.email = 'ali@x.com'
        self.a.user.save()
        self.assertEqual(self.post({'email': 'BILAL@x.com'}).status_code, 400)
        self.assertEqual(self.post({'email': 'ali@x.com'}).status_code, 200)

    def test_empty_body(self):
        r = self.post({})
        self.assertEqual(r.status_code, 400)
        self.assertFalse(r.json()['ok'])

    def test_non_text_values_rejected_not_crash(self):
        for bad in ({'owner_name': ['x']}, {'city': {'a': 1}}, {'email': True}, {'address': False}):
            r = self.post(bad)
            self.assertEqual(r.status_code, 400, bad)

    def test_too_long_values(self):
        self.assertEqual(self.post({'owner_name': 'x' * 101}).status_code, 400)
        self.assertEqual(self.post({'city': 'x' * 101}).status_code, 400)
        self.assertEqual(self.post({'address': 'x' * 501}).status_code, 400)

    def test_other_vendor_untouched(self):
        self.post({'city': 'Khanewal', 'owner_name': 'Ali Raza'})
        self.b.refresh_from_db()
        self.assertNotEqual(self.b.city, 'Khanewal')


class PasswordTests(ProfileBase):
    def setUp(self):
        super().setUp()
        for key in (f'vendor_api_pw:{self.a.pk}', f'vendor_api_pw:{self.b.pk}'):
            cache.delete(key)

    def test_change_ok_returns_new_token_and_old_token_dies(self):
        old_headers = self.bearer(self.a)
        r = self.change_pw()
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'])
        self.assertTrue(d['token'])
        # naya token chalta hai
        ok = self.client.get(reverse('vendor_api_me'), HTTP_AUTHORIZATION='Bearer ' + d['token'])
        self.assertEqual(ok.status_code, 200)
        # purana token (doosra phone) band
        gone = self.client.get(reverse('vendor_api_me'), **old_headers)
        self.assertEqual(gone.status_code, 401)
        self.assertEqual(gone.json()['code'], 'auth')

    def test_login_with_new_password_only(self):
        self.change_pw(new='newpass1')
        good = self.client.post(reverse('vendor_api_login'), json.dumps({'phone': PHONE_A, 'password': 'newpass1'}),
                                content_type='application/json')
        self.assertEqual(good.status_code, 200)
        cache.clear()
        bad = self.client.post(reverse('vendor_api_login'), json.dumps({'phone': PHONE_A, 'password': PASSWORD}),
                               content_type='application/json')
        self.assertEqual(bad.status_code, 401)

    def test_other_vendor_token_unaffected(self):
        self.change_pw()
        self.assertEqual(self.client.get(reverse('vendor_api_me'), **self.bearer(self.b)).status_code, 200)

    def test_wrong_old_password(self):
        r = self.change_pw(old='nope')
        self.assertEqual(r.status_code, 401)
        self.assertFalse(r.json()['ok'])
        self.assertEqual(r.json()['code'], 'bad_password')
        self.a.user.refresh_from_db()
        self.assertTrue(self.a.user.check_password(PASSWORD))

    def test_five_wrong_attempts_lock(self):
        for _ in range(5):
            self.assertEqual(self.change_pw(old='nope').status_code, 401)
        r = self.change_pw(old='nope')
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()['code'], 'locked')
        # lock ke dauran sahi purana password bhi nahi chalta
        self.assertEqual(self.change_pw().status_code, 429)

    def test_success_resets_failures(self):
        for _ in range(3):
            self.change_pw(old='nope')
        self.assertEqual(self.change_pw(new='newpass1').status_code, 200)
        cache.delete(f'vendor_api_pw:{self.a.pk}')

    def test_new_password_rules(self):
        self.assertEqual(self.change_pw(new='12345').status_code, 400)                # kam az kam 6
        self.assertEqual(self.change_pw(new='x' * 129).status_code, 400)              # bohat lamba
        self.assertEqual(self.change_pw(new=PASSWORD).status_code, 400)               # purane jaisa
        self.assertEqual(self.post_json('vendor_api_password', {'old_password': PASSWORD}, self.a).status_code, 400)
        self.assertEqual(self.post_json('vendor_api_password', {}, self.a).status_code, 400)
        self.a.user.refresh_from_db()
        self.assertTrue(self.a.user.check_password(PASSWORD))

    def test_non_string_passwords_rejected(self):
        r = self.post_json('vendor_api_password', {'old_password': 123456, 'new_password': ['abcdefg']}, self.a)
        self.assertEqual(r.status_code, 400)

    def test_other_phones_push_tokens_removed_this_phone_kept(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK_A1)
        VendorPushToken.objects.create(profile=self.a, token=TOK_A2)
        VendorPushToken.objects.create(profile=self.b, token=TOK_B1)
        self.assertEqual(self.change_pw(push_token=TOK_A1).status_code, 200)
        left = set(VendorPushToken.objects.values_list('token', flat=True))
        self.assertEqual(left, {TOK_A1, TOK_B1})          # doosre phone ka (A2) gaya, doosre vendor ka B1 wahi

    def test_no_push_token_sent_removes_all_of_this_vendor_only(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK_A1)
        VendorPushToken.objects.create(profile=self.b, token=TOK_B1)
        self.assertEqual(self.change_pw().status_code, 200)
        self.assertEqual(set(VendorPushToken.objects.values_list('token', flat=True)), {TOK_B1})

    def test_failed_change_keeps_push_tokens(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK_A2)
        self.change_pw(old='nope')
        self.assertTrue(VendorPushToken.objects.filter(token=TOK_A2).exists())


class AccountDeleteTests(ProfileBase):
    def setUp(self):
        super().setUp()
        cache.delete(f'delete_account:{self.a.user.pk}')
        cache.delete(f'delete_account:{self.b.user.pk}')

    def test_delete_ok_wipes_and_closes_login(self):
        p1 = Product.objects.create(name='Atta', vendor=self.a.vendor)
        p2 = Product.objects.create(name='Chawal', vendor=self.b.vendor)
        VendorPushToken.objects.create(profile=self.a, token=TOK_A1)
        VendorPushToken.objects.create(profile=self.b, token=TOK_B1)
        self._order(vendor=self.a, status='delivered')       # purana mukammal order rukawat nahi
        headers = self.bearer(self.a)
        r = self.delete()
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['ok'])

        profile = VendorProfile.objects.get(pk=self.a.pk)           # row bachi rehti hai
        self.assertEqual(profile.business_name, 'Deleted Store')
        self.assertFalse(profile.is_approved)
        self.assertEqual(profile.store_status, 'closed')
        profile.vendor.refresh_from_db()
        self.assertEqual(profile.vendor.name, 'Deleted Vendor')
        self.assertIsNone(profile.vendor.contact_number)
        p1.refresh_from_db()
        self.assertFalse(p1.is_active)
        user = User.objects.get(pk=self.a.user.pk)
        self.assertFalse(user.is_active)
        self.assertFalse(user.has_usable_password())
        self.assertTrue(user.username.startswith('deleted_vendor_'))
        # token ab nahi chalta, push token gaye
        self.assertEqual(self.client.get(reverse('vendor_api_me'), **headers).status_code, 401)
        self.assertFalse(VendorPushToken.objects.filter(profile=self.a).exists())
        # doosre vendor ka kuch nahi bigra
        p2.refresh_from_db()
        self.assertTrue(p2.is_active)
        self.b.refresh_from_db()
        self.assertTrue(self.b.is_approved)
        self.assertTrue(VendorPushToken.objects.filter(token=TOK_B1).exists())

    def test_login_impossible_after_delete(self):
        self.delete()
        cache.clear()
        r = self.client.post(reverse('vendor_api_login'), json.dumps({'phone': PHONE_A, 'password': PASSWORD}),
                             content_type='application/json')
        self.assertEqual(r.status_code, 401)

    def test_needs_confirm(self):
        for bad in (False, None, 'no', 0):
            r = self.delete(confirm=bad)
            self.assertEqual(r.status_code, 400, bad)
            self.assertEqual(r.json()['code'], 'confirm')
        self.assertEqual(VendorProfile.objects.get(pk=self.a.pk).business_name, 'Ali Store')

    def test_wrong_password_not_deleted(self):
        r = self.delete(password='nope')
        self.assertEqual(r.status_code, 401)
        self.assertFalse(r.json()['ok'])
        self.assertEqual(VendorProfile.objects.get(pk=self.a.pk).business_name, 'Ali Store')
        self.assertTrue(User.objects.get(pk=self.a.user.pk).is_active)

    def test_missing_or_non_string_password(self):
        self.assertEqual(self.post_json('vendor_api_account_delete', {'confirm': True}, self.a).status_code, 401)
        self.assertEqual(self.post_json('vendor_api_account_delete', {'confirm': True, 'password': 123}, self.a).status_code, 401)

    def test_five_wrong_passwords_lock(self):
        for _ in range(5):
            self.assertEqual(self.delete(password='nope').status_code, 401)
        r = self.delete(password='nope')
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()['code'], 'locked')
        self.assertEqual(self.delete().status_code, 429)          # lock mein sahi password bhi nahi
        self.assertTrue(User.objects.get(pk=self.a.user.pk).is_active)

    def test_open_order_blocks_delete(self):
        for status in ('pending', 'confirmed', 'processing', 'ready', 'partially_delivered'):
            order = self._order(vendor=self.a, status=status)
            r = self.delete()
            self.assertEqual(r.status_code, 409, status)
            self.assertEqual(r.json()['code'], 'open_orders')
            order.delete()
        self.assertEqual(VendorProfile.objects.get(pk=self.a.pk).business_name, 'Ali Store')
        self.assertTrue(User.objects.get(pk=self.a.user.pk).is_active)

    def test_other_vendors_open_order_does_not_block(self):
        self._order(vendor=self.b, status='pending')
        self.assertEqual(self.delete().status_code, 200)
        self.assertEqual(VendorProfile.objects.get(pk=self.b.pk).business_name, 'Bilal Store')

    def test_cancelled_order_does_not_block(self):
        self._order(vendor=self.a, status='cancelled')
        self.assertEqual(self.delete().status_code, 200)

    def test_vendor_cannot_delete_another_vendor(self):
        # token A hai, password A ka hi chahiye; B ka account kabhi nahi chhua jata
        self.delete(profile=self.a)
        self.assertTrue(User.objects.get(pk=self.b.user.pk).is_active)


class WebDeleteStillWorksTests(ProfileBase):
    """Web `delete_account_vendor` ab shared helper use karta hai - behaviour wahi."""

    def test_web_delete(self):
        cache.delete(f'delete_account:{self.a.user.pk}')
        VendorPushToken.objects.create(profile=self.a, token=TOK_A1)
        self.client.force_login(self.a.user)
        r = self.client.post(reverse('delete_account_vendor'), {'password': PASSWORD, 'confirm_delete': '1'})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(VendorProfile.objects.get(pk=self.a.pk).business_name, 'Deleted Store')
        self.assertFalse(User.objects.get(pk=self.a.user.pk).is_active)
        self.assertFalse(VendorPushToken.objects.filter(profile=self.a).exists())

    def test_web_delete_blocked_by_open_order(self):
        cache.delete(f'delete_account:{self.a.user.pk}')
        self._order(vendor=self.a, status='pending')
        self.client.force_login(self.a.user)
        self.client.post(reverse('delete_account_vendor'), {'password': PASSWORD, 'confirm_delete': '1'})
        self.assertEqual(VendorProfile.objects.get(pk=self.a.pk).business_name, 'Ali Store')
        self.assertTrue(User.objects.get(pk=self.a.user.pk).is_active)
