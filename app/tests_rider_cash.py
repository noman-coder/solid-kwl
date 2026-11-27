"""
Phase 1 tests: rider cash handover API.

Run:  python manage.py test app.tests_rider_cash
"""
import json
from decimal import Decimal

from django.contrib.auth.models import User
from django.test import TestCase
from django.urls import reverse
from django.utils.timezone import now

from app.customer import views_rider_api as api
from app.models import (Customer, DeliveryInfo, Notification, RiderCashHandover, RiderProfile,
                        RiderSettlement, SaleOrder, Vendor, VendorProfile, Warehouse)


class RiderCashBase(TestCase):
    def setUp(self):
        self.wh = Warehouse.objects.create(name='Main')
        self.customer = Customer.objects.create(name='Zara', contact_number='03003333333', address='Lahore')
        self.vendor = Vendor.objects.create(name='Ali Store', contact_number='03001111111')
        self.vuser = User.objects.create_user('u_ali', 'ali@x.com', 'secret12')
        VendorProfile.objects.create(vendor=self.vendor, user=self.vuser,
                                     business_name='Ali Store', is_approved=True)
        self.other_vendor = Vendor.objects.create(name='Other Store', contact_number='03002222222')
        self.admin = User.objects.create_superuser('boss', 'boss@x.com', 'secret12')

        self.rider = self._rider('r1', '03211111111')
        self.rider2 = self._rider('r2', '03222222222')
        self.n = 0
        # rider1: vendor ke 2 COD orders (3000 + 2500) = 5500
        self.d1 = self._delivered(self.rider, self.vendor, '3000')
        self.d2 = self._delivered(self.rider, self.vendor, '2500')

    def _rider(self, uname, phone):
        u = User.objects.create_user(uname, f'{uname}@x.com', 'secret12')
        return RiderProfile.objects.create(user=u, name=uname.upper(), phone=phone)

    def _delivered(self, rider, vendor, cash):
        self.n += 1
        so = SaleOrder.objects.create(customer=self.customer, warehouse=self.wh, status='delivered',
                                      vendor=vendor, payment_method='cod', order_no=f'T{self.n:04d}')
        return DeliveryInfo.objects.create(sale_order=so, rider=rider, status='delivered',
                                           cash_collected=Decimal(cash), rider_fee=Decimal('50'),
                                           delivered_at=now())

    def post(self, rider, **data):
        return self.client.post(reverse('rider_api_cash_handover'), json.dumps(data),
                                content_type='application/json',
                                HTTP_AUTHORIZATION='Bearer ' + api._make_token(rider))

    def get(self, name, rider=None, **q):
        return self.client.get(reverse(name), q,
                               HTTP_AUTHORIZATION='Bearer ' + api._make_token(rider or self.rider))


