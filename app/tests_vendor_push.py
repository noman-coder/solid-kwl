"""
Phase V2 tests: vendor push (token API, naya order / cancel / rider cash / review / stock alerts, test command).

Run:  python manage.py test app.tests_vendor_push
Asli FCM ko koi call nahi jati: vendor_push.push_async (ya rider_push.send_to_tokens) mock hota hai.
"""
import json
from decimal import Decimal
from io import StringIO
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils.timezone import now
from django.contrib.auth.models import User

from app import rider_push, vendor_push
from app.customer import store_orders
from app.customer import views_rider_api as rider_api
from app.customer import views_vendor_api as api
from app.models import (Customer, DeliveryInfo, Inventory, OrderReview, Product, RiderProfile, SaleOrder,
                        VendorPushToken, Warehouse)
from app.tests_vendor_api import PHONE_A, PHONE_B, make_vendor

TOK1 = 'a' * 40
TOK2 = 'b' * 40
TOK3 = 'c' * 40

LOCMEM = {'default': {'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'}}
FCM_OK = {'type': 'service_account', 'project_id': 'demo', 'private_key': 'x'}


@override_settings(CACHES=LOCMEM)       # dedupe keys asli (file) cache mein na jayen / purani keys test na bigarein
class VendorPushBase(TestCase):
    def setUp(self):
        cache.clear()
        self.wh = Warehouse.objects.create(name='Main')
        self.customer = Customer.objects.create(name='Zara', contact_number='03003333333', address='Lahore')
        self.a = make_vendor('Ali Store', PHONE_A)
        self.b = make_vendor('Bilal Store', PHONE_B)
        self.n = 0
        # FCM "set hai" maano, par bhejna mock
        mock.patch('app.rider_push._service_account', return_value=FCM_OK).start()
        self.push = mock.patch('app.vendor_push.push_async').start()
        mock.patch('app.rider_push.push_async').start()      # rider signals kabhi asal thread / FCM na chalayen
        self.addCleanup(mock.patch.stopall)

    def _order(self, vendor=None, status='pending'):
        self.n += 1
        return SaleOrder.objects.create(customer=self.customer, warehouse=self.wh, status=status,
                                        vendor=(vendor or self.a).vendor, payment_method='cod',
                                        order_no=f'VP{self.n:04d}')

    def bearer(self, profile):
        return {'HTTP_AUTHORIZATION': 'Bearer ' + api._make_token(profile)}

    def post_json(self, name, data, profile=None):
        kw = self.bearer(profile) if profile is not None else {}
        return self.client.post(reverse(name), json.dumps(data), content_type='application/json', **kw)

    def sent(self, i=-1):
        """(tokens, title, body, kwargs) of the i-th push_async call."""
        c = self.push.call_args_list[i]
        return c.args[0], c.args[1], c.args[2], c.kwargs


# ---------------------------------------------------------------- rider_push compat

class BuildMessageCompatTests(TestCase):
    def test_default_channel_and_ttl_unchanged_for_rider(self):
        m = rider_push.build_message('t' * 20, 'T', 'B')['message']['android']
        self.assertEqual(m['notification']['channel_id'], 'new_orders')
        self.assertEqual(m['ttl'], '300s')

    def test_custom_channel_and_ttl(self):
        m = rider_push.build_message('t' * 20, 'T', 'B', channel_id='updates', ttl='86400s')['message']['android']
        self.assertEqual(m['notification']['channel_id'], 'updates')
        self.assertEqual(m['ttl'], '86400s')


# ---------------------------------------------------------------- token API

