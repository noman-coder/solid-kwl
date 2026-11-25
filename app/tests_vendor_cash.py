"""
Phase V12 tests: rider cash handover API (list, confirm, reject, ownership, double tap, balance).

Run:  python manage.py test app.tests_vendor_cash
Asli FCM ko koi call nahi jati (VendorPushBase push mock karta hai).
"""
import json
from decimal import Decimal

from django.contrib.auth.models import User
from django.urls import reverse
from django.utils.timezone import now

from app.customer.views_rider_portal import rider_balances
from app.models import DeliveryInfo, RiderCashHandover, RiderProfile, RiderSettlement
from app.tests_vendor_push import VendorPushBase


class CashBase(VendorPushBase):
    def setUp(self):
        super().setUp()
        self.admin = User.objects.create_superuser('boss', 'boss@x.com', 'secret12')
        self.rider = self._rider('r1', '03211111111')
        self.rider2 = self._rider('r2', '03222222222')
        # rider1 ne Ali (a) ke 2 COD orders deliver kiye: 3000 + 2500 = 5500 cash uske paas
        self.d1 = self._delivered(self.rider, self.a, '3000')
        self.d2 = self._delivered(self.rider, self.a, '2500')

    def _rider(self, uname, phone):
        u = User.objects.create_user(uname, f'{uname}@x.com', 'secret12')
        return RiderProfile.objects.create(user=u, name=uname.upper(), phone=phone)

    def _delivered(self, rider, profile, cash):
        so = self._order(profile, status='delivered')
        return DeliveryInfo.objects.create(sale_order=so, rider=rider, status='delivered',
                                           cash_collected=Decimal(cash), rider_fee=Decimal('50'),
                                           delivered_at=now())

    def handover(self, profile=None, amount='3000', rider=None, receiver='vendor', status='pending', orders=()):
        profile = profile or self.a
        h = RiderCashHandover.objects.create(
            rider=rider or self.rider, receiver=receiver,
            vendor=profile.vendor if receiver == 'vendor' else None,
            amount=Decimal(amount), note='subah ka', status=status)
        if orders:
            h.orders.set(orders)
        return h

    def get(self, profile=None, **params):
        return self.client.get(reverse('vendor_api_rider_cash'), params, **self.bearer(profile or self.a))

    def act(self, pk, action, body=None, profile=None):
        return self.client.post(reverse('vendor_api_rider_cash_action', args=[pk, action]),
                                json.dumps(body or {}), content_type='application/json',
                                **self.bearer(profile or self.a))

    def in_hand(self):
        return rider_balances(RiderProfile.objects.get(pk=self.rider.pk))['cash_in_hand']


