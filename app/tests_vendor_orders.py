"""
Phase V5 tests: vendor orders API (list + tabs + search + page, accept/reject/ready/delivered, poll).

Run:  python manage.py test app.tests_vendor_orders
Asli FCM ko koi call nahi jati (push_async mock hota hai, DashBase mein).
"""
import json
from decimal import Decimal

from django.db import connection
from django.test import override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse

from app.customer.views_vendor_portal import ORDER_TABS
from app.models import Customer, DeliveryInfo, SaleOrder
from app.tests_vendor_api import PHONE_A, PHONE_B
from app.tests_vendor_dashboard import DashBase, LOCMEM

ORDER_KEYS = ('id', 'order_no', 'status', 'status_label', 'tab', 'created_at', 'customer', 'items_count',
              'items_qty', 'items_preview', 'items_more', 'subtotal', 'delivery_fee', 'discount', 'total',
              'payment', 'notes', 'prep_minutes', 'reject_reason', 'responded_at', 'delivery', 'actions')


@override_settings(CACHES=LOCMEM)
class OrdersBase(DashBase):
    def orders_url(self, **params):
        url = reverse('vendor_api_orders')
        if params:
            url += '?' + '&'.join(f'{k}={v}' for k, v in params.items())
        return url

    def lst(self, profile=None, **params):
        return self.client.get(self.orders_url(**params), **self.bearer(profile or self.a))

    def lj(self, profile=None, **params):
        r = self.lst(profile, **params)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def act(self, order, action, body=None, profile=None):
        url = reverse('vendor_api_order_action', args=[order.pk, action])
        return self.client.post(url, json.dumps(body or {}), content_type='application/json',
                                **self.bearer(profile or self.a))

    def poll(self, profile=None):
        return self.client.get(reverse('vendor_api_orders_poll'), **self.bearer(profile or self.a))


# ---------------------------------------------------------------- auth

class OrdersAuthTests(OrdersBase):
    def test_list_requires_token(self):
        self.assertEqual(self.client.get(self.orders_url()).status_code, 401)

    def test_action_requires_token(self):
        o = self.order()
        url = reverse('vendor_api_order_action', args=[o.pk, 'accept'])
        self.assertEqual(self.client.post(url, '{}', content_type='application/json').status_code, 401)

    def test_poll_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_orders_poll')).status_code, 401)

    def test_unapproved_vendor_blocked_everywhere(self):
        from app.tests_vendor_api import make_vendor
        c = make_vendor('Chaudhry Store', '03004444444', approved=False)
        o = self.order(profile=c)
        self.assertEqual(self.lst(c).status_code, 403)
        self.assertEqual(self.lst(c).json()['code'], 'pending')
        self.assertEqual(self.act(o, 'accept', profile=c).status_code, 403)
        self.assertEqual(self.poll(c).status_code, 403)
        o.refresh_from_db()
        self.assertEqual(o.status, 'pending')           # action chala hi nahi

    def test_action_needs_post(self):
        o = self.order()
        url = reverse('vendor_api_order_action', args=[o.pk, 'accept'])
        self.assertEqual(self.client.get(url, **self.bearer(self.a)).status_code, 405)


# ---------------------------------------------------------------- list