class PushTokenApiTests(VendorPushBase):
    def reg(self, profile, token=TOK1, **extra):
        return self.post_json('vendor_api_push_token', dict(token=token, **extra), profile)

    def test_register_token(self):
        r = self.reg(self.a, device='Redmi Note 11')
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['ok'])
        t = VendorPushToken.objects.get(token=TOK1)
        self.assertEqual(t.profile, self.a)
        self.assertEqual(t.platform, 'android')
        self.assertEqual(t.device, 'Redmi Note 11')

    def test_requires_login(self):
        r = self.post_json('vendor_api_push_token', {'token': TOK1})
        self.assertEqual(r.status_code, 401)
        self.assertFalse(r.json()['ok'])
        self.assertEqual(VendorPushToken.objects.count(), 0)

    def test_get_not_allowed(self):
        r = self.client.get(reverse('vendor_api_push_token'), **self.bearer(self.a))
        self.assertEqual(r.status_code, 405)

    def test_unapproved_vendor_cannot_register(self):
        pending = make_vendor('Naya Store', '03005555555', approved=False)
        r = self.reg(pending)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()['code'], 'pending')
        self.assertEqual(VendorPushToken.objects.count(), 0)

    def test_bad_token_rejected(self):
        for bad in ('', 'short', 'x' * 300, 'has space ' + 'x' * 30):
            r = self.reg(self.a, token=bad)
            self.assertEqual(r.status_code, 400, bad)
            self.assertFalse(r.json()['ok'])
        self.assertEqual(VendorPushToken.objects.count(), 0)

    def test_refresh_same_token_no_duplicate(self):
        self.reg(self.a)
        self.reg(self.a, device='Naya naam')
        self.assertEqual(VendorPushToken.objects.filter(token=TOK1).count(), 1)
        self.assertEqual(VendorPushToken.objects.get(token=TOK1).device, 'Naya naam')

    def test_refresh_without_device_keeps_old_device(self):
        self.reg(self.a, device='Redmi')
        self.reg(self.a)
        self.assertEqual(VendorPushToken.objects.get(token=TOK1).device, 'Redmi')

    def test_token_moves_to_other_vendor(self):
        self.reg(self.a)
        self.reg(self.b)                     # isi phone par doosra vendor login
        t = VendorPushToken.objects.get(token=TOK1)
        self.assertEqual(t.profile, self.b)
        self.assertEqual(VendorPushToken.objects.count(), 1)

    def test_max_five_phones_per_vendor(self):
        toks = [f'{i}' * 30 for i in range(1, 8)]
        for t in toks:
            self.assertEqual(self.reg(self.a, token=t).status_code, 200)
        left = set(VendorPushToken.objects.filter(profile=self.a).values_list('token', flat=True))
        self.assertEqual(len(left), api.MAX_PUSH_TOKENS)
        self.assertIn(toks[-1], left)
        self.assertNotIn(toks[0], left)

    def test_other_vendors_tokens_untouched_by_trim(self):
        self.reg(self.b, token=TOK3)
        for i in range(1, 8):
            self.reg(self.a, token=f'{i}' * 30)
        self.assertTrue(VendorPushToken.objects.filter(token=TOK3, profile=self.b).exists())


class LogoutTokenTests(VendorPushBase):
    def setUp(self):
        super().setUp()
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        VendorPushToken.objects.create(profile=self.a, token=TOK2)
        VendorPushToken.objects.create(profile=self.b, token=TOK3)

    def test_logout_removes_that_phone_only(self):
        r = self.post_json('vendor_api_logout', {'push_token': TOK1}, self.a)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['ok'])
        left = set(VendorPushToken.objects.values_list('token', flat=True))
        self.assertEqual(left, {TOK2, TOK3})

    def test_logout_without_token_keeps_tokens(self):
        r = self.post_json('vendor_api_logout', {}, self.a)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(VendorPushToken.objects.count(), 3)

    def test_logout_cannot_delete_other_vendors_token(self):
        self.post_json('vendor_api_logout', {'push_token': TOK3}, self.a)
        self.assertTrue(VendorPushToken.objects.filter(token=TOK3).exists())

    def test_unapproved_vendor_logout_still_works(self):
        pending = make_vendor('Naya Store', '03005555555', approved=False)
        VendorPushToken.objects.create(profile=pending, token='d' * 40)
        r = self.post_json('vendor_api_logout', {'push_token': 'd' * 40}, pending)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(VendorPushToken.objects.filter(token='d' * 40).exists())


# ---------------------------------------------------------------- notify_vendor core