class HandoverTests(RiderCashBase):
    def test_requires_token(self):
        r = self.client.post(reverse('rider_api_cash_handover'), '{}', content_type='application/json')
        self.assertEqual(r.status_code, 401)

    def test_admin_handover_creates_pending_and_notifies(self):
        r = self.post(self.rider, receiver='admin', amount='1000', note='subah ka')
        self.assertEqual(r.status_code, 200, r.content)
        h = RiderCashHandover.objects.get()
        self.assertEqual((h.receiver, h.status, h.amount), ('admin', 'pending', Decimal('1000.00')))
        self.assertIsNone(h.vendor)
        self.assertTrue(Notification.objects.filter(user=self.admin).exists())
        # pending par settlement nahi banti: cash_in_hand abhi kam nahi hota
        self.assertEqual(RiderSettlement.objects.count(), 0)

    def test_vendor_handover_notifies_vendor(self):
        r = self.post(self.rider, receiver='vendor', vendor_id=self.vendor.pk, amount='500')
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(RiderCashHandover.objects.get().vendor_id, self.vendor.pk)
        self.assertTrue(Notification.objects.filter(user=self.vuser).exists())

    def test_vendor_must_be_one_of_riders_vendors(self):
        r = self.post(self.rider, receiver='vendor', vendor_id=self.other_vendor.pk, amount='500')
        self.assertEqual(r.status_code, 400)
        r = self.post(self.rider, receiver='vendor', amount='500')
        self.assertEqual(r.status_code, 400)
        self.assertEqual(RiderCashHandover.objects.count(), 0)

    def test_partial_then_rest_and_over_limit(self):
        self.assertEqual(self.post(self.rider, receiver='admin', amount='2000').status_code, 200)
        # cash 5500, pending 2000 -> baqi 3500
        w = self.get('rider_api_wallet').json()
        self.assertEqual(w['cash_in_hand'], 5500.0)
        self.assertEqual(w['pending_handover'], 2000.0)
        self.assertEqual(w['available_to_handover'], 3500.0)
        r = self.post(self.rider, receiver='admin', amount='3600')
        self.assertEqual(r.status_code, 409)
        self.assertEqual(self.post(self.rider, receiver='admin', amount='3500').status_code, 200)
        self.assertEqual(self.post(self.rider, receiver='admin', amount='1').status_code, 409)

    def test_bad_amounts(self):
        for bad in ('0', '-5', 'abc', '', 'NaN', 'Infinity'):
            r = self.post(self.rider, receiver='admin', amount=bad)
            self.assertEqual(r.status_code, 400, bad)
        self.assertEqual(RiderCashHandover.objects.count(), 0)

    def test_double_submit_makes_one(self):
        self.assertEqual(self.post(self.rider, receiver='admin', amount='1000').status_code, 200)
        self.assertEqual(self.post(self.rider, receiver='admin', amount='1000').status_code, 409)
        self.assertEqual(RiderCashHandover.objects.count(), 1)

    def test_rider_without_cash_cannot_handover(self):
        self.assertEqual(self.post(self.rider2, receiver='admin', amount='10').status_code, 409)

    def test_order_ids_validation(self):
        ok = self.post(self.rider, receiver='vendor', vendor_id=self.vendor.pk, amount='3000',
                       order_ids=[self.d1.pk])
        self.assertEqual(ok.status_code, 200, ok.content)
        self.assertEqual(list(RiderCashHandover.objects.get().orders.all()), [self.d1])
        # chune hue order ke cash se zyada
        r = self.post(self.rider, receiver='vendor', vendor_id=self.vendor.pk, amount='2600',
                      order_ids=[self.d2.pk])
        self.assertEqual(r.status_code, 400)
        # kisi aur rider ka order
        d3 = self._delivered(self.rider2, self.vendor, '100')
        r = self.post(self.rider, receiver='admin', amount='50', order_ids=[d3.pk])
        self.assertEqual(r.status_code, 400)

    def test_confirmed_settlement_reduces_cash_in_hand(self):
        """Phase 2 ka confirm RiderSettlement(cash_in) banayega; balances usi se chalte hain."""
        h = RiderCashHandover.objects.create(rider=self.rider, receiver='admin', amount=Decimal('1000'))
        s = RiderSettlement.objects.create(rider=self.rider, kind='cash_in', amount=Decimal('1000'))
        h.status, h.settlement = 'confirmed', s
        h.save()
        w = self.get('rider_api_wallet').json()
        self.assertEqual(w['cash_in_hand'], 4500.0)
        self.assertEqual(w['pending_handover'], 0.0)


