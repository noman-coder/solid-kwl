"""
Rider push notification tests (order ready / rider assign / token API).

Run:  python manage.py test app.tests_rider_push
Asli FCM ko koi call nahi jati: rider_push.push_async mock hota hai.
"""
import json
from unittest import mock

from django.contrib.auth.models import User
from django.test import TestCase
from django.urls import reverse
from django.utils.timezone import now

from app.customer import views_rider_api as api
from app.models import (Customer, DeliveryInfo, RiderProfile, RiderPushToken, SaleOrder, Vendor,
                        VendorProfile, Warehouse)

TOK1 = 'a' * 40
TOK2 = 'b' * 40
TOK3 = 'c' * 40


class RiderPushBase(TestCase):
    def setUp(self):
        self.wh = Warehouse.objects.create(name='Main')
        self.customer = Customer.objects.create(name='Zara', contact_number='03003333333', address='Lahore')
        self.vendor = Vendor.objects.create(name='Ali Store', contact_number='03001111111')
        vu = User.objects.create_user('u_ali_push', 'ali@x.com', 'secret12')
        VendorProfile.objects.create(vendor=self.vendor, user=vu, business_name='Ali Store', is_approved=True)
        self.vendor_user = vu
        self.online = self._rider('rp1', '03411111111', online=True)
        self.offline = self._rider('rp2', '03422222222', online=False)
        self.n = 0

    def _rider(self, uname, phone, online):
        u = User.objects.create_user(uname, f'{uname}@x.com', 'secret12')
        return RiderProfile.objects.create(user=u, name=uname.upper(), phone=phone, is_online=online)

    def _order(self, status='confirmed'):
        self.n += 1
        return SaleOrder.objects.create(customer=self.customer, warehouse=self.wh, status=status,
                                        vendor=self.vendor, payment_method='cod', order_no=f'PU{self.n:04d}')

    def _make_ready(self, order):
        order.status = 'ready'
        with self.captureOnCommitCallbacks(execute=True):
            order.save()

    def h(self, rider):
        return {'HTTP_AUTHORIZATION': 'Bearer ' + api._make_token(rider)}

    def post(self, name, data, rider):
        return self.client.post(reverse(name), json.dumps(data), content_type='application/json', **self.h(rider))


class PushSignalTests(RiderPushBase):
    def setUp(self):
        super().setUp()
        RiderPushToken.objects.create(rider=self.online, token=TOK1)
        RiderPushToken.objects.create(rider=self.offline, token=TOK2)
        p1 = mock.patch('app.rider_push.is_configured', return_value=True)
        p2 = mock.patch('app.rider_push.push_async')
        p1.start()
        self.push = p2.start()
        self.addCleanup(mock.patch.stopall)

    def test_ready_pushes_only_online_rider(self):
        self._make_ready(self._order())
        self.assertEqual(self.push.call_count, 1)
        tokens, title = self.push.call_args[0][0], self.push.call_args[0][1]
        self.assertEqual(tokens, [TOK1])
        self.assertIn('Naya order', title)

    def test_no_push_if_not_transition_to_ready(self):
        o = self._order(status='ready')
        with self.captureOnCommitCallbacks(execute=True):
            o.save()                       # status wahi: koi push nahi
        self.assertEqual(self.push.call_count, 0)

    def test_no_push_if_rider_already_chosen(self):
        o = self._order()
        DeliveryInfo.objects.create(sale_order=o, rider=self.online, status='assigned', assigned_at=now())
        self._make_ready(o)
        self.assertEqual(self.push.call_count, 0)

    def test_busy_rider_skipped(self):
        for _ in range(3):
            DeliveryInfo.objects.create(sale_order=self._order(status='ready'), rider=self.online,
                                        status='assigned', assigned_at=now())
        self.push.reset_mock()
        self._make_ready(self._order())
        self.assertEqual(self.push.call_count, 0)

    def test_vendor_assign_pushes_that_rider_even_if_offline(self):
        o = self._order(status='ready')
        with self.captureOnCommitCallbacks(execute=True):
            DeliveryInfo.objects.create(sale_order=o, rider=self.offline, status='assigned',
                                        assigned_at=now(), created_by=self.vendor_user)
        self.assertEqual(self.push.call_count, 1)
        self.assertEqual(self.push.call_args[0][0], [TOK2])
        self.assertIn('Order aap ko mila', self.push.call_args[0][1])

    def test_self_accept_does_not_push(self):
        o = self._order(status='ready')
        with self.captureOnCommitCallbacks(execute=True):
            DeliveryInfo.objects.create(sale_order=o, rider=self.online, status='assigned',
                                        assigned_at=now(), created_by=self.online.user)
        self.assertEqual(self.push.call_count, 0)


class PushTokenApiTests(RiderPushBase):
    def test_register_and_move_token(self):
        r = self.post('rider_api_push_token', {'token': TOK1}, self.online)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(RiderPushToken.objects.get(token=TOK1).rider, self.online)
        # isi phone par dusra rider login kare: token usi ka ho jata hai
        self.post('rider_api_push_token', {'token': TOK1}, self.offline)
        self.assertEqual(RiderPushToken.objects.get(token=TOK1).rider, self.offline)
        self.assertEqual(RiderPushToken.objects.filter(token=TOK1).count(), 1)

    def test_bad_token_rejected(self):
        self.assertEqual(self.post('rider_api_push_token', {'token': 'short'}, self.online).status_code, 400)

    def test_requires_login(self):
        r = self.client.post(reverse('rider_api_push_token'), json.dumps({'token': TOK1}),
                             content_type='application/json')
        self.assertEqual(r.status_code, 401)

    def test_logout_removes_that_token_only(self):
        RiderPushToken.objects.create(rider=self.online, token=TOK1)
        RiderPushToken.objects.create(rider=self.online, token=TOK3)
        r = self.post('rider_api_logout', {'push_token': TOK1}, self.online)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(list(RiderPushToken.objects.filter(rider=self.online).values_list('token', flat=True)), [TOK3])