class CashListTests(CashBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_rider_cash')).status_code, 401)

    def test_unapproved_vendor_blocked(self):
        from app.tests_vendor_api import make_vendor
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.get(c).status_code, 403)

    def test_only_own_pending_shown(self):
        mine = self.handover(self.a, '3000', orders=[self.d1])
        self.handover(self.b, '1000', rider=self.rider2)           # doosre vendor ka
        self.handover(None, '500', receiver='admin')               # admin ka
        d = self.get().json()
        self.assertTrue(d['ok'])
        self.assertEqual([x['id'] for x in d['pending']], [mine.pk])
        self.assertEqual(d['summary']['pending_count'], 1)
        self.assertEqual(d['summary']['pending_amount'], 3000.0)

    def test_pending_json_has_rider_and_orders(self):
        h = self.handover(self.a, '3000', orders=[self.d1])
        p = self.get().json()['pending'][0]
        self.assertEqual(p['id'], h.pk)
        self.assertEqual(p['rider']['name'], 'R1')
        self.assertEqual(p['rider']['phone'], '03211111111')
        self.assertEqual(p['amount'], 3000.0)
        self.assertEqual(p['note'], 'subah ka')
        self.assertEqual(len(p['orders']), 1)
        self.assertEqual(p['orders'][0]['order_no'], self.d1.sale_order.order_no)
        self.assertEqual(p['orders'][0]['cash'], 3000.0)

    def test_history_excludes_pending_and_has_totals(self):
        self.handover(self.a, '1000', status='confirmed')
        self.handover(self.a, '2000', status='confirmed')
        rej = self.handover(self.a, '700', status='rejected')
        RiderCashHandover.objects.filter(pk=rej.pk).update(reject_reason='Raqam kam thi')
        self.handover(self.a, '300')
        d = self.get().json()
        self.assertEqual(len(d['history']), 3)
        self.assertTrue(all(x['status'] != 'pending' for x in d['history']))
        s = d['summary']
        self.assertEqual((s['confirmed_count'], s['confirmed_total'], s['rejected_count']), (2, 3000.0, 1))
        self.assertIn('Raqam kam thi', [x['reject_reason'] for x in d['history']])

    def test_history_pages(self):
        for _ in range(25):
            self.handover(self.a, '10', status='confirmed')
        p1 = self.get().json()
        self.assertEqual((len(p1['history']), p1['has_more']), (20, True))
        p2 = self.get(page=2).json()
        self.assertEqual((len(p2['history']), p2['has_more']), (5, False))
        self.assertEqual(p2['pending'], [])           # pending sirf page 1 par

    def test_empty(self):
        d = self.get().json()
        self.assertEqual((d['pending'], d['history']), ([], []))
        self.assertEqual(d['summary']['pending_count'], 0)

    def test_dashboard_pending_matches(self):
        self.handover(self.a, '3000')
        self.handover(self.a, '1000')
        dash = self.client.get(reverse('vendor_api_dashboard'), **self.bearer(self.a)).json()
        self.assertEqual(dash['rider_cash']['count'], 2)
        self.assertEqual(dash['rider_cash']['amount'], 4000.0)


class CashConfirmTests(CashBase):
    def test_confirm_makes_settlement_and_reduces_rider_cash(self):
        h = self.handover(self.a, '3000', orders=[self.d1])
        self.assertEqual(self.in_hand(), Decimal('5500'))
        r = self.act(h.pk, 'confirm')
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        self.assertEqual(body['handover']['status'], 'confirmed')
        self.assertEqual(body['summary']['pending_count'], 0)
        self.assertEqual(body['summary']['confirmed_total'], 3000.0)
        h.refresh_from_db()
        self.assertEqual(h.status, 'confirmed')
        self.assertEqual(h.decided_by_id, self.a.user_id)
        self.assertIsNotNone(h.settlement)
        self.assertEqual(h.settlement.kind, 'cash_in')
        self.assertEqual(self.in_hand(), Decimal('2500'))

    def test_double_confirm_only_one_settlement(self):
        h = self.handover(self.a, '3000')
        self.assertEqual(self.act(h.pk, 'confirm').status_code, 200)
        r = self.act(h.pk, 'confirm')
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'handover')
        self.assertEqual(RiderSettlement.objects.filter(kind='cash_in').count(), 1)
        self.assertEqual(self.in_hand(), Decimal('2500'))

    def test_confirm_after_reject_not_allowed(self):
        h = self.handover(self.a, '3000')
        self.act(h.pk, 'reject', {'reason': 'Raqam kam thi'})
        self.assertEqual(self.act(h.pk, 'confirm').status_code, 409)
        self.assertEqual(RiderSettlement.objects.count(), 0)

    def test_confirm_more_than_cash_in_hand_blocked(self):
        # admin pehle 4000 jama kar chuka -> rider ke paas 1500 hisab mein, handover 3000 ka
        RiderSettlement.objects.create(rider=self.rider, kind='cash_in', amount=Decimal('4000'),
                                       note='admin', created_by=self.admin)
        h = self.handover(self.a, '3000')
        r = self.act(h.pk, 'confirm')
        self.assertEqual(r.status_code, 409)
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')
        self.assertEqual(RiderSettlement.objects.filter(kind='cash_in').count(), 1)

    def test_amount_check_matches(self):
        h = self.handover(self.a, '3000.50')
        self.assertEqual(self.act(h.pk, 'confirm', {'amount': '3,000.50'}).status_code, 200)

    def test_amount_check_mismatch_blocks_confirm(self):
        h = self.handover(self.a, '3000')
        r = self.act(h.pk, 'confirm', {'amount': 2000})
        self.assertEqual((r.status_code, r.json()['code']), (409, 'changed'))
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')
        self.assertEqual(RiderSettlement.objects.count(), 0)

    def test_amount_check_garbage(self):
        h = self.handover(self.a, '3000')
        r = self.act(h.pk, 'confirm', {'amount': 'abc'})
        self.assertEqual((r.status_code, r.json()['code']), (400, 'validation'))
        self.assertEqual(self.act(h.pk, 'confirm', {'amount': 'NaN'}).status_code, 400)


