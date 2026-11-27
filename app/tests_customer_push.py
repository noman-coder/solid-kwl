"""
Phase C2 tests: customer push (token API, logout / password reset par token hatna, order status alerts, test command).

Run:  python manage.py test app.tests_customer_push -v 2
Asli FCM ko koi call nahi jati: customer_push.push_async (ya rider_push.send_to_tokens) mock hota hai.
"""
import json
from io import StringIO
from unittest import mock

from django.contrib.auth.models import User
from django.core.cache import cache
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils.timezone import now

from app import customer_push
from app.customer import views_customer_api as api
from app.customer.views_customer_auth import normalize_phone
from app.models import CustomerOTP, CustomerPushToken, DeliveryInfo, RiderProfile, SaleOrder, Warehouse
from app.tests_customer_api import LOCMEM, MAIL, NEW_PW, NO_WA, PHONE_A, PHONE_B, make_customer
from app.tests_vendor_api import make_vendor

TOK1 = 'a' * 40
TOK2 = 'b' * 40
TOK3 = 'c' * 40
FCM_OK = {'type': 'service_account', 'project_id': 'demo', 'private_key': 'x'}


@override_settings(CACHES=LOCMEM, EMAIL_BACKEND=MAIL, **NO_WA)
class CustomerPushBase(TestCase):
    def setUp(self):
        cache.clear()
        self.a = make_customer('Ali', PHONE_A)
        self.b = make_customer('Bilal', PHONE_B)
        self.wh = Warehouse.objects.create(name='Main')
        self.shop = make_vendor('Shop One', '03007777777')       # store_name() ko VendorProfile chahiye
        self.vendor = self.shop.vendor
        self.n = 0
        # FCM "set hai" maano, par bhejna mock. Rider / vendor push kabhi asal thread / FCM na chalayen.
        mock.patch('app.rider_push._service_account', return_value=FCM_OK).start()
        self.real_push_async = customer_push.push_async          # asal function (mock se pehle)
        self.push = mock.patch('app.customer_push.push_async').start()
        mock.patch('app.rider_push.push_async').start()
        mock.patch('app.vendor_push.push_async').start()
        self.addCleanup(mock.patch.stopall)

    # ---- helpers
    def _order(self, profile=None, status='pending', **extra):
        self.n += 1
        return SaleOrder.objects.create(customer=(profile or self.a).customer, warehouse=self.wh, status=status,
                                        vendor=self.vendor, payment_method='cod', order_no=f'CP{self.n:04d}',
                                        **extra)

    def _rider(self, uname, name, phone):
        u = User.objects.create_user(uname, f'{uname}@x.com', 'secret12')
        return RiderProfile.objects.create(user=u, name=name, phone=phone, is_online=True)

    def _change(self, order, status, **fields):
        """Status badlo aur commit ke callbacks chalao (jaise asal mein commit ke baad chalte hain)."""
        with self.captureOnCommitCallbacks(execute=True):
            order.status = status
            for k, v in fields.items():
                setattr(order, k, v)
            order.save()

    def bearer(self, profile):
        return {'HTTP_AUTHORIZATION': 'Bearer ' + api._make_token(profile)}

    def post(self, name, body, profile=None, **extra):
        kw = self.bearer(profile) if profile is not None else {}
        kw.update(extra)
        return self.client.post(reverse(name), json.dumps(body), content_type='application/json', **kw)

    def sent(self, i=-1):
        """(tokens, title, body, kwargs) of the i-th push_async call."""
        c = self.push.call_args_list[i]
        return c.args[0], c.args[1], c.args[2], c.kwargs


# ---------------------------------------------------------------- push-token API