class OrdersListTests(OrdersBase):
    def test_shape_and_values(self):
        o = self.order(amount=500)
        o.delivery_fee = Decimal('50.00')
        o.discount_value = Decimal('20.00')
        o.notes = 'Gate par dein'
        o.save()
        j = self.lj()
        self.assertTrue(j['ok'])
        for k in ('tab', 'page', 'has_more', 'counts', 'tabs', 'orders', 'reject_reasons', 'prep_options'):
            self.assertIn(k, j)
        self.assertEqual(len(j['orders']), 1)
        row = j['orders'][0]
        for k in ORDER_KEYS:
            self.assertIn(k, row)
        self.assertEqual(row['id'], o.pk)
        self.assertEqual(row['order_no'], o.order_no)
        self.assertEqual(row['status'], 'pending')
        self.assertEqual(row['tab'], 'new')
        self.assertEqual(row['subtotal'], 480.0)           # 500 - 20 discount
        self.assertEqual(row['delivery_fee'], 50.0)
        self.assertEqual(row['discount'], 20.0)
        self.assertEqual(row['total'], 530.0)              # 480 + 50
        self.assertEqual(row['notes'], 'Gate par dein')
        self.assertEqual(row['customer']['name'], 'Zara')
        self.assertEqual(row['customer']['phone'], '03003333333')
        self.assertEqual(row['customer']['address'], 'Lahore')
        self.assertEqual(row['items_count'], 1)
        self.assertEqual(row['items_preview'][0]['qty'], 1)
        self.assertEqual(row['items_preview'][0]['price'], 500.0)
        self.assertEqual(row['items_more'], 0)
        self.assertEqual(row['actions'], ['accept', 'reject'])
        self.assertIsNone(row['delivery'])
        self.assertIn('accept', [a for a in row['actions']])

    def test_payment_cod_default_and_online(self):
        cod = self.order()
        cod.payment_method = ''
        cod.save()
        online = self.order()
        online.payment_method = 'easypaisa'
        online.save()
        rows = {r['id']: r for r in self.lj()['orders']}
        self.assertEqual(rows[cod.pk]['payment'], {'method': 'cod', 'is_cod': True, 'label': 'COD'})
        self.assertFalse(rows[online.pk]['payment']['is_cod'])
        self.assertEqual(rows[online.pk]['payment']['label'], 'Online')

    def test_items_preview_is_limited(self):
        o = self.order()
        from app.models import Product, SaleOrderItem
        for i in range(5):
            p = Product.objects.create(name=f'Maal {i}', vendor=self.a.vendor)
            SaleOrderItem.objects.create(order=o, product=p, qty=2, price=Decimal('10'))
        row = self.lj()['orders'][0]
        self.assertEqual(row['items_count'], 5)
        self.assertEqual(len(row['items_preview']), 3)
        self.assertEqual(row['items_more'], 2)
        self.assertEqual(row['items_qty'], 10)

    def test_tabs_and_counts_match_web_order_tabs(self):
        for st in ('pending', 'pending', 'confirmed', 'processing', 'ready', 'delivered', 'cancelled', 'invoiced'):
            self.order(status=st)
        j = self.lj()
        self.assertEqual(j['counts'], {'new': 2, 'active': 3, 'done': 3})
        self.assertEqual([t['key'] for t in j['tabs']], list(ORDER_TABS.keys()))
        self.assertEqual({t['key']: t['count'] for t in j['tabs']}, j['counts'])
        self.assertEqual(len(self.lj(tab='new')['orders']), 2)
        self.assertEqual(len(self.lj(tab='active')['orders']), 3)
        self.assertEqual(len(self.lj(tab='done')['orders']), 3)
        for r in self.lj(tab='active')['orders']:
            self.assertEqual(r['tab'], 'active')

    def test_bad_tab_falls_back_to_new(self):
        self.order(status='pending')
        self.order(status='delivered')
        j = self.lj(tab='nonsense')
        self.assertEqual(j['tab'], 'new')
        self.assertEqual([r['status'] for r in j['orders']], ['pending'])

    def test_new_tab_oldest_first_others_newest_first(self):
        old = self.order(status='pending', days_ago=3)
        new = self.order(status='pending', days_ago=0)
        self.assertEqual([r['id'] for r in self.lj(tab='new')['orders']], [old.pk, new.pk])
        d_old = self.order(status='delivered', days_ago=5)
        d_new = self.order(status='delivered', days_ago=1)
        self.assertEqual([r['id'] for r in self.lj(tab='done')['orders']], [d_new.pk, d_old.pk])

    def test_only_own_orders(self):
        mine = self.order(profile=self.a)
        theirs = self.order(profile=self.b)
        ids = [r['id'] for r in self.lj(self.a)['orders']]
        self.assertIn(mine.pk, ids)
        self.assertNotIn(theirs.pk, ids)
        self.assertEqual(self.lj(self.a)['counts']['new'], 1)
        ids_b = [r['id'] for r in self.lj(self.b)['orders']]
        self.assertEqual(ids_b, [theirs.pk])

    def test_search_by_order_no_customer_name_and_phone(self):
        o1 = self.order()
        other = Customer.objects.create(name='Hamid Khan', contact_number='03009998888', address='Multan')
        o2 = self.order()
        o2.customer = other
        o2.save()
        self.assertEqual([r['id'] for r in self.lj(q=o1.order_no)['orders']], [o1.pk])
        self.assertEqual([r['id'] for r in self.lj(q='hamid')['orders']], [o2.pk])
        self.assertEqual([r['id'] for r in self.lj(q='0300999')['orders']], [o2.pk])
        self.assertEqual(self.lj(q='zzzz-nahi')['orders'], [])

    def test_search_never_leaks_other_vendor(self):
        theirs = self.order(profile=self.b)
        self.assertEqual(self.lj(self.a, q=theirs.order_no)['orders'], [])

    def test_pagination(self):
        for _ in range(25):
            self.order(status='pending')
        p1 = self.lj(tab='new', page=1)
        self.assertEqual(len(p1['orders']), 20)
        self.assertTrue(p1['has_more'])
        p2 = self.lj(tab='new', page=2)
        self.assertEqual(len(p2['orders']), 5)
        self.assertFalse(p2['has_more'])
        ids = [r['id'] for r in p1['orders']] + [r['id'] for r in p2['orders']]
        self.assertEqual(len(set(ids)), 25)                  # koi order dobara / gum nahi
        self.assertEqual(self.lj(tab='new', page='abc')['page'], 1)
        self.assertEqual(self.lj(tab='new', page=0)['page'], 1)

    def test_rider_info_shown_when_assigned(self):
        o = self.order(status='ready')
        rider = self.rider()
        DeliveryInfo.objects.create(sale_order=o, rider=rider, status='assigned')
        row = self.lj(tab='active')['orders'][0]
        self.assertEqual(row['delivery']['rider_name'], 'RIDER1')
        self.assertEqual(row['delivery']['rider_phone'], '03007777777')
        self.assertEqual(row['delivery']['status'], 'assigned')

    def test_allowed_actions_follow_status(self):
        expect = {'pending': ['accept', 'reject'], 'confirmed': ['ready'], 'processing': ['ready'],
                  'ready': ['delivered'], 'delivered': [], 'cancelled': [], 'invoiced': []}
        for st in expect:
            self.order(status=st)
        got = {}
        for tab in ORDER_TABS:
            for r in self.lj(tab=tab)['orders']:
                got[r['status']] = r['actions']
        self.assertEqual(got, expect)

    def test_reject_reasons_and_prep_options_for_app(self):
        j = self.lj()
        codes = [r['code'] for r in j['reject_reasons']]
        self.assertIn('out_of_stock', codes)
        self.assertIn('other', codes)
        self.assertEqual(j['prep_options'], [10, 20, 30, 45])

    def test_query_count_does_not_grow_with_orders(self):
        for _ in range(2):
            self.order(amount=100)
        with CaptureQueriesContext(connection) as small:
            self.lj()
        for _ in range(10):
            self.order(amount=100)
        with CaptureQueriesContext(connection) as big:
            self.lj()
        self.assertEqual(len(small), len(big))