class CashRejectTests(CashBase):
    def test_reject_needs_reason(self):
        h = self.handover(self.a, '3000')
        for body in ({}, {'reason': ''}, {'reason': '   '}):
            r = self.act(h.pk, 'reject', body)
            self.assertEqual((r.status_code, r.json()['code']), (400, 'validation'))
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')

    def test_reject_keeps_balance_and_saves_reason(self):
        h = self.handover(self.a, '3000')
        r = self.act(h.pk, 'reject', {'reason': 'Raqam kam thi'})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()['handover']['reject_reason'], 'Raqam kam thi')
        h.refresh_from_db()
        self.assertEqual((h.status, h.reject_reason), ('rejected', 'Raqam kam thi'))
        self.assertIsNone(h.settlement)
        self.assertEqual(RiderSettlement.objects.count(), 0)
        self.assertEqual(self.in_hand(), Decimal('5500'))          # balance wahi

    def test_reason_is_trimmed_to_200(self):
        h = self.handover(self.a, '3000')
        self.assertEqual(self.act(h.pk, 'reject', {'reason': 'x' * 500}).status_code, 200)
        h.refresh_from_db()
        self.assertEqual(len(h.reject_reason), 200)

    def test_double_reject(self):
        h = self.handover(self.a, '3000')
        self.assertEqual(self.act(h.pk, 'reject', {'reason': 'ghalat'}).status_code, 200)
        self.assertEqual(self.act(h.pk, 'reject', {'reason': 'ghalat'}).status_code, 409)


class CashOwnershipTests(CashBase):
    def test_other_vendor_cannot_act(self):
        h = self.handover(self.a, '3000')
        for action, body in (('confirm', {}), ('reject', {'reason': 'x'})):
            r = self.act(h.pk, action, body, profile=self.b)
            self.assertEqual((r.status_code, r.json()['code']), (404, 'not_found'))
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')
        self.assertEqual(RiderSettlement.objects.count(), 0)

    def test_admin_handover_not_actionable_by_vendor(self):
        h = self.handover(None, '500', receiver='admin')
        self.assertEqual(self.act(h.pk, 'confirm').status_code, 404)
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')

    def test_unknown_id_404(self):
        self.assertEqual(self.act(99999, 'confirm').status_code, 404)

    def test_bad_action(self):
        h = self.handover(self.a, '3000')
        self.assertEqual(self.act(h.pk, 'delete').status_code, 400)

    def test_action_requires_token_and_post(self):
        h = self.handover(self.a, '3000')
        url = reverse('vendor_api_rider_cash_action', args=[h.pk, 'confirm'])
        self.assertEqual(self.client.post(url, '{}', content_type='application/json').status_code, 401)
        self.assertEqual(self.client.get(url, **self.bearer(self.a)).status_code, 405)

    def test_unapproved_vendor_cannot_act(self):
        from app.tests_vendor_api import make_vendor
        c = make_vendor('Naya', '03004444444', approved=False)
        h = self.handover(c, '100')
        self.assertEqual(self.act(h.pk, 'confirm', profile=c).status_code, 403)
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')