class PushTokenApiTests(CustomerPushBase):
    def reg(self, token=TOK1, profile=None, **extra):
        body = {'token': token}
        body.update(extra)
        return self.post('customer_api_push_token', body, profile or self.a)

    def test_requires_login(self):
        r = self.post('customer_api_push_token', {'token': TOK1})
        self.assertEqual(r.status_code, 401)
        self.assertFalse(CustomerPushToken.objects.exists())

    def test_get_not_allowed(self):
        r = self.client.get(reverse('customer_api_push_token'), **self.bearer(self.a))
        self.assertEqual(r.status_code, 405)

    def test_register_saves_token(self):
        r = self.reg(platform='android', device='Redmi Note 9')
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['ok'])
        t = CustomerPushToken.objects.get()
        self.assertEqual((t.customer_id, t.token, t.platform, t.device),
                         (self.a.customer_id, TOK1, 'android', 'Redmi Note 9'))

    def test_form_body_also_works(self):
        r = self.client.post(reverse('customer_api_push_token'), {'token': TOK1}, **self.bearer(self.a))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(CustomerPushToken.objects.filter(customer=self.a.customer).count(), 1)

    def test_bad_tokens_rejected(self):
        for bad in ('', 'short', 'x' * 20 + ' ' + 'y' * 20, 'z' * 300, None, 12345678901234567890, ['a' * 40]):
            r = self.post('customer_api_push_token', {'token': bad}, self.a)
            self.assertEqual(r.status_code, 400, bad)
            self.assertEqual(r.json()['code'], 'bad_token')
        self.assertEqual(self.post('customer_api_push_token', {}, self.a).status_code, 400)
        self.assertFalse(CustomerPushToken.objects.exists())

    def test_refresh_does_not_duplicate(self):
        self.reg()
        first = CustomerPushToken.objects.get().updated_at
        self.reg(device='New name')
        self.assertEqual(CustomerPushToken.objects.count(), 1)
        t = CustomerPushToken.objects.get()
        self.assertEqual(t.device, 'New name')
        self.assertGreaterEqual(t.updated_at, first)

    def test_token_moves_to_other_customer_on_same_phone(self):
        self.reg(profile=self.a)
        self.reg(profile=self.b)                       # Bilal ne usi phone par login kiya
        t = CustomerPushToken.objects.get()
        self.assertEqual(t.customer_id, self.b.customer_id)
        self.assertEqual(customer_push.tokens_for(self.a), [])
        self.assertEqual(customer_push.tokens_for(self.b), [TOK1])

    def test_max_five_phones_keeps_newest(self):
        toks = [f'{c}' * 40 for c in 'abcdefg'][:6]
        for t in toks:
            self.assertEqual(self.reg(token=t).status_code, 200)
        left = set(CustomerPushToken.objects.filter(customer=self.a.customer).values_list('token', flat=True))
        self.assertEqual(len(left), api.MAX_PUSH_TOKENS)
        self.assertNotIn(toks[0], left)               # sab se purana gaya
        self.assertIn(toks[-1], left)

    def test_limit_is_per_customer(self):
        for t in ('a' * 40, 'b' * 40, 'c' * 40, 'd' * 40, 'e' * 40):
            self.reg(token=t)
        self.reg(token='f' * 40, profile=self.b)
        self.assertEqual(CustomerPushToken.objects.filter(customer=self.a.customer).count(), 5)
        self.assertEqual(CustomerPushToken.objects.filter(customer=self.b.customer).count(), 1)

    def test_platform_defaults_to_android(self):
        self.reg()
        self.assertEqual(CustomerPushToken.objects.get().platform, 'android')


class LogoutAndResetTests(CustomerPushBase):
    def setUp(self):
        super().setUp()
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK1)
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK2)
        CustomerPushToken.objects.create(customer=self.b.customer, token=TOK3)

    def test_logout_removes_only_this_phones_token(self):
        r = self.post('customer_api_logout', {'push_token': TOK1}, self.a)
        self.assertEqual(r.status_code, 200)
        left = set(CustomerPushToken.objects.values_list('token', flat=True))
        self.assertEqual(left, {TOK2, TOK3})

    def test_logout_accepts_token_key_too(self):
        self.post('customer_api_logout', {'token': TOK2}, self.a)
        self.assertFalse(CustomerPushToken.objects.filter(token=TOK2).exists())

    def test_logout_without_token_still_ok_and_keeps_tokens(self):
        r = self.post('customer_api_logout', {}, self.a)
        self.assertEqual((r.status_code, r.json()['ok']), (200, True))
        self.assertEqual(CustomerPushToken.objects.count(), 3)

    def test_logout_with_no_body_at_all(self):
        r = self.client.post(reverse('customer_api_logout'), **self.bearer(self.a))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(CustomerPushToken.objects.count(), 3)

    def test_cannot_remove_other_customers_token(self):
        self.post('customer_api_logout', {'push_token': TOK3}, self.a)       # Ali, Bilal ka token bhej raha hai
        self.assertTrue(CustomerPushToken.objects.filter(token=TOK3, customer=self.b.customer).exists())

    def test_password_reset_removes_all_push_tokens_of_that_customer(self):
        self.post('customer_api_forgot_password', {'phone': PHONE_A})
        code = CustomerOTP.objects.filter(phone=normalize_phone(PHONE_A),
                                          purpose='forgot_password').latest('created_at').otp_code
        r = self.post('customer_api_reset_password',
                      {'phone': PHONE_A, 'code': code, 'password': NEW_PW, 'confirm_password': NEW_PW})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(set(CustomerPushToken.objects.values_list('token', flat=True)), {TOK3})   # Bilal ka rehta hai

    def test_failed_reset_keeps_tokens(self):
        self.post('customer_api_forgot_password', {'phone': PHONE_A})
        r = self.post('customer_api_reset_password',
                      {'phone': PHONE_A, 'code': '000000', 'password': NEW_PW, 'confirm_password': NEW_PW})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(CustomerPushToken.objects.count(), 3)