# ---------------------------------------------------------------- actions

class OrderActionTests(OrdersBase):
    def test_accept_sets_confirmed_and_prep_minutes(self):
        o = self.order(amount=100)
        r = self.act(o, 'accept', {'prep_minutes': 20})
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertTrue(j['ok'])
        self.assertEqual(j['order']['status'], 'confirmed')
        self.assertEqual(j['order']['prep_minutes'], 20)
        self.assertEqual(j['next_tab'], 'active')
        self.assertEqual(j['counts'], {'new': 0, 'active': 1, 'done': 0})
        o.refresh_from_db()
        self.assertEqual(o.status, 'confirmed')
        self.assertEqual(o.prep_minutes, 20)
        self.assertIsNotNone(o.vendor_responded_at)

    def test_accept_without_prep_is_fine(self):
        o = self.order()
        self.assertEqual(self.act(o, 'accept').status_code, 200)
        o.refresh_from_db()
        self.assertEqual(o.status, 'confirmed')
        self.assertIsNone(o.prep_minutes)

    def test_accept_prep_as_string_digits(self):
        o = self.order()
        self.assertEqual(self.act(o, 'accept', {'prep_minutes': ' 45 '}).status_code, 200)
        o.refresh_from_db()
        self.assertEqual(o.prep_minutes, 45)

    def test_accept_prep_limits_1_to_600(self):
        for bad in (0, -5, 601, 99999, 'abc', 10.5):
            o = self.order()
            r = self.act(o, 'accept', {'prep_minutes': bad})
            self.assertEqual(r.status_code, 409, (bad, r.content))
            self.assertFalse(r.json()['ok'])
            self.assertTrue(r.json()['message'])
            o.refresh_from_db()
            self.assertEqual(o.status, 'pending', bad)          # status nahi badla
        for good in (1, 600):
            o = self.order()
            self.assertEqual(self.act(o, 'accept', {'prep_minutes': good}).status_code, 200)

    def test_reject_needs_reason(self):
        o = self.order()
        r = self.act(o, 'reject', {})
        self.assertEqual(r.status_code, 409)
        self.assertIn('wajah', r.json()['message'].lower())
        o.refresh_from_db()
        self.assertEqual(o.status, 'pending')

    def test_reject_with_unknown_reason_code(self):
        o = self.order()
        self.assertEqual(self.act(o, 'reject', {'reason_code': 'jhoota'}).status_code, 409)
        o.refresh_from_db()
        self.assertEqual(o.status, 'pending')

    def test_reject_other_needs_note(self):
        o = self.order()
        self.assertEqual(self.act(o, 'reject', {'reason_code': 'other'}).status_code, 409)
        r = self.act(o, 'reject', {'reason_code': 'other', 'reason_note': 'Rider nahi mil raha'})
        self.assertEqual(r.status_code, 200, r.content)
        o.refresh_from_db()
        self.assertEqual(o.reject_reason, 'Rider nahi mil raha')

    def test_reject_sets_cancelled_with_reason(self):
        o = self.order()
        r = self.act(o, 'reject', {'reason_code': 'out_of_stock', 'reason_note': 'Daal khatam'})
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertEqual(j['order']['status'], 'cancelled')
        self.assertEqual(j['next_tab'], 'done')
        self.assertIn('Daal khatam', j['order']['reject_reason'])
        o.refresh_from_db()
        self.assertEqual(o.status, 'cancelled')
        self.assertIn('Daal khatam', o.reject_reason)

    def test_full_journey_accept_ready_delivered(self):
        o = self.order(amount=250)
        self.assertEqual(self.act(o, 'accept', {'prep_minutes': 10}).status_code, 200)
        r = self.act(o, 'ready')
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()['order']['status'], 'ready')
        self.assertEqual(r.json()['order']['actions'], ['delivered'])
        r = self.act(o, 'delivered')
        self.assertEqual(r.status_code, 200, r.content)
        o.refresh_from_db()
        # delivered ke baad web ki tarah khud invoice ban sakta hai (na bane to delivered hi rehta hai)
        self.assertIn(o.status, ('delivered', 'invoiced'))
        self.assertEqual(r.json()['order']['status'], o.status)
        self.assertEqual(r.json()['next_tab'], 'done')
        self.assertEqual(r.json()['order']['actions'], [])

    def test_wrong_state_gives_409_with_fresh_order(self):
        o = self.order()                                   # pending: seedha ready/delivered nahi ho sakta
        for action in ('ready', 'delivered'):
            r = self.act(o, action)
            self.assertEqual(r.status_code, 409)
            j = r.json()
            self.assertFalse(j['ok'])
            self.assertEqual(j['code'], 'conflict')
            self.assertEqual(j['order']['status'], 'pending')
            o.refresh_from_db()
            self.assertEqual(o.status, 'pending')

    def test_second_tap_on_same_action_is_refused(self):
        """Do phone / double tap: pehla chalta hai, doosre ko saaf message aur order ki naya haalat."""
        o = self.order()
        first = self.act(o, 'accept', {'prep_minutes': 15})
        second = self.act(o, 'accept', {'prep_minutes': 30})
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 409)
        self.assertEqual(second.json()['order']['status'], 'confirmed')
        o.refresh_from_db()
        self.assertEqual(o.prep_minutes, 15)               # doosre ne pehle ka time nahi badla

    def test_reject_after_accept_is_refused(self):
        o = self.order()
        self.act(o, 'accept')
        r = self.act(o, 'reject', {'reason_code': 'store_busy'})
        self.assertEqual(r.status_code, 409)
        o.refresh_from_db()
        self.assertEqual(o.status, 'confirmed')

    def test_bad_action_name(self):
        o = self.order()
        r = self.act(o, 'delete')
        self.assertEqual(r.status_code, 400)
        self.assertFalse(r.json()['ok'])
        o.refresh_from_db()
        self.assertEqual(o.status, 'pending')

    def test_other_vendors_order_is_404_and_untouched(self):
        theirs = self.order(profile=self.b)
        for action in ('accept', 'reject', 'ready', 'delivered'):
            r = self.act(theirs, action, {'reason_code': 'store_busy'}, profile=self.a)
            self.assertEqual(r.status_code, 404, action)
            self.assertFalse(r.json()['ok'])
            self.assertEqual(r.json()['code'], 'not_found')
        theirs.refresh_from_db()
        self.assertEqual(theirs.status, 'pending')
        self.assertIsNone(theirs.vendor_responded_at)

    def test_unknown_order_id_is_404_json(self):
        url = reverse('vendor_api_order_action', args=[999999, 'accept'])
        r = self.client.post(url, '{}', content_type='application/json', **self.bearer(self.a))
        self.assertEqual(r.status_code, 404)
        self.assertEqual(r.json()['code'], 'not_found')

    def test_shop_own_order_without_vendor_is_not_actionable(self):
        o = self.order()
        o.vendor = None
        o.save()
        self.assertEqual(self.act(o, 'accept').status_code, 404)

    def test_form_encoded_body_also_works(self):
        o = self.order()
        url = reverse('vendor_api_order_action', args=[o.pk, 'accept'])
        r = self.client.post(url, {'prep_minutes': '25'}, **self.bearer(self.a))
        self.assertEqual(r.status_code, 200, r.content)
        o.refresh_from_db()
        self.assertEqual(o.prep_minutes, 25)

    def test_action_updates_dashboard_new_orders(self):
        o = self.order()
        self.assertEqual(self.dj()['new_orders'], 1)
        self.act(o, 'accept')
        self.assertEqual(self.dj()['new_orders'], 0)


