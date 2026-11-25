"""
Phase V10 tests: stock list (kam / khatam), stock adjust (add / minus, bulk, history), threshold,
negative stock, ownership, retry (request_key), low-stock push + roz ka summary.

Run:  python manage.py test app.tests_vendor_stock
Asli FCM ko koi call nahi jati (push_async mock hota hai).
"""
import json
from decimal import Decimal
from io import StringIO

from django.core.management import call_command
from django.urls import reverse

from app import vendor_push
from app.models import Inventory, Product, StockBatch, VendorPushToken, VendorStockLog
from app.tests_vendor_push import TOK1, VendorPushBase
from app.tests_vendor_api import PHONE_A, make_vendor


class StockBase(VendorPushBase):
    def mk(self, profile, name, stock=20, status='approved', threshold=10.0, price='100', reserved=0, barcode=''):
        p = Product(name=name, vendor=profile.vendor, original_price=Decimal(price), price=Decimal(price),
                    approval_status=status, is_active=True, low_stock_threshold=threshold, barcode=barcode or None)
        p._image_processed = True
        p.save()
        inv, _ = Inventory.objects.get_or_create(product=p, warehouse=self.wh)
        if stock or reserved:
            Inventory.objects.filter(pk=inv.pk).update(stock=stock, reserved_stock=reserved)
            if stock:
                StockBatch(product=p, qty=stock, remaining_qty=stock, price=Decimal('90'),
                           selling_price=Decimal(price), warehouse=self.wh).save()
        return p

    def stock_of(self, p):
        return Inventory.objects.get(product=p, warehouse=self.wh).stock

    def batches_left(self, p):
        return sum(b.remaining_qty for b in StockBatch.objects.filter(product=p))

    def get(self, name, profile=None, **params):
        return self.client.get(reverse(name), params, **self.bearer(profile or self.a))

    def adjust(self, body, profile=None):
        return self.post_json('vendor_api_stock_adjust', body, profile or self.a)


class StockListTests(StockBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_stock')).status_code, 401)

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.get('vendor_api_stock', c).status_code, 403)

    def test_default_shows_low_and_out_only_lowest_first(self):
        ok = self.mk(self.a, 'Theek', stock=50)
        low = self.mk(self.a, 'Kam', stock=4)
        out = self.mk(self.a, 'Khatam', stock=0)
        d = self.get('vendor_api_stock').json()
        self.assertTrue(d['ok'])
        self.assertEqual([p['id'] for p in d['products']], [out.pk, low.pk])
        self.assertEqual(d['summary']['low'], 1)
        self.assertEqual(d['summary']['out'], 1)
        self.assertEqual(d['summary']['ok'], 1)
        self.assertIn('damaged', [r['code'] for r in d['reasons']['minus']])
        self.assertNotIn(ok.pk, [p['id'] for p in d['products']])

    def test_filters_and_all(self):
        self.mk(self.a, 'Theek', stock=50)
        low = self.mk(self.a, 'Kam', stock=4)
        out = self.mk(self.a, 'Khatam', stock=0)
        self.assertEqual([p['id'] for p in self.get('vendor_api_stock', filter='low').json()['products']], [low.pk])
        self.assertEqual([p['id'] for p in self.get('vendor_api_stock', filter='out').json()['products']], [out.pk])
        self.assertEqual(len(self.get('vendor_api_stock', filter='all').json()['products']), 3)
        self.assertEqual(self.get('vendor_api_stock', filter='bakwas').json()['filter'], 'need')

    def test_only_own_and_only_approved(self):
        self.mk(self.b, 'Doosre ka', stock=1)
        self.mk(self.a, 'Pending', stock=1, status='pending')
        mine = self.mk(self.a, 'Mera', stock=1)
        d = self.get('vendor_api_stock', filter='all').json()
        self.assertEqual([p['id'] for p in d['products']], [mine.pk])

    def test_search_by_name_and_barcode(self):
        a = self.mk(self.a, 'Chawal', stock=1, barcode='8964000111')
        self.mk(self.a, 'Daal', stock=1)
        self.assertEqual([p['id'] for p in self.get('vendor_api_stock', q='chaw').json()['products']], [a.pk])
        self.assertEqual([p['id'] for p in self.get('vendor_api_stock', q='8964000111').json()['products']], [a.pk])

    def test_reserved_and_available_shown(self):
        self.mk(self.a, 'Aam', stock=8, reserved=3)
        p = self.get('vendor_api_stock').json()['products'][0]
        self.assertEqual(p['reserved'], 3)
        self.assertEqual(p['available'], 5)