# ---------------------------------------------------------------- notify_customer

class NotifyCustomerTests(CustomerPushBase):
    def setUp(self):
        super().setUp()
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK1)
        CustomerPushToken.objects.create(customer=self.b.customer, token=TOK2)

    def test_sends_only_to_that_customers_phones(self):
        n = customer_push.notify_customer(self.a.customer, 'T', 'B', {'type': 'x'})
        self.assertEqual(n, 1)
        tokens, title, body, kw = self.sent()
        self.assertEqual((tokens, title, body), ([TOK1], 'T', 'B'))
        self.assertEqual(kw['channel_id'], customer_push.ORDER_CHANNEL)
        self.assertEqual(kw['ttl'], customer_push.TTL_ORDER)
        self.assertEqual(kw['data'], {'type': 'x'})

    def test_profile_and_plain_id_also_accepted(self):
        self.assertEqual(customer_push.notify_customer(self.a, 'T', 'B'), 1)                 # CustomerProfile
        self.assertEqual(customer_push.notify_customer(self.a.customer_id, 'T', 'B'), 1)     # id
        self.assertEqual(self.sent(0)[0], [TOK1])
        self.assertEqual(self.sent(1)[0], [TOK1])

    def test_offers_channel_uses_offer_ttl(self):
        customer_push.notify_customer(self.a.customer, 'T', 'B', channel=customer_push.OFFERS_CHANNEL)
        kw = self.sent()[3]
        self.assertEqual((kw['channel_id'], kw['ttl']), (customer_push.OFFERS_CHANNEL, customer_push.TTL_OFFER))

    def test_not_configured_does_nothing(self):
        with mock.patch('app.rider_push._service_account', return_value=None):
            self.assertEqual(customer_push.notify_customer(self.a.customer, 'T', 'B'), 0)
        self.assertEqual(self.push.call_count, 0)

    def test_no_tokens_does_nothing(self):
        CustomerPushToken.objects.all().delete()
        self.assertEqual(customer_push.notify_customer(self.a.customer, 'T', 'B'), 0)
        self.assertEqual(self.push.call_count, 0)

    def test_none_customer_does_nothing(self):
        self.assertEqual(customer_push.notify_customer(None, 'T', 'B'), 0)
        self.assertEqual(self.push.call_count, 0)

    def test_blocked_account_gets_no_push(self):
        self.a.user.is_active = False
        self.a.user.save()
        self.assertEqual(customer_push.notify_customer(self.a.customer, 'T', 'B'), 0)
        self.assertEqual(self.push.call_count, 0)

    def test_never_raises(self):
        with mock.patch('app.customer_push.tokens_for', side_effect=RuntimeError('db down')):
            self.assertEqual(customer_push.notify_customer(self.a.customer, 'T', 'B'), 0)
        self.push.side_effect = RuntimeError('FCM down')
        self.assertEqual(customer_push.notify_customer(self.a.customer, 'T', 'B'), 0)

    def test_dead_tokens_removed_after_send(self):
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 1, 'failed': 0, 'dead': [TOK1]}):
            res = customer_push._deliver([TOK1, TOK2], 'T', 'B')
        self.assertEqual(res['dead'], [TOK1])
        self.assertEqual(set(CustomerPushToken.objects.values_list('token', flat=True)), {TOK2})

    def test_real_push_async_starts_no_thread_when_not_configured(self):
        with mock.patch('app.rider_push._service_account', return_value=None):
            with mock.patch('app.customer_push.threading.Thread') as th:
                self.real_push_async([TOK1], 'T', 'B')
        th.assert_not_called()

    def test_real_push_async_starts_background_thread_when_configured(self):
        with mock.patch('app.customer_push.threading.Thread') as th:
            self.real_push_async([TOK1], 'T', 'B', data={'type': 'x'}, channel_id='order_updates')
            self.real_push_async([], 'T', 'B')                  # khali tokens: thread nahi
        self.assertEqual(th.call_count, 1)
        th.return_value.start.assert_called_once()
        self.assertTrue(th.call_args.kwargs['daemon'])


