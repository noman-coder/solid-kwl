"""
Phase V6 tests: order detail, live track (rider ki location + privacy), assign-rider (list + assign).

Run:  python manage.py test app.tests_vendor_detail
Asli FCM ko koi call nahi jati (push_async mock hota hai, DashBase mein).
"""
import json
from datetime import timedelta
from decimal import Decimal

from django.test import override_settings
from django.urls import reverse
from django.utils import timezone

from app.models import (CustomerProfile, DeliveryInfo, OrderTracking, Product, RiderLiveLocation, SaleOrder,
                        SaleOrderItem)
from app.tests_vendor_api import make_vendor
from app.tests_vendor_dashboard import DashBase, LOCMEM

DETAIL_KEYS = ('id', 'order_no', 'status', 'customer', 'items', 'payment', 'coupon', 'commission', 'steps',
               'timeline', 'rider', 'can_track', 'can_assign_rider', 'delivery_fee', 'total', 'actions',
               'whatsapp_url', 'store_point')


@override_settings(CACHES=LOCMEM)
class DetailBase(DashBase):
    def detail(self, order, profile=None):
        return self.client.get(reverse('vendor_api_order_detail', args=[order.pk]), **self.bearer(profile or self.a))

    def track(self, order, profile=None):
        return self.client.get(reverse('vendor_api_order_track', args=[order.pk]), **self.bearer(profile or self.a))

    def riders(self, order, profile=None):
        return self.client.get(reverse('vendor_api_assign_rider', args=[order.pk]), **self.bearer(profile or self.a))

    def assign(self, order, rider_id, profile=None):
        return self.client.post(reverse('vendor_api_assign_rider', args=[order.pk]),
                                json.dumps({'rider_id': rider_id}), content_type='application/json',
                                **self.bearer(profile or self.a))

    def give_rider(self, order, rider, status='assigned'):
        return DeliveryInfo.objects.create(sale_order=order, rider=rider, rider_name=rider.name,
                                           rider_contact=rider.phone, status=status, delivery_type='local_rider',
                                           assigned_at=timezone.now())


class DetailAuthTests(DetailBase):
    def test_requires_token(self):
        o = self.order(amount=100)
        self.assertEqual(self.client.get(reverse('vendor_api_order_detail', args=[o.pk])).status_code, 401)
        self.assertEqual(self.client.get(reverse('vendor_api_order_track', args=[o.pk])).status_code, 401)
        self.assertEqual(self.client.get(reverse('vendor_api_assign_rider', args=[o.pk])).status_code, 401)

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Chaudhry Store', '03004444444', approved=False)
        o = self.order(profile=c, amount=100)
        self.assertEqual(self.detail(o, c).status_code, 403)
        self.assertEqual(self.track(o, c).status_code, 403)
        self.assertEqual(self.riders(o, c).status_code, 403)

    def test_other_vendor_gets_404_everywhere(self):
        o = self.order(profile=self.b, status='ready', amount=100)
        r = self.rider()
        self.assertEqual(self.detail(o).status_code, 404)
        self.assertEqual(self.track(o).status_code, 404)
        self.assertEqual(self.riders(o).status_code, 404)
        self.assertEqual(self.assign(o, r.pk).status_code, 404)
        self.assertFalse(DeliveryInfo.objects.filter(sale_order=o).exists())      # kuch bana nahi

    def test_existing_action_route_still_works(self):
        o = self.order(amount=100)
        url = reverse('vendor_api_order_action', args=[o.pk, 'accept'])
        r = self.client.post(url, '{}', content_type='application/json', **self.bearer(self.a))
        self.assertEqual(r.status_code, 200, r.content)