class NotifyVendorTests(VendorPushBase):
    def test_sends_to_all_phones_of_that_vendor_only(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        VendorPushToken.objects.create(profile=self.a, token=TOK2)
        VendorPushToken.objects.create(profile=self.b, token=TOK3)
        n = vendor_push.notify_vendor(self.a, 'T', 'B', {'type': 'x'})
        self.assertEqual(n, 2)
        tokens, title, body, kw = self.sent()
        self.assertEqual(set(tokens), {TOK1, TOK2})
        self.assertEqual((title, body), ('T', 'B'))
        self.assertEqual(kw['channel_id'], vendor_push.UPDATES_CHANNEL)
        self.assertEqual(kw['data'], {'type': 'x'})

    def test_accepts_vendor_profile_or_id(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        for who in (self.a, self.a.vendor, self.a.vendor_id):
            self.push.reset_mock()
            self.assertEqual(vendor_push.notify_vendor(who, 'T', 'B'), 1)
            self.assertEqual(self.sent()[0], [TOK1])

    def test_no_tokens_nothing_sent(self):
        self.assertEqual(vendor_push.notify_vendor(self.a, 'T', 'B'), 0)
        self.assertEqual(self.push.call_count, 0)

    def test_not_configured_is_silent(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        with mock.patch('app.rider_push._service_account', return_value=None):
            self.assertEqual(vendor_push.notify_vendor(self.a, 'T', 'B'), 0)
        self.assertEqual(self.push.call_count, 0)

    def test_push_async_does_nothing_when_not_configured(self):
        # asal push_async (mock nahi): config na ho to na thread bane na FCM call jaye
        mock.patch.stopall()
        with mock.patch('app.rider_push._service_account', return_value=None), \
                mock.patch('app.vendor_push.threading.Thread') as th, \
                mock.patch('app.rider_push.send_to_tokens') as send:
            vendor_push.push_async([TOK1], 'T', 'B')
        self.assertEqual(th.call_count, 0)
        self.assertEqual(send.call_count, 0)

    def test_exception_inside_never_escapes(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        self.push.side_effect = RuntimeError('boom')
        self.assertEqual(vendor_push.notify_vendor(self.a, 'T', 'B'), 0)      # raise nahi hua

    def test_dead_tokens_are_removed(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        VendorPushToken.objects.create(profile=self.a, token=TOK2)
        mock.patch.stopall()
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 1, 'failed': 0, 'dead': [TOK1]}):
            res = vendor_push._deliver([TOK1, TOK2], 'T', 'B')
        self.assertEqual(res['dead'], [TOK1])
        self.assertEqual(set(VendorPushToken.objects.values_list('token', flat=True)), {TOK2})


# ---------------------------------------------------------------- events

class NewOrderPushTests(VendorPushBase):
    def setUp(self):
        super().setUp()
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        VendorPushToken.objects.create(profile=self.b, token=TOK2)

    def test_new_order_pushes_that_vendor_on_orders_channel(self):
        order = self._order(self.a)
        with self.captureOnCommitCallbacks(execute=True):
            store_orders.notify_vendor_new_order(order)
        self.assertEqual(self.push.call_count, 1)
        tokens, title, body, kw = self.sent()
        self.assertEqual(tokens, [TOK1])                     # Bilal ko nahi
        self.assertIn('Naya order', title)
        self.assertIn(order.order_no, title)
        self.assertIn('Zara', body)
        self.assertEqual(kw['channel_id'], vendor_push.NEW_ORDERS_CHANNEL)
        self.assertEqual(kw['ttl'], vendor_push.TTL_ORDER)
        self.assertEqual(kw['data']['type'], 'new_order')
        self.assertEqual(kw['data']['order_id'], order.pk)

    def test_push_waits_for_commit(self):
        order = self._order(self.a)
        with self.captureOnCommitCallbacks(execute=False) as cbs:
            store_orders.notify_vendor_new_order(order)
        self.assertEqual(self.push.call_count, 0)            # abhi commit nahi hua
        self.assertEqual(len(cbs), 1)

    def test_shop_own_order_no_push(self):
        order = self._order(self.a)
        SaleOrder.objects.filter(pk=order.pk).update(vendor=None)
        order.refresh_from_db()
        with self.captureOnCommitCallbacks(execute=True):
            store_orders.notify_vendor_new_order(order)
        self.assertEqual(self.push.call_count, 0)

    def test_push_failure_does_not_stop_order(self):
        order = self._order(self.a)
        self.push.side_effect = RuntimeError('FCM down')
        with self.captureOnCommitCallbacks(execute=True):
            store_orders.notify_vendor_new_order(order)       # exception nahi aani chahiye
        self.assertTrue(SaleOrder.objects.filter(pk=order.pk).exists())

    def test_hook_error_does_not_stop_order(self):
        order = self._order(self.a)
        with mock.patch('app.vendor_push.notify_new_order', side_effect=RuntimeError('bug')):
            store_orders.notify_vendor_new_order(order)       # exception nahi aani chahiye

    def test_not_configured_no_crash_no_push(self):
        order = self._order(self.a)
        with mock.patch('app.rider_push._service_account', return_value=None):
            with self.captureOnCommitCallbacks(execute=True):
                store_orders.notify_vendor_new_order(order)
        self.assertEqual(self.push.call_count, 0)


class CancelPushTests(VendorPushBase):
    def test_cancel_pushes_on_updates_channel(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        order = self._order(self.a, status='cancelled')
        with self.captureOnCommitCallbacks(execute=True):
            vendor_push.notify_order_cancelled(order.pk)
        tokens, title, body, kw = self.sent()
        self.assertEqual(tokens, [TOK1])
        self.assertIn('cancel', title)
        self.assertEqual(kw['channel_id'], vendor_push.UPDATES_CHANNEL)
        self.assertEqual(kw['data']['type'], 'order_cancelled')

    def test_vendor_own_reject_does_not_push_vendor(self):
        # reject = vendor ka apna action: hum sirf customer-cancel hook se push dete hain, status badalne se nahi
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        order = self._order(self.a)
        with self.captureOnCommitCallbacks(execute=True):
            order.status = 'cancelled'
            order.save()
        self.assertEqual(self.push.call_count, 0)


class RiderCashPushTests(VendorPushBase):
    def setUp(self):
        super().setUp()
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        VendorPushToken.objects.create(profile=self.b, token=TOK2)
        u = User.objects.create_user('rider_vp', 'r@x.com', 'secret12')
        self.rider = RiderProfile.objects.create(user=u, name='RAZA', phone='03411111111')

    def test_function_pushes_vendor(self):
        with self.captureOnCommitCallbacks(execute=True):
            vendor_push.notify_rider_cash(self.a.vendor_id, 'RAZA', Decimal('1500'), 7)
        tokens, title, body, kw = self.sent()
        self.assertEqual(tokens, [TOK1])
        self.assertIn('RAZA', title)
        self.assertIn('1,500', title)
        self.assertEqual(kw['data'], {'type': 'rider_cash', 'handover_id': 7})

    def test_handover_api_pushes_receiving_vendor_only(self):
        so = self._order(self.a, status='delivered')
        DeliveryInfo.objects.create(sale_order=so, rider=self.rider, status='delivered', assigned_at=now(),
                                    cash_collected=Decimal('1000'), rider_fee=Decimal('50'), delivered_at=now())
        h = {'HTTP_AUTHORIZATION': 'Bearer ' + rider_api._make_token(self.rider)}
        with self.captureOnCommitCallbacks(execute=True):
            r = self.client.post(reverse('rider_api_cash_handover'),
                                 json.dumps({'receiver': 'vendor', 'vendor_id': self.a.vendor_id, 'amount': '500'}),
                                 content_type='application/json', **h)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.push.call_count, 1)
        self.assertEqual(self.sent()[0], [TOK1])
        self.assertEqual(self.sent()[3]['data']['type'], 'rider_cash')

    def test_admin_handover_does_not_push_vendor(self):
        so = self._order(self.a, status='delivered')
        DeliveryInfo.objects.create(sale_order=so, rider=self.rider, status='delivered', assigned_at=now(),
                                    cash_collected=Decimal('1000'), rider_fee=Decimal('50'), delivered_at=now())
        h = {'HTTP_AUTHORIZATION': 'Bearer ' + rider_api._make_token(self.rider)}
        with self.captureOnCommitCallbacks(execute=True):
            r = self.client.post(reverse('rider_api_cash_handover'),
                                 json.dumps({'receiver': 'admin', 'amount': '500'}),
                                 content_type='application/json', **h)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.push.call_count, 0)


class ReviewPushTests(VendorPushBase):
    def test_review_pushes_vendor_with_comment(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        order = self._order(self.a, status='delivered')
        OrderReview.objects.create(sale_order=order, vendor=self.a.vendor, vendor_rating=2,
                                   vendor_comment='Der se aaya')
        with self.captureOnCommitCallbacks(execute=True):
            vendor_push.notify_new_review(order.pk)
        tokens, title, body, kw = self.sent()
        self.assertEqual(tokens, [TOK1])
        self.assertIn('2/5', title)
        self.assertEqual(body, 'Der se aaya')
        self.assertEqual(kw['data']['type'], 'review')

    def test_rider_only_review_does_not_push_vendor(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        order = self._order(self.a, status='delivered')
        OrderReview.objects.create(sale_order=order, vendor=None, vendor_rating=None)
        with self.captureOnCommitCallbacks(execute=True):
            vendor_push.notify_new_review(order.pk)
        self.assertEqual(self.push.call_count, 0)


class StockPushTests(VendorPushBase):
    def setUp(self):
        super().setUp()
        VendorPushToken.objects.create(profile=self.a, token=TOK1)

    def _inv(self, stock=50, vendor=True, threshold=10):
        p = Product.objects.create(name='Biryani', vendor=self.a.vendor if vendor else None,
                                   low_stock_threshold=threshold)
        return Inventory.objects.create(product=p, warehouse=self.wh, stock=stock)

    def _set(self, inv, stock):
        inv.stock = stock
        with self.captureOnCommitCallbacks(execute=True):
            inv.save()

    def test_low_stock_pushes_once_per_day(self):
        inv = self._inv()
        self._set(inv, 5)
        self.assertEqual(self.push.call_count, 1)
        tokens, title, body, kw = self.sent()
        self.assertEqual(tokens, [TOK1])
        self.assertIn('kam', title)
        self.assertIn('Biryani', title)
        self.assertEqual(kw['data']['type'], 'low_stock')
        self.assertEqual(kw['data']['product_id'], inv.product_id)
        self.assertEqual(kw['channel_id'], vendor_push.UPDATES_CHANNEL)
        self._set(inv, 4)                                    # dobara kam: spam nahi
        self._set(inv, 3)
        self.assertEqual(self.push.call_count, 1)

    def test_out_of_stock_is_separate_alert(self):
        inv = self._inv()
        self._set(inv, 5)
        self._set(inv, 0)
        self.assertEqual(self.push.call_count, 2)
        self.assertEqual(self.sent()[3]['data']['type'], 'out_of_stock')
        self._set(inv, 0)
        self.assertEqual(self.push.call_count, 2)            # khatam wala bhi din mein ek hi dafa

    def test_straight_to_zero_is_out_of_stock(self):
        inv = self._inv()
        self._set(inv, 0)
        self.assertEqual(self.push.call_count, 1)
        self.assertEqual(self.sent()[3]['data']['type'], 'out_of_stock')

    def test_stock_above_threshold_no_push(self):
        inv = self._inv()
        self._set(inv, 20)
        self.assertEqual(self.push.call_count, 0)

    def test_shop_own_product_no_vendor_push(self):
        inv = self._inv(vendor=False)
        self._set(inv, 1)
        self.assertEqual(self.push.call_count, 0)

    def test_new_inventory_row_with_zero_is_ignored(self):
        p = Product.objects.create(name='Naya', vendor=self.a.vendor)
        with self.captureOnCommitCallbacks(execute=True):
            Inventory.objects.create(product=p, warehouse=self.wh, stock=0)
        self.assertEqual(self.push.call_count, 0)

    def test_threshold_is_per_product(self):
        inv = self._inv(threshold=3)
        self._set(inv, 5)                                    # 5 >= 3: theek
        self.assertEqual(self.push.call_count, 0)
        self._set(inv, 2)
        self.assertEqual(self.push.call_count, 1)

    def test_signal_error_never_breaks_stock_save(self):
        inv = self._inv()
        with mock.patch('app.vendor_push.check_stock_alert', side_effect=RuntimeError('bug')):
            self._set(inv, 1)                                # save phir bhi ho jati hai
        inv.refresh_from_db()
        self.assertEqual(inv.stock, 1)

    def test_not_configured_no_push(self):
        inv = self._inv()
        with mock.patch('app.rider_push._service_account', return_value=None):
            self._set(inv, 1)
        self.assertEqual(self.push.call_count, 0)


# ---------------------------------------------------------------- management command

class TestVendorPushCommandTests(VendorPushBase):
    def run_cmd(self, *args):
        out = StringIO()
        call_command('test_vendor_push', *args, stdout=out)
        return out.getvalue()

    def test_sends_test_push(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 1, 'failed': 0, 'dead': []}) as send:
            out = self.run_cmd(PHONE_A)
        self.assertEqual(send.call_args.args[0], [TOK1])
        self.assertEqual(send.call_args.kwargs['channel_id'], 'new_orders')
        self.assertIn('sent=1', out)

    def test_updates_channel_option(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 1, 'failed': 0, 'dead': []}) as send:
            self.run_cmd(PHONE_A, '--channel', 'updates')
        self.assertEqual(send.call_args.kwargs['channel_id'], 'updates')

    def test_dead_tokens_removed(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 0, 'failed': 0, 'dead': [TOK1]}):
            out = self.run_cmd(PHONE_A)
        self.assertIn('dead_removed=1', out)
        self.assertEqual(VendorPushToken.objects.count(), 0)

    def test_phone_format_normalized(self):
        VendorPushToken.objects.create(profile=self.a, token=TOK1)
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 1, 'failed': 0, 'dead': []}):
            self.assertIn('sent=1', self.run_cmd('+92 300 1111111'))

    def test_errors_are_clear(self):
        with mock.patch('app.rider_push._service_account', return_value=None):
            with self.assertRaisesRegex(CommandError, 'FCM_SERVICE_ACCOUNT_JSON'):
                self.run_cmd(PHONE_A)
        with self.assertRaisesRegex(CommandError, 'vendor nahi mila'):
            self.run_cmd('03999999999')
        with self.assertRaisesRegex(CommandError, 'push token nahi'):
            self.run_cmd(PHONE_A)