# ---------------------------------------------------------------- poll

class OrdersPollTests(OrdersBase):
    def test_poll_counts_only_pending_of_this_vendor(self):
        a1 = self.order(profile=self.a, status='pending')
        a2 = self.order(profile=self.a, status='pending')
        self.order(profile=self.a, status='confirmed')
        self.order(profile=self.b, status='pending')
        j = self.poll(self.a).json()
        self.assertTrue(j['ok'])
        self.assertEqual(j['new'], 2)
        self.assertEqual(j['latest_id'], max(a1.pk, a2.pk))

    def test_poll_empty(self):
        j = self.poll().json()
        self.assertEqual(j['new'], 0)
        self.assertEqual(j['latest_id'], 0)

    def test_poll_drops_after_accept(self):
        o = self.order()
        self.assertEqual(self.poll().json()['new'], 1)
        self.act(o, 'accept')
        self.assertEqual(self.poll().json()['new'], 0)

    def test_poll_is_light(self):
        """Poll ke queries orders badhne se nahi badhte (sirf ginti + aakhri id)."""
        self.order(amount=10)
        with CaptureQueriesContext(connection) as small:
            self.poll()
        for _ in range(8):
            self.order(amount=10)
        with CaptureQueriesContext(connection) as big:
            self.poll()
        self.assertEqual(len(small), len(big))