class AdjustTests(StockBase):
    def test_add_increases_stock_batch_and_history(self):
        p = self.mk(self.a, 'Aata', stock=2)
        r = self.adjust({'id': p.pk, 'mode': 'add', 'qty': 30, 'reason': 'purchase'})
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['ok'])
        self.assertEqual(self.stock_of(p), 32)
        self.assertEqual(self.batches_left(p), 32)
        log = VendorStockLog.objects.get()
        self.assertEqual((log.kind, log.qty, log.before, log.after, log.reason, log.source),
                         ('add', 30, 2, 32, 'purchase', 'app'))
        self.assertEqual(log.profile, self.a)
        row = r.json()['results'][0]
        self.assertEqual((row['status'], row['before'], row['after']), ('ok', 2, 32))
        self.assertEqual(row['product']['stock'], 32)
        self.assertEqual(row['product']['stock_state'], 'ok')

    def test_minus_decreases_stock_fifo_and_history(self):
        p = self.mk(self.a, 'Cheeni', stock=10)
        StockBatch(product=p, qty=5, remaining_qty=5, price=Decimal('95'), selling_price=Decimal('100'),
                   warehouse=self.wh).save()
        Inventory.objects.filter(product=p, warehouse=self.wh).update(stock=15)
        r = self.adjust({'id': p.pk, 'mode': 'minus', 'qty': 12, 'reason': 'damaged', 'note': 'Barish mein bheeg gaya'})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.stock_of(p), 3)
        first, second = list(StockBatch.objects.filter(product=p).order_by('id'))
        self.assertEqual((first.remaining_qty, second.remaining_qty), (0, 3))     # purana batch pehle
        log = VendorStockLog.objects.get()
        self.assertEqual((log.kind, log.before, log.after, log.reason), ('minus', 15, 3, 'damaged'))
        self.assertEqual(log.note, 'Barish mein bheeg gaya')

    def test_minus_more_than_stock_rejected_no_change(self):
        p = self.mk(self.a, 'Namak', stock=5)
        r = self.adjust({'id': p.pk, 'mode': 'minus', 'qty': 6, 'reason': 'lost'})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['results'][0]['code'], 'too_much')
        self.assertEqual(self.stock_of(p), 5)
        self.assertEqual(self.batches_left(p), 5)
        self.assertEqual(VendorStockLog.objects.count(), 0)

    def test_minus_exact_stock_to_zero_ok_never_negative(self):
        p = self.mk(self.a, 'Chai', stock=5)
        self.assertEqual(self.adjust({'id': p.pk, 'mode': 'minus', 'qty': 5, 'reason': 'expired'}).status_code, 200)
        self.assertEqual(self.stock_of(p), 0)
        r = self.adjust({'id': p.pk, 'mode': 'minus', 'qty': 1, 'reason': 'expired'})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['results'][0]['code'], 'no_stock')
        self.assertEqual(self.stock_of(p), 0)

    def test_reserved_stock_cannot_be_removed(self):
        p = self.mk(self.a, 'Doodh', stock=10, reserved=4)
        r = self.adjust({'id': p.pk, 'mode': 'minus', 'qty': 7, 'reason': 'lost'})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(self.stock_of(p), 10)
        self.assertEqual(self.adjust({'id': p.pk, 'mode': 'minus', 'qty': 6, 'reason': 'lost'}).status_code, 200)
        self.assertEqual(self.stock_of(p), 4)

    def test_bad_input(self):
        p = self.mk(self.a, 'Ghee', stock=5)
        for qty in (0, -3, 'abc', '', None, 2_000_000, 'nan', 'inf', True):
            r = self.adjust({'id': p.pk, 'mode': 'add', 'qty': qty})
            self.assertEqual(r.status_code, 400, qty)
        self.assertEqual(self.adjust({'id': p.pk, 'mode': 'badal', 'qty': 1}).status_code, 400)
        self.assertEqual(self.adjust({'items': []}).status_code, 400)
        self.assertEqual(self.adjust({}).status_code, 400)
        self.assertEqual(self.stock_of(p), 5)
        self.assertEqual(VendorStockLog.objects.count(), 0)

    def test_unknown_reason_becomes_other_and_note_trimmed(self):
        p = self.mk(self.a, 'Lassi', stock=5)
        self.adjust({'id': p.pk, 'mode': 'add', 'qty': 1, 'reason': 'jadu', 'note': 'x' * 500})
        log = VendorStockLog.objects.get()
        self.assertEqual(log.reason, 'other')
        self.assertEqual(len(log.note), 200)

    def test_other_vendors_product_untouched(self):
        mine = self.mk(self.a, 'Mera', stock=5)
        theirs = self.mk(self.b, 'Unka', stock=5)
        r = self.adjust({'items': [{'id': theirs.pk, 'mode': 'add', 'qty': 10},
                                   {'id': mine.pk, 'mode': 'add', 'qty': 1}]})
        self.assertEqual(r.status_code, 200)
        res = {x['id']: x for x in r.json()['results']}
        self.assertEqual(res[theirs.pk]['status'], 'error')
        self.assertEqual(res[theirs.pk]['code'], 'not_found')
        self.assertNotIn('product', res[theirs.pk])
        self.assertEqual(self.stock_of(theirs), 5)
        self.assertEqual(self.stock_of(mine), 6)

    def test_only_approved_products(self):
        p = self.mk(self.a, 'Naya', stock=0, status='pending')
        r = self.adjust({'id': p.pk, 'mode': 'add', 'qty': 5})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['results'][0]['code'], 'not_approved')

    def test_bulk_partial_success(self):
        a = self.mk(self.a, 'A', stock=5)
        b = self.mk(self.a, 'B', stock=2)
        r = self.adjust({'items': [{'id': a.pk, 'mode': 'add', 'qty': 5},
                                   {'id': b.pk, 'mode': 'minus', 'qty': 9}]})
        self.assertEqual(r.status_code, 200)          # ek lag gaya: ok
        d = r.json()
        self.assertEqual(d['changed'], 1)
        self.assertIn('mein masla', d['message'])
        self.assertEqual(self.stock_of(a), 10)
        self.assertEqual(self.stock_of(b), 2)

    def test_too_many_items(self):
        items = [{'id': i, 'mode': 'add', 'qty': 1} for i in range(1, 52)]
        self.assertEqual(self.adjust({'items': items}).status_code, 400)

    def test_request_key_retry_applies_once(self):
        p = self.mk(self.a, 'Retry', stock=5)
        body = {'id': p.pk, 'mode': 'add', 'qty': 10, 'request_key': 'key-12345678'}
        self.assertEqual(self.adjust(body).status_code, 200)
        r = self.adjust(body)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['results'][0]['status'], 'same')
        self.assertEqual(self.stock_of(p), 15)
        self.assertEqual(VendorStockLog.objects.count(), 1)

    def test_get_not_allowed(self):
        self.assertEqual(self.get('vendor_api_stock_adjust').status_code, 405)

    def test_unapproved_vendor_cannot_adjust(self):
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.adjust({'id': 1, 'mode': 'add', 'qty': 1}, c).status_code, 403)

    def test_adjust_updates_summary(self):
        p = self.mk(self.a, 'Kam', stock=3)
        self.assertEqual(self.get('vendor_api_stock').json()['summary']['low'], 1)
        d = self.adjust({'id': p.pk, 'mode': 'add', 'qty': 50, 'reason': 'purchase'}).json()
        self.assertEqual(d['summary']['low'], 0)
        self.assertEqual(d['summary']['ok'], 1)


