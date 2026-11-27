"""
Phase 3 tests: rider dashboard / history / order detail / profile / password API + GPS "assigned" par.

Run:  python manage.py test app.tests_rider_phase3
"""
import json
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth.models import User
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils.timezone import now

from app.customer import views_rider_api as api
from app.models import (Customer, DeliveryInfo, OrderReview, OrderTracking, RiderLiveLocation,
                        RiderProfile, SaleOrder, Vendor, VendorProfile, Warehouse)


class Phase3Base(TestCase):
    def setUp(self):
        self.wh = Warehouse.objects.create(name='Main')
        self.customer = Customer.objects.create(name='Zara', contact_number='03003333333', address='Lahore')
        self.vendor = Vendor.objects.create(name='Ali Store', contact_number='03001111111')
        vu = User.objects.create_user('u_ali', 'ali@x.com', 'secret12')
        VendorProfile.objects.create(vendor=self.vendor, user=vu, business_name='Ali Store', is_approved=True)
        self.rider = self._rider('r1', '03211111111')
        self.rider2 = self._rider('r2', '03222222222')
        self.n = 0
        # cache file-based hai: purani lock / throttle keys saaf karein (poori cache nahi)
        for r in (self.rider, self.rider2):
            cache.delete_many([f'rider_api_pw:{r.pk}', f'rloglast:{r.pk}'])

    def _rider(self, uname, phone):
        u = User.objects.create_user(uname, f'{uname}@x.com', 'secret12')
        return RiderProfile.objects.create(user=u, name=uname.upper(), phone=phone)

    def _order(self, rider, status='delivered', cash='1000', when=None, pm='cod'):
        self.n += 1
        so = SaleOrder.objects.create(customer=self.customer, warehouse=self.wh,
                                      status='delivered' if status == 'delivered' else 'ready',
                                      vendor=self.vendor, payment_method=pm, order_no=f'P{self.n:04d}')
        kw = dict(sale_order=so, rider=rider, status=status, assigned_at=now())
        if status == 'delivered':
            kw.update(cash_collected=Decimal(cash), rider_fee=Decimal('50'), delivered_at=when or now())
        if status == 'cancelled':
            kw.pop('assigned_at')
        return DeliveryInfo.objects.create(**kw)

    def h(self, rider=None):
        return {'HTTP_AUTHORIZATION': 'Bearer ' + api._make_token(rider or self.rider)}

    def get(self, name, rider=None, args=None, **q):
        return self.client.get(reverse(name, args=args), q, **self.h(rider))

    def post(self, name, data, rider=None, args=None):
        return self.client.post(reverse(name, args=args), json.dumps(data),
                                content_type='application/json', **self.h(rider))


class DashboardTests(Phase3Base):
    def test_requires_token(self):
        for n in ('rider_api_dashboard', 'rider_api_history', 'rider_api_profile'):
            self.assertEqual(self.client.get(reverse(n)).status_code, 401)

    def test_dashboard_numbers(self):
        self._order(self.rider, cash='3000')
        self._order(self.rider, cash='2500', when=now() - timedelta(days=3))
        self._order(self.rider, status='assigned')
        self._order(self.rider2, cash='9999')            # doosre rider ka - nazar na aaye
        d = self.get('rider_api_dashboard').json()
        self.assertTrue(d['ok'])
        self.assertEqual(d['today']['deliveries'], 1)
        self.assertEqual(d['today']['earned'], 50.0)
        self.assertEqual(d['week']['deliveries'], 2)
        self.assertEqual(d['cash_in_hand'], 5500.0)
        self.assertEqual(d['active_count'], 1)
        self.assertEqual(len(d['chart']), 7)
        self.assertEqual(d['chart'][-1]['deliveries'], 1)
        self.assertEqual(sum(x['deliveries'] for x in d['chart']), 2)
        self.assertTrue(d['limit_reached'])
        self.assertIn('cash_limit', [w['code'] for w in d['warnings']])
        self.assertIsNone(d['rating']['avg'])

    def test_dashboard_rating(self):
        di = self._order(self.rider)
        OrderReview.objects.create(sale_order=di.sale_order, rider=self.rider, rider_rating=4,
                                   rider_comment='Acha')
        self.assertEqual(self.get('rider_api_dashboard').json()['rating'], {'avg': 4.0, 'count': 1})


