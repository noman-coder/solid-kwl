"""
Phase C7 tests: api/customer/cart/ (get, count, add, update, remove, clear, ack, merge, preview).

Run:  python manage.py test app.tests_customer_cart -v 2

Cache locmem par override hai (Redis ki zaroorat nahi). Migration 0066 (CustomerCart) chahiye.
"""
from datetime import timedelta
from decimal import Decimal

from django.urls import reverse
from django.utils import timezone

from app.models import CustomerCart, Inventory, Product, ProductOffer, Warehouse
from app.tests_customer_home import HomeBase, make_store

D = Decimal
CART = 'customer_api_cart'
COUNT = 'customer_api_cart_count'
ADD = 'customer_api_cart_add'
UPDATE = 'customer_api_cart_update'
REMOVE = 'customer_api_cart_remove'
CLEAR = 'customer_api_cart_clear'
ACK = 'customer_api_cart_ack'
MERGE = 'customer_api_cart_merge'
PREVIEW = 'customer_api_cart_preview'


class CartBase(HomeBase):
    def setUp(self):
        super().setUp()
        self.ta = self.token('03001111111')
        self.tb = self.token('03002222222')

    def item(self, vp, name, price='100', stock=10, **kw):
        p = Product.objects.create(name=name, vendor=vp.vendor, price=D(price), is_active=True,
                                   approval_status='approved', **kw)
        if stock is not None:
            Inventory.objects.create(product=p, warehouse=Warehouse.objects.get_or_create(name='Main')[0], stock=stock)
        return p

    def add(self, pid, qty=1, token=None, **extra):
        return self.post(ADD, dict({'product_id': pid, 'quantity': qty}, **extra), token or self.ta)

    def cart(self, token=None):
        return self.get(CART, token=token or self.ta).json()['cart']


class CartAuthTests(CartBase):
    def test_login_required(self):
        for name in (CART, COUNT):
            self.assertEqual(self.get(name).status_code, 401)
        for name in (ADD, UPDATE, REMOVE, CLEAR, ACK, MERGE):
            self.assertEqual(self.post(name, {}).status_code, 401)

    def test_empty_cart_shape(self):
        r = self.get(CART, token=self.ta)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r['Cache-Control'], 'no-store')
        c = r.json()['cart']
        for key in ('items', 'count', 'lines', 'subtotal', 'delivery_fee', 'total', 'store', 'min_order', 'min_ok',
                    'short_by', 'free_delivery', 'can_checkout', 'checkout_message', 'notices', 'currency',
                    'price_changed', 'has_issues'):
            self.assertIn(key, c)
        self.assertEqual(c['items'], [])
        self.assertEqual(c['total'], 0)
        self.assertFalse(c['can_checkout'])

    def test_get_wrong_method(self):
        self.assertEqual(self.client.post(reverse(CART), '{}', content_type='application/json',
                                          HTTP_AUTHORIZATION=f'Bearer {self.ta}').status_code, 405)