# ---------------------------------------------------------------- order status events

class OrderEventTests(CustomerPushBase):
    def setUp(self):
        super().setUp()
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK1)
        CustomerPushToken.objects.create(customer=self.b.customer, token=TOK2)

    def assertOnePush(self, event, order, customer_token=TOK1):
        self.assertEqual(self.push.call_count, 1, self.push.call_args_list)
        tokens, title, body, kw = self.sent()
        self.assertEqual(tokens, [customer_token])
        self.assertIn(order.order_no, title if event != 'rider_assigned' else body)
        self.assertEqual(kw['channel_id'], customer_push.ORDER_CHANNEL)
        self.assertEqual(kw['data']['type'], event)
        self.assertEqual(kw['data']['order_id'], order.pk)
        self.assertEqual(kw['data']['order_no'], order.order_no)
        return title, body

    def test_accept(self):
        o = self._order()
        self._change(o, 'confirmed', prep_minutes=25)
        title, body = self.assertOnePush('order_accepted', o)
        self.assertIn('qubool', title)
        self.assertIn('Shop One', body)
        self.assertIn('25 minute', body)

    def test_reject_with_reason(self):
        o = self._order()
        self._change(o, 'cancelled', reject_reason='Stock khatam')
        title, body = self.assertOnePush('order_rejected', o)
        self.assertIn('qubool nahi', title)
        self.assertIn('Stock khatam', body)

    def test_cancel_without_reason(self):
        o = self._order()
        self._change(o, 'cancelled')
        title, _body = self.assertOnePush('order_cancelled', o)
        self.assertIn('cancel', title)

    def test_ready_for_delivery(self):
        o = self._order(status='confirmed')
        self._change(o, 'ready')
        title, body = self.assertOnePush('order_ready', o)
        self.assertIn('tayyar', title)
        self.assertIn('Rider', body)

    def test_ready_for_pickup(self):
        o = self._order(status='confirmed')
        DeliveryInfo.objects.create(sale_order=o, delivery_type='customer_pickup', status='pending')
        self._change(o, 'ready')
        _title, body = self.assertOnePush('order_ready', o)
        self.assertIn('le jayein', body)

    def test_delivered(self):
        o = self._order(status='ready')
        self._change(o, 'delivered')
        title, _body = self.assertOnePush('order_delivered', o)
        self.assertIn('pahunch', title)

    def test_other_customer_gets_nothing(self):
        o = self._order(profile=self.b, status='pending')
        self._change(o, 'confirmed')
        self.assertEqual(self.push.call_count, 1)
        self.assertEqual(self.sent()[0], [TOK2])           # sirf Bilal ko, Ali ko nahi

    def test_statuses_without_push(self):
        o = self._order()
        for st in ('processing', 'partially_delivered', 'invoiced'):
            self._change(o, st)
        self.assertEqual(self.push.call_count, 0)

    def test_new_order_creation_does_not_push(self):
        with self.captureOnCommitCallbacks(execute=True):
            self._order(status='confirmed')
        self.assertEqual(self.push.call_count, 0)

    def test_save_without_status_change_does_not_push(self):
        o = self._order(status='confirmed')
        with self.captureOnCommitCallbacks(execute=True):
            o.notes = 'x'
            o.save()
        self.assertEqual(self.push.call_count, 0)

    def test_same_event_not_pushed_twice(self):
        o = self._order()
        self._change(o, 'confirmed')
        self._change(o, 'processing')
        self._change(o, 'confirmed')                       # dobara confirmed: wohi khabar dobara nahi
        self.assertEqual(self.push.call_count, 1)

    def test_status_flow_pushes_each_step_once(self):
        o = self._order()
        for st in ('confirmed', 'processing', 'ready', 'delivered'):
            self._change(o, st)
        types = [c.kwargs['data']['type'] for c in self.push.call_args_list]
        self.assertEqual(types, ['order_accepted', 'order_ready', 'order_delivered'])

    def test_push_waits_for_commit(self):
        o = self._order()
        with self.captureOnCommitCallbacks(execute=False) as cbs:
            o.status = 'confirmed'
            o.save()
        self.assertEqual(self.push.call_count, 0)           # abhi commit nahi hua
        for cb in cbs:
            cb()
        self.assertEqual(self.push.call_count, 1)

    def test_customer_without_app_costs_nothing(self):
        CustomerPushToken.objects.filter(customer=self.a.customer).delete()
        o = self._order()
        self._change(o, 'confirmed')
        self.assertEqual(self.push.call_count, 0)

    def test_push_failure_does_not_stop_status_change(self):
        o = self._order()
        self.push.side_effect = RuntimeError('FCM down')
        self._change(o, 'confirmed')                        # exception nahi aani chahiye
        o.refresh_from_db()
        self.assertEqual(o.status, 'confirmed')

    def test_hook_error_does_not_stop_status_change(self):
        o = self._order()
        with mock.patch('app.customer_push.notify_order_event', side_effect=RuntimeError('bug')):
            self._change(o, 'confirmed')
        o.refresh_from_db()
        self.assertEqual(o.status, 'confirmed')

    def test_message_build_error_does_not_stop_status_change(self):
        o = self._order()
        with mock.patch('app.customer_push._messages', side_effect=RuntimeError('bug')):
            self._change(o, 'confirmed')
        o.refresh_from_db()
        self.assertEqual(o.status, 'confirmed')
        self.assertEqual(self.push.call_count, 0)

    def test_not_configured_status_still_changes_no_push(self):
        o = self._order()
        with mock.patch('app.rider_push._service_account', return_value=None):
            self._change(o, 'confirmed')
        o.refresh_from_db()
        self.assertEqual(o.status, 'confirmed')
        self.assertEqual(self.push.call_count, 0)

    def test_cache_failure_skips_push_but_not_status(self):
        o = self._order()
        with mock.patch('app.customer_push.cache') as bad_cache:
            bad_cache.add.side_effect = RuntimeError('cache down')
            self._change(o, 'confirmed')
        o.refresh_from_db()
        self.assertEqual(o.status, 'confirmed')
        self.assertEqual(self.push.call_count, 0)