class WalletTests(RiderCashBase):
    def test_wallet_shape_and_vendor_breakup(self):
        w = self.get('rider_api_wallet').json()
        self.assertTrue(w['ok'])
        self.assertEqual(w['cash_limit'], 5000.0)
        self.assertTrue(w['limit_reached'])            # 5500 >= 5000
        self.assertEqual(w['earned'], 100.0)
        self.assertEqual(w['vendors'], [{'vendor_id': self.vendor.pk, 'name': w['vendors'][0]['name']}])
        vw = w['vendor_wise'][0]
        self.assertEqual((vw['orders'], vw['collected'], vw['balance']), (2, 5500.0, 5500.0))

    def test_rider_sees_only_own_data(self):
        self.post(self.rider, receiver='admin', amount='100')
        self.assertEqual(self.get('rider_api_wallet', self.rider2).json()['handovers'], [])
        self.assertEqual(self.get('rider_api_handovers', self.rider2).json()['handovers'], [])

    def test_handovers_list_and_status_filter(self):
        self.post(self.rider, receiver='admin', amount='100')
        RiderCashHandover.objects.create(rider=self.rider, receiver='admin', amount=Decimal('50'),
                                         status='rejected', reject_reason='kam nikla')
        allh = self.get('rider_api_handovers').json()['handovers']
        self.assertEqual(len(allh), 2)
        rej = self.get('rider_api_handovers', status='rejected').json()['handovers']
        self.assertEqual([x['reject_reason'] for x in rej], ['kam nikla'])


class RegressionTests(RiderCashBase):
    def test_old_endpoints_unchanged(self):
        me = self.get('rider_api_me').json()
        self.assertTrue(me['ok'])
        for k in ('id', 'name', 'phone', 'vehicle', 'online', 'fee', 'today_deliveries',
                  'today_earned', 'cash_in_hand', 'due'):
            self.assertIn(k, me['rider'])
        orders = self.get('rider_api_orders').json()
        for k in ('ok', 'online', 'offers', 'mine', 'tracking', 'profile'):
            self.assertIn(k, orders)


# ================================================================
# PHASE 2: receiver (admin / vendor) confirm / reject
# Run:  python manage.py test app.tests_rider_cash
# ================================================================
from django.core.management import call_command  # noqa: E402

from app.customer import rider_cash_service as svc  # noqa: E402
from app.customer.views_rider_portal import rider_balances  # noqa: E402


class ReceiverBase(RiderCashBase):
    def setUp(self):
        super().setUp()
        self.vuser2 = User.objects.create_user('u_other', 'o@x.com', 'secret12')
        VendorProfile.objects.create(vendor=self.other_vendor, user=self.vuser2,
                                     business_name='Other Store', is_approved=True)

    def handover(self, receiver='admin', amount='1000', vendor=None, rider=None):
        return RiderCashHandover.objects.create(rider=rider or self.rider, receiver=receiver,
                                                vendor=vendor, amount=Decimal(amount))

    def cash(self, rider=None):
        return rider_balances(rider or self.rider)['cash_in_hand']