class CartAddTests(CartBase):
    def test_add_and_totals_match_web_rule(self):
        vp, _ = make_store('Shop', fee=D('50'))
        p = self.item(vp, 'Cola', price='100', stock=10)
        r = self.add(p.pk, 2)
        self.assertEqual(r.status_code, 200)
        c = r.json()['cart']
        self.assertEqual(c['count'], 2)
        self.assertEqual(c['subtotal'], 200.0)
        self.assertEqual(c['delivery_fee'], 50.0)
        self.assertEqual(c['total'], 250.0)
        self.assertEqual(c['store']['id'], vp.pk)
        line = c['items'][0]
        self.assertEqual((line['product_id'], line['quantity'], line['line_total']), (p.pk, 2, 200.0))
        self.assertTrue(c['can_checkout'])
        # GET wahi dikhaye
        self.assertEqual(self.cart()['total'], 250.0)

    def test_add_same_product_twice_sums(self):
        vp, _ = make_store('Shop')
        p = self.item(vp, 'Cola', stock=10)
        self.add(p.pk, 2)
        self.assertEqual(self.add(p.pk, 3).json()['cart']['count'], 5)
        self.assertEqual(CustomerCart.objects.filter(customer=self.a).count(), 1)

    def test_cannot_exceed_stock(self):
        vp, _ = make_store('Shop')
        p = self.item(vp, 'Cola', stock=3)
        r = self.add(p.pk, 4)
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'stock')
        self.assertEqual(r.json()['max_qty'], 3)
        self.assertEqual(self.cart()['count'], 0)
        self.add(p.pk, 2)
        r = self.add(p.pk, 2)                       # 2 + 2 > 3
        self.assertEqual(r.status_code, 409)
        self.assertEqual(self.cart()['count'], 2)

    def test_out_of_stock_cannot_be_added(self):
        vp, _ = make_store('Shop')
        p = self.item(vp, 'Gone', stock=0)
        r = self.add(p.pk)
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'out_of_stock')
        no_inventory = self.item(vp, 'NoInv', stock=None)
        self.assertEqual(self.add(no_inventory.pk).status_code, 409)

    def test_inactive_or_rejected_product_never_added(self):
        vp, _ = make_store('Shop')
        off = self.item(vp, 'Off')
        Product.objects.filter(pk=off.pk).update(is_active=False)
        pend = self.item(vp, 'Pending')
        Product.objects.filter(pk=pend.pk).update(approval_status='pending')
        rej = self.item(vp, 'Rejected')
        Product.objects.filter(pk=rej.pk).update(approval_status='rejected')
        for p in (off, pend, rej):
            r = self.add(p.pk)
            self.assertEqual(r.status_code, 404)
            self.assertEqual(r.json()['code'], 'not_found')
        self.assertEqual(self.add(999999).status_code, 404)

    def test_unapproved_store_product_not_added(self):
        vp, _ = make_store('Hidden', approved=False)
        p = self.item(vp, 'X')
        self.assertEqual(self.add(p.pk).status_code, 404)

    def test_closed_store_blocked(self):
        vp, _ = make_store('Closed Shop', status='closed')
        p = self.item(vp, 'X')
        r = self.add(p.pk)
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'store_closed')
        self.assertIn('band', r.json()['error'])

    def test_bad_inputs(self):
        vp, _ = make_store('Shop')
        p = self.item(vp, 'Cola')
        for body in ({}, {'product_id': 'abc'}, {'product_id': -1}, {'product_id': p.pk, 'quantity': 0},
                     {'product_id': p.pk, 'quantity': -2}, {'product_id': p.pk, 'quantity': 1001},
                     {'product_id': p.pk, 'quantity': 'many'}, {'product_id': p.pk, 'quantity': 1.5},
                     {'product_id': True}):
            r = self.post(ADD, body, self.ta)
            self.assertEqual(r.status_code, 400, body)
            self.assertFalse(r.json()['ok'])
        self.assertEqual(self.cart()['count'], 0)

    def test_area_not_served_blocked(self):
        vp, _ = make_store('Local', city='Lahore', areas='Gulberg')
        p = self.item(vp, 'X')
        r = self.add(p.pk, area='Karachi')
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'not_served')
        self.assertEqual(self.add(p.pk, area='Lahore').status_code, 200)

    def test_one_store_at_a_time_and_replace(self):
        a, _ = make_store('Store A')
        b, _ = make_store('Store B')
        pa = self.item(a, 'A1')
        pb = self.item(b, 'B1')
        self.add(pa.pk, 2)
        r = self.add(pb.pk)
        self.assertEqual(r.status_code, 409)
        j = r.json()
        self.assertEqual(j['code'], 'cart_conflict')
        self.assertEqual((j['current_store'], j['new_store']), ('Store A', 'Store B'))
        self.assertEqual(self.cart()['items'][0]['product_id'], pa.pk)       # purana cart waisa hi
        r = self.add(pb.pk, 1, replace_cart=True)
        self.assertEqual(r.status_code, 200)
        c = r.json()['cart']
        self.assertEqual([i['product_id'] for i in c['items']], [pb.pk])
        self.assertEqual(c['store']['name'], 'Store B')

    def test_offer_price_used(self):
        vp, _ = make_store('Shop')
        p = self.item(vp, 'Cola', price='100')
        now = timezone.now()
        ProductOffer.objects.create(product=p, profile=vp, discount_percent=D('20'),
                                    starts_at=now - timedelta(hours=1), ends_at=now + timedelta(hours=5))
        line = self.add(p.pk, 2).json()['cart']['items'][0]
        self.assertEqual(line['price'], 80.0)
        self.assertEqual(line['line_total'], 160.0)

    def test_concurrent_style_adds_do_not_lose_items(self):
        vp, _ = make_store('Shop')
        p1, p2 = self.item(vp, 'P1'), self.item(vp, 'P2')
        self.add(p1.pk)
        self.add(p2.pk)
        self.assertEqual(sorted(i['product_id'] for i in self.cart()['items']), sorted([p1.pk, p2.pk]))