class DeliveryEventTests(CustomerPushBase):
    def setUp(self):
        super().setUp()
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK1)
        self.r1 = self._rider('rider_one', 'Hassan', '03211111111')
        self.r2 = self._rider('rider_two', 'Usman', '03212222222')

    def _assign(self, order, rider):
        with self.captureOnCommitCallbacks(execute=True):
            return DeliveryInfo.objects.create(sale_order=order, rider=rider, status='assigned',
                                               assigned_at=now())

    def _set(self, di, **fields):
        with self.captureOnCommitCallbacks(execute=True):
            for k, v in fields.items():
                setattr(di, k, v)
            di.save()

    def types(self):
        return [c.kwargs['data']['type'] for c in self.push.call_args_list]

    def test_rider_assigned(self):
        o = self._order(status='ready')
        self._assign(o, self.r1)
        self.assertEqual(self.types(), ['rider_assigned'])
        tokens, title, body, kw = self.sent()
        self.assertEqual(tokens, [TOK1])
        self.assertIn('Rider', title)
        self.assertIn('Hassan', body)
        self.assertIn(o.order_no, body)
        self.assertEqual(kw['data']['order_id'], o.pk)

    def test_same_rider_saved_again_no_second_push(self):
        o = self._order(status='ready')
        di = self._assign(o, self.r1)
        self._set(di, rider_fee=50)
        self.assertEqual(self.types(), ['rider_assigned'])

    def test_rider_changed_pushes_again_with_new_name(self):
        o = self._order(status='ready')
        di = self._assign(o, self.r1)
        self._set(di, rider=self.r2)
        self.assertEqual(self.types(), ['rider_assigned', 'rider_assigned'])
        self.assertIn('Usman', self.sent()[2])

    def test_on_the_way_once_for_picked_up_and_in_transit(self):
        o = self._order(status='ready')
        di = self._assign(o, self.r1)
        self._set(di, status='picked_up')
        self._set(di, status='in_transit')
        self.assertEqual(self.types(), ['rider_assigned', 'order_on_the_way'])
        self.assertIn('raste', self.sent()[1])

    def test_in_transit_directly_also_pushes(self):
        o = self._order(status='ready')
        di = self._assign(o, self.r1)
        self._set(di, status='in_transit')
        self.assertEqual(self.types(), ['rider_assigned', 'order_on_the_way'])

    def test_other_delivery_statuses_no_push(self):
        o = self._order(status='ready')
        with self.captureOnCommitCallbacks(execute=True):
            di = DeliveryInfo.objects.create(sale_order=o, status='pending')
        self._set(di, status='cancelled')
        self.assertEqual(self.push.call_count, 0)

    def test_other_customers_delivery_does_not_reach_ali(self):
        o = self._order(profile=self.b, status='ready')
        self._assign(o, self.r1)
        self.assertEqual(self.push.call_count, 0)           # Bilal ka koi token nahi

    def test_delivery_hook_error_does_not_stop_save(self):
        o = self._order(status='ready')
        with mock.patch('app.customer_push.notify_order_event', side_effect=RuntimeError('bug')):
            di = self._assign(o, self.r1)
        self.assertTrue(DeliveryInfo.objects.filter(pk=di.pk).exists())

    def test_full_journey_order_of_pushes(self):
        o = self._order()
        self._change(o, 'confirmed')
        self._change(o, 'ready')
        di = self._assign(o, self.r1)
        self._set(di, status='picked_up')
        self._change(o, 'delivered')
        self.assertEqual(self.types(), ['order_accepted', 'order_ready', 'rider_assigned',
                                        'order_on_the_way', 'order_delivered'])