class ThresholdTests(StockBase):
    def test_set_threshold(self):
        p = self.mk(self.a, 'Aam', stock=20, threshold=10)
        r = self.post_json('vendor_api_stock_threshold', {'id': p.pk, 'threshold': 25}, self.a)
        self.assertEqual(r.status_code, 200)
        p.refresh_from_db()
        self.assertEqual(p.low_stock_threshold, 25)
        self.assertEqual(r.json()['product']['stock_state'], 'low')       # 20 <= 25

    def test_validation(self):
        p = self.mk(self.a, 'Aam', stock=20)
        for bad in (0, -1, 'abc', None, 2_000_000, 'nan'):
            r = self.post_json('vendor_api_stock_threshold', {'id': p.pk, 'threshold': bad}, self.a)
            self.assertEqual(r.status_code, 400, bad)
        p.refresh_from_db()
        self.assertEqual(p.low_stock_threshold, 10)

    def test_other_vendor_404(self):
        p = self.mk(self.b, 'Unka', stock=20)
        r = self.post_json('vendor_api_stock_threshold', {'id': p.pk, 'threshold': 5}, self.a)
        self.assertEqual(r.status_code, 404)
        p.refresh_from_db()
        self.assertEqual(p.low_stock_threshold, 10)


class HistoryTests(StockBase):
    def test_history_own_only_newest_first_with_filter(self):
        p = self.mk(self.a, 'Aata', stock=5)
        q = self.mk(self.a, 'Daal', stock=5)
        theirs = self.mk(self.b, 'Unka', stock=5)
        self.adjust({'id': p.pk, 'mode': 'add', 'qty': 1, 'reason': 'purchase'})
        self.adjust({'id': q.pk, 'mode': 'minus', 'qty': 2, 'reason': 'damaged'})
        self.adjust({'id': theirs.pk, 'mode': 'add', 'qty': 9}, self.b)
        d = self.get('vendor_api_stock_history').json()
        self.assertEqual([x['product'] for x in d['logs']], ['Daal', 'Aata'])
        self.assertEqual(d['logs'][0]['reason_label'], 'Kharab / toota')
        one = self.get('vendor_api_stock_history', product=p.pk).json()
        self.assertEqual([x['product'] for x in one['logs']], ['Aata'])
        other = self.get('vendor_api_stock_history', product=theirs.pk).json()      # doosre ka: khali, leak nahi
        self.assertEqual(other['logs'], [])
        self.assertEqual(self.get('vendor_api_stock_history', product='x').status_code, 400)

    def test_quick_update_stock_add_is_logged(self):
        p = self.mk(self.a, 'Chawal', stock=5)
        r = self.post_json('vendor_api_products_quick_update', {'items': [{'id': p.pk, 'price': 100, 'add': 7}]}, self.a)
        self.assertEqual(r.status_code, 200)
        log = VendorStockLog.objects.get()
        self.assertEqual((log.kind, log.qty, log.before, log.after, log.source), ('add', 7, 5, 12, 'quick_update'))

    def test_quick_update_price_only_not_logged(self):
        p = self.mk(self.a, 'Chawal', stock=5)
        self.post_json('vendor_api_products_quick_update', {'items': [{'id': p.pk, 'price': 120}]}, self.a)
        self.assertEqual(VendorStockLog.objects.count(), 0)