class AdminConfirmTests(ReceiverBase):
    def setUp(self):
        super().setUp()
        self.client.force_login(self.admin)

    def act(self, h, action, **extra):
        return self.client.post(reverse('rider_detail', args=[h.rider_id]),
                                dict(action=action, handover_id=h.pk, **extra))

    def test_confirm_creates_cash_in_and_reduces_cash(self):
        h = self.handover(amount='1500')
        self.assertEqual(self.cash(), Decimal('5500'))
        self.act(h, 'handover_confirm')
        h.refresh_from_db()
        self.assertEqual(h.status, 'confirmed')
        self.assertEqual(h.decided_by, self.admin)
        self.assertIsNotNone(h.settlement)
        self.assertEqual((h.settlement.kind, h.settlement.amount), ('cash_in', Decimal('1500.00')))
        self.assertEqual(self.cash(), Decimal('4000'))
        self.assertTrue(Notification.objects.filter(user=self.rider.user, title__contains='confirm').exists())

    def test_double_confirm_makes_one_settlement(self):
        h = self.handover(amount='1500')
        self.act(h, 'handover_confirm')
        self.act(h, 'handover_confirm')
        self.assertEqual(RiderSettlement.objects.filter(kind='cash_in').count(), 1)
        self.assertEqual(self.cash(), Decimal('4000'))

    def test_reject_needs_reason_and_keeps_cash(self):
        h = self.handover(amount='1500')
        self.act(h, 'handover_reject', reason='')
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')
        self.act(h, 'handover_reject', reason='Raqam kam thi')
        h.refresh_from_db()
        self.assertEqual((h.status, h.reject_reason), ('rejected', 'Raqam kam thi'))
        self.assertIsNone(h.settlement)
        self.assertEqual(RiderSettlement.objects.count(), 0)
        self.assertEqual(self.cash(), Decimal('5500'))
        self.assertTrue(Notification.objects.filter(user=self.rider.user, message__contains='Raqam kam thi').exists())

    def test_rejected_cannot_be_confirmed_later(self):
        h = self.handover()
        self.act(h, 'handover_reject', reason='ghalat')
        self.act(h, 'handover_confirm')
        h.refresh_from_db()
        self.assertEqual(h.status, 'rejected')
        self.assertEqual(RiderSettlement.objects.count(), 0)

    def test_admin_cannot_decide_vendor_handover(self):
        h = self.handover(receiver='vendor', vendor=self.vendor)
        self.act(h, 'handover_confirm')
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')

    def test_handover_of_other_rider_not_decided_via_wrong_page(self):
        h = self.handover(rider=self.rider)
        self.client.post(reverse('rider_detail', args=[self.rider2.pk]),
                         dict(action='handover_confirm', handover_id=h.pk))
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')

    def test_confirm_blocked_if_cash_already_deposited_manually(self):
        """Admin ne purana 'Cash jama' form pehle hi use kar liya: confirm raqam se zyada na ho."""
        h = self.handover(amount='3000')
        RiderSettlement.objects.create(rider=self.rider, kind='cash_in', amount=Decimal('4000'))
        self.act(h, 'handover_confirm')
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')
        self.assertEqual(RiderSettlement.objects.count(), 1)

    def test_old_manual_cash_in_form_still_works(self):
        self.client.post(reverse('rider_detail', args=[self.rider.pk]),
                         dict(action='cash_in', amount='500', note='haath se'))
        self.assertEqual(self.cash(), Decimal('5000'))

    def test_detail_page_lists_pending(self):
        self.handover(amount='1234')
        r = self.client.get(reverse('rider_detail', args=[self.rider.pk]))
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, 'Pending cash handovers')
        self.assertContains(r, '1234')

    def test_non_admin_cannot_use_rider_detail(self):
        h = self.handover()
        self.client.force_login(self.vuser)
        self.client.post(reverse('rider_detail', args=[self.rider.pk]),
                         dict(action='handover_confirm', handover_id=h.pk))
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')