class HistoryTests(Phase3Base):
    def test_pagination_and_filters(self):
        for i in range(5):
            self._order(self.rider, when=now() - timedelta(days=i))
        self._order(self.rider, status='cancelled')
        self._order(self.rider2)
        r = self.get('rider_api_history', page_size=4).json()
        self.assertEqual(r['total'], 6)
        self.assertEqual(len(r['items']), 4)
        self.assertTrue(r['has_more'])
        r2 = self.get('rider_api_history', page_size=4, page=2).json()
        self.assertEqual(len(r2['items']), 2)
        self.assertFalse(r2['has_more'])
        only = self.get('rider_api_history', status='cancelled').json()
        self.assertEqual(only['total'], 1)
        day = (timezone_today() - timedelta(days=2)).isoformat()
        f = self.get('rider_api_history', **{'from': day, 'to': day, 'status': 'delivered'}).json()
        self.assertEqual(f['total'], 1)
        self.assertEqual(f['summary']['deliveries'], 1)

    def test_bad_date(self):
        self.assertEqual(self.get('rider_api_history', **{'from': 'kal'}).status_code, 400)


def timezone_today():
    from django.utils import timezone
    return timezone.localdate()


class OrderDetailTests(Phase3Base):
    def test_detail_and_timeline(self):
        di = self._order(self.rider, status='assigned')
        OrderTracking.objects.create(sale_order=di.sale_order, status='rider_assigned', title='Rider Assigned')
        r = self.get('rider_api_order_detail', args=[di.sale_order_id])
        self.assertEqual(r.status_code, 200)
        o = r.json()['order']
        self.assertEqual(o['vendor_id'], self.vendor.pk)
        self.assertEqual(o['delivery_status'], 'assigned')
        self.assertEqual([s['done'] for s in o['steps']], [True, False, False])
        self.assertEqual(len(o['timeline']), 1)
        self.assertTrue(o['tracking'])

    def test_other_riders_order_404(self):
        di = self._order(self.rider)
        self.assertEqual(self.get('rider_api_order_detail', rider=self.rider2, args=[di.sale_order_id]).status_code, 404)

    def test_old_orders_json_keys_kept(self):
        self._order(self.rider, status='assigned')
        d = self.get('rider_api_orders').json()
        m = d['mine'][0]
        for k in ('id', 'order_no', 'status', 'store', 'customer', 'items', 'total', 'is_cod', 'delivery_status'):
            self.assertIn(k, m)
        self.assertEqual(m['vendor_id'], self.vendor.pk)
        self.assertTrue(d['tracking'])               # assigned par bhi tracking


class ProfileTests(Phase3Base):
    def test_get_and_edit(self):
        p = self.get('rider_api_profile').json()['profile']
        self.assertEqual(p['phone'], '03211111111')
        r = self.post('rider_api_profile', {'name': 'Ali Raza', 'vehicle': 'Honda 70'})
        self.assertEqual(r.status_code, 200)
        self.rider.refresh_from_db()
        self.assertEqual((self.rider.name, self.rider.vehicle), ('Ali Raza', 'Honda 70'))
        self.assertEqual(self.rider.phone, '03211111111')
        self.assertEqual(self.post('rider_api_profile', {'phone': '0300'}).status_code, 400)
        self.assertEqual(self.post('rider_api_profile', {'name': 'x'}).status_code, 400)

    def test_password_change(self):
        self.assertEqual(self.post('rider_api_password', {'old_password': 'bad', 'new_password': 'newpass1'}).status_code, 401)
        self.assertEqual(self.post('rider_api_password', {'old_password': 'secret12', 'new_password': '123'}).status_code, 400)
        r = self.post('rider_api_password', {'old_password': 'secret12', 'new_password': 'newpass1'})
        self.assertEqual(r.status_code, 200)
        tok = r.json()['token']
        # purana token band, naya chalta hai
        self.assertEqual(self.client.get(reverse('rider_api_me'), **self.h()).status_code, 401)
        self.assertEqual(self.client.get(reverse('rider_api_me'), HTTP_AUTHORIZATION='Bearer ' + tok).status_code, 200)

    def test_password_lock_after_5_bad(self):
        for _ in range(5):
            self.post('rider_api_password', {'old_password': 'bad', 'new_password': 'newpass1'})
        self.assertEqual(self.post('rider_api_password', {'old_password': 'secret12', 'new_password': 'newpass1'}).status_code, 429)


class GpsAssignedTests(Phase3Base):
    def test_location_saved_on_assigned(self):
        self._order(self.rider, status='assigned')
        r = self.post('rider_api_location', {'lat': 31.5, 'lng': 74.3, 'acc': 10})
        self.assertTrue(r.json()['tracking'])
        self.assertEqual(RiderLiveLocation.objects.filter(rider=self.rider).count(), 1)

    def test_no_location_without_active_order(self):
        self._order(self.rider, status='delivered')
        r = self.post('rider_api_location', {'lat': 31.5, 'lng': 74.3})
        self.assertFalse(r.json()['tracking'])
        self.assertEqual(RiderLiveLocation.objects.count(), 0)