class StockPushTests(StockBase):
    def setUp(self):
        super().setUp()
        VendorPushToken.objects.create(profile=self.a, token=TOK1)

    def test_adjust_below_threshold_pushes_once(self):
        p = self.mk(self.a, 'Biryani', stock=50)
        with self.captureOnCommitCallbacks(execute=True):
            self.adjust({'id': p.pk, 'mode': 'minus', 'qty': 45, 'reason': 'damaged'})
        self.assertEqual(self.push.call_count, 1)
        self.assertEqual(self.sent()[3]['data']['type'], 'low_stock')
        with self.captureOnCommitCallbacks(execute=True):
            self.adjust({'id': p.pk, 'mode': 'minus', 'qty': 1, 'reason': 'damaged'})
        self.assertEqual(self.push.call_count, 1)                 # bar bar nahi

    def test_summary_push_once_a_day(self):
        self.mk(self.a, 'Kam', stock=3)
        self.mk(self.a, 'Khatam', stock=0)
        self.mk(self.a, 'Theek', stock=99)
        out = StringIO()
        call_command('vendor_stock_summary', stdout=out)
        self.assertEqual(self.push.call_count, 1)
        tokens, title, body, kw = self.sent()
        self.assertEqual(tokens, [TOK1])
        self.assertIn('1 khatam', body)
        self.assertIn('1 kam', body)
        self.assertEqual(kw['data']['type'], 'stock_summary')
        call_command('vendor_stock_summary', stdout=out)           # dobara chalayein: spam nahi
        self.assertEqual(self.push.call_count, 1)

    def test_summary_nothing_to_report_sends_nothing(self):
        self.mk(self.a, 'Theek', stock=99)
        call_command('vendor_stock_summary', stdout=StringIO())
        self.assertEqual(self.push.call_count, 0)

    def test_summary_dry_run_sends_nothing(self):
        self.mk(self.a, 'Kam', stock=3)
        out = StringIO()
        call_command('vendor_stock_summary', '--dry-run', stdout=out)
        self.assertEqual(self.push.call_count, 0)
        self.assertIn('1 kam', out.getvalue())

    def test_summary_helper_never_raises(self):
        self.assertFalse(vendor_push.notify_stock_summary(None, 1, 1))
        self.assertFalse(vendor_push.notify_stock_summary(self.a.vendor_id, 0, 0))