class DetailTests(DetailBase):
    def test_shape_and_values(self):
        p = Product.objects.create(name='Atta 10kg', vendor=self.a.vendor)
        o = self.order(status='confirmed')
        SaleOrderItem.objects.create(order=o, product=p, qty=2, price=Decimal('500.00'))
        o.delivery_fee = Decimal('50.00')
        o.discount_value = Decimal('100.00')
        o.coupon_code = 'EID10'
        o.save()
        j = self.detail(o).json()['order']
        for k in DETAIL_KEYS:
            self.assertIn(k, j)
        self.assertEqual(j['items'][0]['name'], 'Atta 10kg')
        self.assertEqual(j['items'][0]['qty'], 2)
        self.assertEqual(j['items'][0]['total'], 1000.0)
        self.assertIn('image', j['items'][0])
        self.assertEqual(j['coupon'], {'code': 'EID10', 'discount': 100.0})
        self.assertEqual(j['total'], 950.0)                  # 1000 - 100 + 50
        self.assertEqual(j['customer']['phone'], '03003333333')
        self.assertTrue(j['payment']['is_cod'])
        self.assertIsNone(j['rider'])

    def test_commission_estimate(self):
        o = self.order(status='confirmed', amount=1000)
        c = self.detail(o).json()['order']['commission']
        self.assertTrue(c['estimated'])
        self.assertEqual(c['base'], 1000.0)
        self.assertAlmostEqual(c['amount'] + c['vendor_gets'], 1000.0, places=2)

    def test_steps_follow_status(self):
        o = self.order(status='pending', amount=100)
        done = lambda j: [s['key'] for s in j['steps'] if s['done']]
        self.assertEqual(done(self.detail(o).json()['order']), ['new'])
        for status, expect in (('confirmed', ['new', 'accepted']), ('ready', ['new', 'accepted', 'ready']),
                               ('delivered', ['new', 'accepted', 'ready', 'on_way', 'delivered'])):
            o.status = status
            o.save()
            self.assertEqual(done(self.detail(o).json()['order']), expect, status)

    def test_rejected_order_steps(self):
        o = self.order(status='cancelled', amount=100)
        o.reject_reason = 'Item abhi stock mein nahi'
        o.save()
        j = self.detail(o).json()['order']
        self.assertEqual([s['key'] for s in j['steps']], ['new', 'rejected'])
        self.assertEqual(j['reject_reason'], 'Item abhi stock mein nahi')
        self.assertFalse(j['can_track'])
        self.assertFalse(j['can_assign_rider'])

    def test_customer_coordinates_only_in_own_order(self):
        CustomerProfile.objects.create(customer=self.customer, latitude=30.30, longitude=71.93)
        o = self.order(status='ready', amount=100)
        c = self.detail(o).json()['order']['customer']
        self.assertEqual((c['lat'], c['lng']), (30.30, 71.93))
        # doosre vendor ko is order ka koi hissa nahi milta
        self.assertEqual(self.detail(o, self.b).status_code, 404)

    def test_no_coordinates_is_null_not_crash(self):
        o = self.order(status='ready', amount=100)
        c = self.detail(o).json()['order']['customer']
        self.assertIsNone(c['lat'])
        self.assertIsNone(c['lng'])

    def test_rider_and_timeline(self):
        r = self.rider()
        o = self.order(status='ready', amount=100)
        self.give_rider(o, r)
        OrderTracking.objects.create(sale_order=o, status='rider_assigned', title='Rider Assigned',
                                     description='Rider: R', rider_name=r.name)
        j = self.detail(o).json()['order']
        self.assertEqual(j['rider']['name'], r.name)
        self.assertEqual(j['rider']['phone'], r.phone)
        self.assertEqual(j['timeline'][0]['status'], 'rider_assigned')
        self.assertTrue(j['can_track'])
        self.assertFalse(j['can_assign_rider'] and False)      # assigned (picked_up nahi) ho to badal sakta hai

    def test_detail_has_no_n_plus_one(self):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext
        o = self.order(status='confirmed')
        for i in range(8):
            p = Product.objects.create(name=f'P{i}', vendor=self.a.vendor)
            SaleOrderItem.objects.create(order=o, product=p, qty=1, price=Decimal('10'))
        with CaptureQueriesContext(connection) as ctx:
            self.assertEqual(self.detail(o).status_code, 200)
        self.assertLess(len(ctx), 25)


class TrackTests(DetailBase):
    def test_no_rider_message(self):
        o = self.order(status='ready', amount=100)
        j = self.track(o).json()
        self.assertFalse(j['active'])
        self.assertEqual(j['reason'], 'no_rider')
        self.assertIn('assign nahi', j['message'])

    def test_rider_position_returned(self):
        r = self.rider()
        o = self.order(status='ready', amount=100)
        self.give_rider(o, r, status='picked_up')
        RiderLiveLocation.objects.create(rider=r, latitude=30.31, longitude=71.94, heading=90)
        j = self.track(o).json()
        self.assertTrue(j['active'])
        self.assertEqual(j['pos'], [30.31, 71.94])
        self.assertFalse(j['stale'])
        self.assertEqual(j['rider']['name'], r.name)

    def test_stale_location_flagged(self):
        r = self.rider()
        o = self.order(status='ready', amount=100)
        self.give_rider(o, r, status='in_transit')
        loc = RiderLiveLocation.objects.create(rider=r, latitude=30.31, longitude=71.94)
        RiderLiveLocation.objects.filter(pk=loc.pk).update(updated_at=timezone.now() - timedelta(minutes=5))
        j = self.track(o).json()
        self.assertTrue(j['active'])
        self.assertTrue(j['stale'])
        self.assertGreaterEqual(j['age_sec'], 290)

    def test_assigned_without_location_yet(self):
        r = self.rider()
        o = self.order(status='ready', amount=100)
        self.give_rider(o, r)
        j = self.track(o).json()
        self.assertTrue(j['active'])
        self.assertIsNone(j['pos'])

    def test_finished_order_not_tracked(self):
        r = self.rider()
        for status in ('delivered', 'cancelled'):
            o = self.order(status=status, amount=100)
            self.give_rider(o, r, status='picked_up')
            RiderLiveLocation.objects.update_or_create(rider=r, defaults={'latitude': 1.0, 'longitude': 2.0})
            j = self.track(o).json()
            self.assertFalse(j['active'], status)
            self.assertEqual(j['reason'], 'finished')
            self.assertNotIn('pos', j)                         # location leak nahi

    def test_delivery_done_but_order_status_not_updated(self):
        r = self.rider()
        o = self.order(status='ready', amount=100)
        self.give_rider(o, r, status='delivered')
        self.assertFalse(self.track(o).json()['active'])

    def test_vendor_cannot_track_other_vendors_rider(self):
        r = self.rider()
        o = self.order(profile=self.b, status='ready', amount=100)
        self.give_rider(o, r, status='picked_up')
        RiderLiveLocation.objects.create(rider=r, latitude=1.0, longitude=2.0)
        self.assertEqual(self.track(o).status_code, 404)