class VendorConfirmTests(ReceiverBase):
    def act(self, h, action, **extra):
        return self.client.post(reverse('vendor_rider_cash_action', args=[h.pk, action]), extra)

    def test_page_shows_only_own_vendor_handovers(self):
        mine = self.handover(receiver='vendor', vendor=self.vendor, amount='777')
        self.handover(receiver='vendor', vendor=self.other_vendor, amount='888')
        self.handover(receiver='admin', amount='999')
        self.client.force_login(self.vuser)
        r = self.client.get(reverse('vendor_rider_cash'))
        self.assertEqual(r.status_code, 200)
        self.assertEqual([h.pk for h in r.context['pending']], [mine.pk])

    def test_vendor_confirm_updates_balance_and_notes_vendor(self):
        h = self.handover(receiver='vendor', vendor=self.vendor, amount='2000')
        self.client.force_login(self.vuser)
        self.act(h, 'confirm')
        h.refresh_from_db()
        self.assertEqual(h.status, 'confirmed')
        self.assertEqual(h.decided_by, self.vuser)
        self.assertIn('Ali Store', h.settlement.note)
        self.assertEqual(self.cash(), Decimal('3500'))

    def test_vendor_reject_keeps_cash_with_rider(self):
        h = self.handover(receiver='vendor', vendor=self.vendor, amount='2000')
        self.client.force_login(self.vuser)
        self.act(h, 'reject', reason='Cash nahi mila')
        h.refresh_from_db()
        self.assertEqual((h.status, h.reject_reason), ('rejected', 'Cash nahi mila'))
        self.assertEqual(self.cash(), Decimal('5500'))
        self.assertTrue(Notification.objects.filter(user=self.rider.user, message__contains='Cash nahi mila').exists())

    def test_other_vendor_cannot_decide(self):
        h = self.handover(receiver='vendor', vendor=self.vendor)
        self.client.force_login(self.vuser2)
        self.act(h, 'confirm')
        self.act(h, 'reject', reason='x')
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')
        self.assertEqual(RiderSettlement.objects.count(), 0)

    def test_vendor_cannot_decide_admin_handover(self):
        h = self.handover(receiver='admin')
        self.client.force_login(self.vuser)
        self.act(h, 'confirm')
        h.refresh_from_db()
        self.assertEqual(h.status, 'pending')

    def test_get_not_allowed_and_login_required(self):
        h = self.handover(receiver='vendor', vendor=self.vendor)
        self.assertEqual(self.client.get(reverse('vendor_rider_cash_action', args=[h.pk, 'confirm'])).status_code, 302)
        self.client.force_login(self.vuser)
        self.assertEqual(self.client.get(reverse('vendor_rider_cash_action', args=[h.pk, 'confirm'])).status_code, 405)

    def test_end_to_end_rider_api_to_vendor_confirm(self):
        r = self.post(self.rider, receiver='vendor', vendor_id=self.vendor.pk, amount='1000')
        self.assertEqual(r.status_code, 200, r.content)
        h = RiderCashHandover.objects.get()
        self.client.force_login(self.vuser)
        self.act(h, 'confirm')
        w = self.get('rider_api_wallet').json()
        self.assertEqual(w['cash_in_hand'], 4500.0)
        self.assertEqual(w['pending_handover'], 0.0)
        self.assertEqual(w['handovers'][0]['status'], 'confirmed')


class ServiceTests(ReceiverBase):
    def test_can_decide_rules(self):
        ha = self.handover(receiver='admin')
        hv = self.handover(receiver='vendor', vendor=self.vendor)
        self.assertTrue(svc.can_decide(ha, self.admin))
        self.assertFalse(svc.can_decide(ha, self.vuser, vendor=self.vendor))
        self.assertTrue(svc.can_decide(hv, self.vuser, vendor=self.vendor))
        self.assertFalse(svc.can_decide(hv, self.admin))

    def test_service_raises_for_missing_and_reused(self):
        with self.assertRaises(svc.HandoverError):
            svc.confirm_handover(99999, self.admin)
        h = self.handover()
        svc.confirm_handover(h.pk, self.admin)
        with self.assertRaises(svc.HandoverError):
            svc.confirm_handover(h.pk, self.admin)

    def test_two_partial_handovers_both_confirm(self):
        a, b = self.handover(amount='3000'), self.handover(amount='2500')
        svc.confirm_handover(a.pk, self.admin)
        svc.confirm_handover(b.pk, self.admin)
        self.assertEqual(self.cash(), Decimal('0'))

    def test_reminder_command_only_for_old_pending(self):
        from datetime import timedelta
        old = self.handover()
        RiderCashHandover.objects.filter(pk=old.pk).update(created_at=now() - timedelta(hours=30))
        self.handover(amount='10')
        call_command('remind_pending_handovers')
        self.assertEqual(Notification.objects.filter(user=self.admin, title__contains='confirm ka intezar').count(), 1)
        # auto-confirm nahi hota
        old.refresh_from_db()
        self.assertEqual(old.status, 'pending')