class CartUpdateTests(CartBase):
    def setUp(self):
        super().setUp()
        self.vp, _ = make_store('Shop', fee=D('50'))
        self.p = self.item(self.vp, 'Cola', price='100', stock=5)

    def test_update_qty(self):
        self.add(self.p.pk, 1)
        r = self.post(UPDATE, {'product_id': self.p.pk, 'quantity': 4}, self.ta)
        self.assertEqual(r.status_code, 200)
        c = r.json()['cart']
        self.assertEqual((c['count'], c['subtotal'], c['total']), (4, 400.0, 450.0))

    def test_update_over_stock_rejected(self):
        self.add(self.p.pk, 2)
        r = self.post(UPDATE, {'product_id': self.p.pk, 'quantity': 6}, self.ta)
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'stock')
        self.assertEqual(self.cart()['count'], 2)

    def test_update_zero_removes(self):
        self.add(self.p.pk, 2)
        c = self.post(UPDATE, {'product_id': self.p.pk, 'quantity': 0}, self.ta).json()['cart']
        self.assertEqual(c['items'], [])

    def test_update_not_in_cart_404(self):
        r = self.post(UPDATE, {'product_id': self.p.pk, 'quantity': 2}, self.ta)
        self.assertEqual(r.status_code, 404)
        self.assertEqual(r.json()['code'], 'not_in_cart')

    def test_update_bad_qty(self):
        self.add(self.p.pk, 2)
        for q in (-1, 1001, 'x', None):
            self.assertEqual(self.post(UPDATE, {'product_id': self.p.pk, 'quantity': q}, self.ta).status_code, 400)

    def test_can_reduce_even_if_stock_dropped(self):
        self.add(self.p.pk, 5)
        Inventory.objects.filter(product=self.p).update(stock=2)
        self.assertTrue(self.cart()['has_issues'])                           # 5 > 2: warning
        c = self.post(UPDATE, {'product_id': self.p.pk, 'quantity': 3}, self.ta).json()['cart']
        self.assertEqual(c['count'], 3)                                       # kam karna chalta hai
        c = self.post(UPDATE, {'product_id': self.p.pk, 'quantity': 2}, self.ta).json()['cart']
        self.assertFalse(c['has_issues'])

    def test_remove_and_clear(self):
        p2 = self.item(self.vp, 'Chips', price='30', stock=9)
        self.add(self.p.pk, 1)
        self.add(p2.pk, 2)
        c = self.post(REMOVE, {'product_id': self.p.pk}, self.ta).json()['cart']
        self.assertEqual([i['product_id'] for i in c['items']], [p2.pk])
        # dobara remove par bhi theek (double tap)
        self.assertEqual(self.post(REMOVE, {'product_id': self.p.pk}, self.ta).status_code, 200)
        c = self.post(CLEAR, {}, self.ta).json()['cart']
        self.assertEqual((c['items'], c['total']), ([], 0))

    def test_count_endpoint(self):
        self.add(self.p.pk, 3)
        j = self.get(COUNT, token=self.ta).json()
        self.assertEqual((j['count'], j['lines']), (3, 1))


class CartOwnershipTests(CartBase):
    def test_carts_are_separate(self):
        vp, _ = make_store('Shop')
        p = self.item(vp, 'Cola')
        self.add(p.pk, 2, token=self.ta)
        self.assertEqual(self.cart(self.tb)['items'], [])
        self.assertEqual(self.get(COUNT, token=self.tb).json()['count'], 0)
        # B ka remove / clear A ka cart nahi chhedta
        self.post(REMOVE, {'product_id': p.pk}, self.tb)
        self.post(CLEAR, {}, self.tb)
        self.assertEqual(self.cart(self.ta)['count'], 2)
        self.assertEqual(self.post(UPDATE, {'product_id': p.pk, 'quantity': 3}, self.tb).status_code, 404)