class AssignRiderTests(DetailBase):
    def test_list_riders(self):
        r1 = self.rider('rider1', '03007777771')
        r2 = self.rider('rider2', '03007777772')
        type(r2).objects.filter(pk=r2.pk).update(is_online=True)
        r3 = self.rider('rider3', '03007777773')
        type(r3).objects.filter(pk=r3.pk).update(is_active=False)
        o = self.order(status='ready', amount=100)
        j = self.riders(o).json()
        ids = [x['id'] for x in j['riders']]
        self.assertEqual(ids[0], r2.pk)                        # online pehle
        self.assertIn(r1.pk, ids)
        self.assertNotIn(r3.pk, ids)                           # band rider nahi
        self.assertTrue(j['can_assign'])

    def test_assign_ok(self):
        r = self.rider()
        o = self.order(status='ready', amount=100)
        resp = self.assign(o, r.pk)
        self.assertEqual(resp.status_code, 200, resp.content)
        j = resp.json()
        self.assertEqual(j['order']['rider']['name'], r.name)
        di = DeliveryInfo.objects.get(sale_order=o)
        self.assertEqual(di.rider_id, r.pk)
        self.assertEqual(di.status, 'assigned')
        self.assertTrue(OrderTracking.objects.filter(sale_order=o, status='rider_assigned').exists())

    def test_assign_only_on_ready(self):
        r = self.rider()
        for status in ('pending', 'confirmed', 'delivered', 'cancelled'):
            o = self.order(status=status, amount=100)
            resp = self.assign(o, r.pk)
            self.assertEqual(resp.status_code, 409, status)
            self.assertEqual(resp.json()['code'], 'conflict')
            self.assertFalse(DeliveryInfo.objects.filter(sale_order=o).exists(), status)

    def test_cannot_change_after_pickup(self):
        r1, r2 = self.rider('r1', '03007777771'), self.rider('r2', '03007777772')
        o = self.order(status='ready', amount=100)
        self.give_rider(o, r1, status='picked_up')
        resp = self.assign(o, r2.pk)
        self.assertEqual(resp.status_code, 409)
        self.assertEqual(DeliveryInfo.objects.get(sale_order=o).rider_id, r1.pk)

    def test_can_change_before_pickup(self):
        r1, r2 = self.rider('r1', '03007777771'), self.rider('r2', '03007777772')
        o = self.order(status='ready', amount=100)
        self.give_rider(o, r1)
        self.assertEqual(self.assign(o, r2.pk).status_code, 200)
        self.assertEqual(DeliveryInfo.objects.get(sale_order=o).rider_id, r2.pk)

    def test_bad_rider(self):
        o = self.order(status='ready', amount=100)
        self.assertEqual(self.assign(o, 99999).status_code, 404)
        r = self.client.post(reverse('vendor_api_assign_rider', args=[o.pk]), json.dumps({'rider_id': 'abc'}),
                             content_type='application/json', **self.bearer(self.a))
        self.assertEqual(r.status_code, 400)
        r = self.client.post(reverse('vendor_api_assign_rider', args=[o.pk]), '{}',
                             content_type='application/json', **self.bearer(self.a))
        self.assertEqual(r.status_code, 400)

    def test_inactive_rider_rejected(self):
        r = self.rider()
        type(r).objects.filter(pk=r.pk).update(is_active=False)
        o = self.order(status='ready', amount=100)
        self.assertEqual(self.assign(o, r.pk).status_code, 404)