# ---------------------------------------------------------------- management command

class TestCustomerPushCommandTests(CustomerPushBase):
    def run_cmd(self, *args):
        out = StringIO()
        call_command('test_customer_push', *args, stdout=out)
        return out.getvalue()

    def test_not_configured(self):
        with mock.patch('app.rider_push._service_account', return_value=None):
            with self.assertRaises(CommandError) as cm:
                self.run_cmd(PHONE_A)
        self.assertIn('FCM_SERVICE_ACCOUNT_JSON', str(cm.exception))

    def test_unknown_phone(self):
        with self.assertRaises(CommandError) as cm:
            self.run_cmd('03009990000')
        self.assertIn('nahi mila', str(cm.exception))

    def test_customer_without_token(self):
        with self.assertRaises(CommandError) as cm:
            self.run_cmd(PHONE_A)
        self.assertIn('push token nahi', str(cm.exception))

    def test_success_sends_to_that_customer_only(self):
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK1)
        CustomerPushToken.objects.create(customer=self.b.customer, token=TOK2)
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 1, 'failed': 0, 'dead': []}) as send:
            out = self.run_cmd(PHONE_A)
        self.assertEqual(send.call_args.args[0], [TOK1])
        self.assertEqual(send.call_args.kwargs['channel_id'], customer_push.ORDER_CHANNEL)
        self.assertEqual(send.call_args.kwargs['data'], {'type': 'test'})
        self.assertIn('tokens=1 sent=1 failed=0 dead_removed=0', out)

    def test_phone_given_in_plus92_form(self):
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK1)
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 1, 'failed': 0, 'dead': []}):
            out = self.run_cmd(normalize_phone(PHONE_A))
        self.assertIn('tokens=1', out)

    def test_offers_channel_and_dead_token_cleanup(self):
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK1)
        with mock.patch('app.rider_push.send_to_tokens',
                        return_value={'sent': 0, 'failed': 0, 'dead': [TOK1]}) as send:
            out = self.run_cmd(PHONE_A, '--channel', 'offers')
        self.assertEqual(send.call_args.kwargs['channel_id'], customer_push.OFFERS_CHANNEL)
        self.assertEqual(send.call_args.kwargs['ttl'], customer_push.TTL_OFFER)
        self.assertIn('dead_removed=1', out)
        self.assertFalse(CustomerPushToken.objects.exists())


# ---------------------------------------------------------------- model / migration sanity

class ModelSanityTests(CustomerPushBase):
    def test_token_unique(self):
        from django.db import IntegrityError, transaction
        CustomerPushToken.objects.create(customer=self.a.customer, token=TOK1)
        with self.assertRaises(IntegrityError), transaction.atomic():
            CustomerPushToken.objects.create(customer=self.b.customer, token=TOK1)

    def test_str(self):
        t = CustomerPushToken.objects.create(customer=self.a.customer, token='x' * 30 + 'ABCDEFGH')
        self.assertIn('Ali', str(t))
        self.assertTrue(str(t).endswith('ABCDEFGH'))