class CartPriceAndIssueTests(CartBase):
    def setUp(self):
        super().setUp()
        self.vp, _ = make_store('Shop', fee=D('50'))

    def test_price_change_flagged_then_acked(self):
        p = self.item(self.vp, 'Cola', price='100')
        self.add(p.pk, 2)
        Product.objects.filter(pk=p.pk).update(price=D('120'))
        c = self.cart()
        line = c['items'][0]
        self.assertTrue(c['price_changed'])
        self.assertTrue(line['price_changed'])
        self.assertEqual((line['price'], line['price_was']), (120.0, 100.0))
        self.assertEqual(c['subtotal'], 240.0)                                # total naye dam par
        self.assertTrue(any('qeemat' in n for n in c['notices']))
        self.assertTrue(self.cart()['price_changed'])                         # ack tak alert bana rahe
        c = self.post(ACK, {}, self.ta).json()['cart']
        self.assertFalse(c['price_changed'])
        self.assertIsNone(c['items'][0]['price_was'])

    def test_price_change_cleared_on_qty_update(self):
        p = self.item(self.vp, 'Cola', price='100')
        self.add(p.pk, 2)
        Product.objects.filter(pk=p.pk).update(price=D('90'))
        self.assertTrue(self.cart()['price_changed'])
        c = self.post(UPDATE, {'product_id': p.pk, 'quantity': 3}, self.ta).json()['cart']
        self.assertFalse(c['price_changed'])
        self.assertEqual(c['subtotal'], 270.0)

    def test_product_gone_shows_issue_and_not_counted(self):
        p1 = self.item(self.vp, 'Keep', price='100')
        p2 = self.item(self.vp, 'Gone', price='100')
        self.add(p1.pk, 1)
        self.add(p2.pk, 1)
        Product.objects.filter(pk=p2.pk).update(is_active=False)
        c = self.cart()
        gone = [i for i in c['items'] if i['product_id'] == p2.pk][0]
        self.assertEqual(gone['issue'], 'unavailable')
        self.assertEqual(c['subtotal'], 100.0)
        self.assertTrue(c['has_issues'])
        self.assertFalse(c['can_checkout'])
        c = self.post(REMOVE, {'product_id': p2.pk}, self.ta).json()['cart']
        self.assertTrue(c['can_checkout'])

    def test_out_of_stock_and_store_closed_issue(self):
        p = self.item(self.vp, 'Cola', stock=5)
        self.add(p.pk, 2)
        Inventory.objects.filter(product=p).update(stock=0)
        line = self.cart()['items'][0]
        self.assertEqual(line['issue'], 'out_of_stock')
        Inventory.objects.filter(product=p).update(stock=5)
        self.vp.store_status = 'closed'
        self.vp.save()
        c = self.cart()
        self.assertEqual(c['items'][0]['issue'], 'store_closed')
        self.assertFalse(c['can_checkout'])
        self.assertIn('band', c['checkout_message'])

    def test_min_order_warning(self):
        self.vp.min_order_amount = D('500')
        self.vp.save()
        p = self.item(self.vp, 'Cola', price='100')
        c = self.add(p.pk, 2).json()['cart']
        self.assertFalse(c['min_ok'])
        self.assertEqual((c['min_order'], c['short_by']), (500.0, 300.0))
        self.assertFalse(c['can_checkout'])
        self.assertIn('minimum', c['checkout_message'].lower())
        c = self.post(UPDATE, {'product_id': p.pk, 'quantity': 5}, self.ta).json()['cart']
        self.assertTrue(c['min_ok'])
        self.assertTrue(c['can_checkout'])

    def test_free_delivery_fee_zero_flag(self):
        vp, _ = make_store('Free Shop', fee=D('0'))
        p = self.item(vp, 'X')
        c = self.add(p.pk).json()['cart']
        self.assertTrue(c['delivery_is_free'])
        self.assertEqual(c['total'], c['subtotal'])


class CartMergeTests(CartBase):
    def setUp(self):
        super().setUp()
        self.vp, _ = make_store('Shop A')
        self.p1 = self.item(self.vp, 'P1', stock=10)
        self.p2 = self.item(self.vp, 'P2', stock=10)

    def merge(self, items, token=None):
        return self.post(MERGE, {'items': items}, token or self.ta)

    def test_merge_into_empty_server_cart(self):
        r = self.merge([{'product_id': self.p1.pk, 'quantity': 2}, {'product_id': self.p2.pk, 'quantity': 1}])
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertEqual(j['merged'], 2)
        self.assertEqual(j['skipped'], [])
        self.assertEqual(j['cart']['count'], 3)
        self.assertEqual(self.cart()['count'], 3)

    def test_merge_twice_does_not_double(self):
        items = [{'product_id': self.p1.pk, 'quantity': 2}]
        self.merge(items)
        self.assertEqual(self.merge(items).json()['cart']['count'], 2)

    def test_merge_keeps_bigger_quantity_and_caps_stock(self):
        self.add(self.p1.pk, 3)
        c = self.merge([{'product_id': self.p1.pk, 'quantity': 2}]).json()['cart']
        self.assertEqual(c['count'], 3)
        c = self.merge([{'product_id': self.p1.pk, 'quantity': 50}]).json()['cart']
        self.assertEqual(c['count'], 10)                                     # stock tak

    def test_merge_other_store_skipped(self):
        b, _ = make_store('Shop B')
        pb = self.item(b, 'B1')
        self.add(self.p1.pk, 1)
        j = self.merge([{'product_id': pb.pk, 'quantity': 1}, {'product_id': self.p2.pk, 'quantity': 1}]).json()
        self.assertEqual(j['merged'], 1)
        self.assertEqual([s['reason'] for s in j['skipped']], ['other_store'])
        self.assertEqual(sorted(i['product_id'] for i in j['cart']['items']), sorted([self.p1.pk, self.p2.pk]))

    def test_merge_skips_gone_and_out_of_stock(self):
        gone = self.item(self.vp, 'Gone')
        Product.objects.filter(pk=gone.pk).update(is_active=False)
        none_left = self.item(self.vp, 'None', stock=0)
        j = self.merge([{'product_id': gone.pk, 'quantity': 1}, {'product_id': none_left.pk, 'quantity': 1},
                        {'product_id': self.p1.pk, 'quantity': 1}]).json()
        self.assertEqual(j['merged'], 1)
        self.assertEqual(sorted(s['reason'] for s in j['skipped']), ['out_of_stock', 'unavailable'])

    def test_merge_bad_body(self):
        self.assertEqual(self.post(MERGE, {'items': 'x'}, self.ta).status_code, 400)
        self.assertEqual(self.post(MERGE, {}, self.ta).status_code, 400)
        self.assertEqual(self.merge([{'product_id': 'a', 'quantity': 1}, 5, {'product_id': self.p1.pk}]).status_code, 200)

    def test_merge_empty_list_ok(self):
        j = self.merge([]).json()
        self.assertEqual((j['merged'], j['cart']['count']), (0, 0))


class CartPreviewTests(CartBase):
    def test_guest_preview_matches_logged_in_total(self):
        vp, _ = make_store('Shop', fee=D('50'))
        p = self.item(vp, 'Cola', price='100')
        body = {'items': [{'product_id': p.pk, 'quantity': 3}]}
        guest = self.post(PREVIEW, body)
        self.assertEqual(guest.status_code, 200)
        g = guest.json()['cart']
        self.assertEqual((g['subtotal'], g['delivery_fee'], g['total']), (300.0, 50.0, 350.0))
        self.assertTrue(g['can_checkout'])
        self.assertEqual(CustomerCart.objects.count(), 0)                    # kuch save nahi
        self.add(p.pk, 3)
        self.assertEqual(self.cart()['total'], g['total'])

    def test_preview_flags_stock_and_gone(self):
        vp, _ = make_store('Shop')
        p = self.item(vp, 'Cola', stock=2)
        c = self.post(PREVIEW, {'items': [{'product_id': p.pk, 'quantity': 5},
                                          {'product_id': 424242, 'quantity': 1}]}).json()['cart']
        issues = sorted(i['issue'] for i in c['items'])
        self.assertEqual(issues, ['low_stock', 'unavailable'])
        self.assertFalse(c['can_checkout'])

    def test_preview_bad_token_401_and_bad_body(self):
        self.assertEqual(self.post(PREVIEW, {'items': []}, token='garbage').status_code, 401)
        self.assertEqual(self.post(PREVIEW, {'items': 'x'}).status_code, 400)
        c = self.post(PREVIEW, {'items': []}).json()['cart']
        self.assertEqual(c['items'], [])
