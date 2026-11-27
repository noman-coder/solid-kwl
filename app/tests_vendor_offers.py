"""
Phase V13-B tests: vendor offers (product par waqt-wala discount).

Run:  python manage.py test app.tests_vendor_offers
Asli FCM ko koi call nahi jati (VendorPushBase push mock karta hai).
"""
import json
from datetime import timedelta
from decimal import Decimal

from django.urls import reverse
from django.utils import timezone

from app.customer import offers as engine
from app.customer.views_customer_portal import get_product_final_price
from app.models import Product, ProductOffer
from app.tests_vendor_api import make_vendor
from app.tests_vendor_stock import StockBase

D = Decimal


def ymd(days=0):
    return (timezone.localdate() + timedelta(days=days)).isoformat()


class OfferBase(StockBase):
    def setUp(self):
        super().setUp()
        # commission 20% -> offer ki hadd 20% (product discount 0 par)
        self.a.commission_percent = D('20')
        self.a.save()
        self.p = self.mk(self.a, 'Biryani', price='100')

    def body(self, product=None, **kw):
        d = {'product_id': (product or self.p).pk, 'discount_percent': 15, 'starts_on': ymd(0), 'ends_on': ymd(5)}
        d.update(kw)
        return d

    def create(self, body=None, profile=None):
        return self.post_json('vendor_api_offers', body or self.body(), profile or self.a)

    def edit(self, pk, body, profile=None):
        return self.client.post(reverse('vendor_api_offer_edit', args=[pk]), json.dumps(body),
                                content_type='application/json', **self.bearer(profile or self.a))

    def toggle(self, pk, body=None, profile=None):
        return self.client.post(reverse('vendor_api_offer_toggle', args=[pk]), json.dumps(body or {}),
                                content_type='application/json', **self.bearer(profile or self.a))

    def delete(self, pk, profile=None):
        return self.client.post(reverse('vendor_api_offer_delete', args=[pk]), '{}', content_type='application/json',
                                **self.bearer(profile or self.a))

    def raw(self, product=None, profile=None, pct='15', start=None, end=None, **kw):
        now = timezone.now()
        return ProductOffer.objects.create(
            product=product or self.p, profile=profile or self.a, discount_percent=D(pct),
            starts_at=start or now - timedelta(hours=1), ends_at=end or now + timedelta(days=2), **kw)


class AuthTests(OfferBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_offers')).status_code, 401)
        self.assertEqual(self.client.get(reverse('vendor_api_offer_products')).status_code, 401)
        self.assertEqual(self.client.post(reverse('vendor_api_offers'), '{}', content_type='application/json').status_code, 401)

    def test_unapproved_vendor_blocked(self):
        c = make_vendor('Naya', '03004444444', approved=False)
        self.assertEqual(self.client.get(reverse('vendor_api_offers'), **self.bearer(c)).status_code, 403)
        self.assertEqual(self.create(profile=c).status_code, 403)
        self.assertEqual(ProductOffer.objects.count(), 0)


class CreateTests(OfferBase):
    def test_create_ok(self):
        r = self.create()
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        o = j['offer']
        self.assertEqual(o['discount_percent'], 15.0)
        self.assertEqual(o['state'], 'live')
        self.assertEqual(o['regular_price'], 100.0)
        self.assertEqual(o['offer_price'], 85.0)
        self.assertEqual(o['ends_on'], ymd(5))
        self.assertEqual(j['summary']['live'], 1)
        self.assertEqual(ProductOffer.objects.count(), 1)

    def test_future_start_is_scheduled(self):
        r = self.create(self.body(starts_on=ymd(2), ends_on=ymd(4)))
        self.assertEqual(r.json()['offer']['state'], 'scheduled')

    def test_product_price_never_changes(self):
        self.create()
        p = Product.objects.get(pk=self.p.pk)
        self.assertEqual(p.price, D('100'))
        self.assertEqual(p.original_price, D('100'))
        self.assertEqual(p.discount_percentage, D('0'))

    def test_other_vendors_product_404(self):
        other = self.mk(self.b, 'Karahi', price='200')
        r = self.create(self.body(product=other))
        self.assertEqual(r.status_code, 404)
        self.assertEqual(ProductOffer.objects.count(), 0)

    def test_pending_or_inactive_product_rejected(self):
        pend = self.mk(self.a, 'Naya', status='pending')
        self.assertEqual(self.create(self.body(product=pend)).status_code, 400)
        off = self.mk(self.a, 'Band')
        Product.objects.filter(pk=off.pk).update(is_active=False)
        self.assertEqual(self.create(self.body(product=off)).status_code, 400)

    def test_percent_validation(self):
        for bad in (0, 0.5, -5, 'abc', None, 500):
            r = self.create(self.body(discount_percent=bad))
            self.assertEqual(r.status_code, 400, bad)
        self.assertEqual(ProductOffer.objects.count(), 0)

    def test_percent_capped_to_commission(self):
        r = self.create(self.body(discount_percent=25))     # commission 20% -> hadd 20
        self.assertEqual(r.status_code, 400)
        self.assertIn('20', r.json()['error'])
        self.assertEqual(self.create(self.body(discount_percent=20)).status_code, 200)

    def test_cap_off_allows_up_to_70(self):
        with self.settings(VENDOR_OFFER_CAP_TO_COMMISSION=False):
            self.assertEqual(self.create(self.body(discount_percent=70)).status_code, 200)
            ProductOffer.objects.all().delete()
            self.assertEqual(self.create(self.body(discount_percent=71)).status_code, 400)

    def test_date_validation(self):
        self.assertEqual(self.create(self.body(ends_on=ymd(-1))).status_code, 400)            # guzri
        self.assertEqual(self.create(self.body(starts_on=ymd(-1), ends_on=ymd(3))).status_code, 400)
        self.assertEqual(self.create(self.body(starts_on=ymd(3), ends_on=ymd(1))).status_code, 400)
        self.assertEqual(self.create(self.body(ends_on='kal')).status_code, 400)
        self.assertEqual(self.create(self.body(ends_on=ymd(200))).status_code, 400)           # 90 din se zyada
        self.assertEqual(ProductOffer.objects.count(), 0)

    def test_starts_on_defaults_to_today(self):
        b = self.body()
        b.pop('starts_on')
        self.assertEqual(self.create(b).json()['offer']['starts_on'], ymd(0))

    def test_overlap_rejected_but_back_to_back_ok(self):
        self.assertEqual(self.create(self.body(starts_on=ymd(0), ends_on=ymd(3))).status_code, 200)
        r = self.create(self.body(starts_on=ymd(2), ends_on=ymd(6)))
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()['code'], 'overlap')
        self.assertEqual(self.create(self.body(starts_on=ymd(4), ends_on=ymd(6))).status_code, 200)

    def test_request_key_dedupes(self):
        b = self.body(request_key='key-abc-12345')
        first = self.create(b)
        second = self.create(b)
        self.assertEqual(first.status_code, 200)
        self.assertTrue(second.json().get('duplicate'))
        self.assertEqual(ProductOffer.objects.count(), 1)

    def test_limit(self):
        for i in range(engine.MAX_VENDOR_OFFERS):
            self.raw(start=timezone.now() - timedelta(days=10 + i), end=timezone.now() - timedelta(days=5 + i))
        r = self.create()
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'limit')


class ListTests(OfferBase):
    def test_only_own_offers(self):
        mine = self.raw()
        other_p = self.mk(self.b, 'Karahi')
        self.raw(product=other_p, profile=self.b)
        j = self.client.get(reverse('vendor_api_offers'), **self.bearer(self.a)).json()
        self.assertEqual([o['id'] for o in j['offers']], [mine.pk])
        self.assertEqual(j['summary']['total'], 1)
        self.assertEqual(j['limits']['max_days'], 90)

    def test_states_and_summary(self):
        now = timezone.now()
        p2, p3, p4 = self.mk(self.a, 'P2'), self.mk(self.a, 'P3'), self.mk(self.a, 'P4')
        self.raw()                                                                    # live
        self.raw(product=p2, start=now + timedelta(days=1), end=now + timedelta(days=3))  # scheduled
        self.raw(product=p3, is_active=False)                                         # paused
        self.raw(product=p4, start=now - timedelta(days=4), end=now - timedelta(days=1))  # ended
        s = self.client.get(reverse('vendor_api_offers'), **self.bearer(self.a)).json()['summary']
        self.assertEqual((s['live'], s['scheduled'], s['paused'], s['ended']), (1, 1, 1, 1))

    def test_product_picker(self):
        self.mk(self.a, 'Pending', status='pending')
        self.mk(self.b, 'Doosre ka')
        self.raw()
        j = self.client.get(reverse('vendor_api_offer_products'), **self.bearer(self.a)).json()
        names = [p['name'] for p in j['products']]
        self.assertEqual(names, ['Biryani'])
        self.assertTrue(j['products'][0]['has_offer'])
        self.assertEqual(j['products'][0]['max_percent'], 20.0)
        q = self.client.get(reverse('vendor_api_offer_products'), {'q': 'zzz'}, **self.bearer(self.a)).json()
        self.assertEqual(q['products'], [])


class EditToggleDeleteTests(OfferBase):
    def test_edit_percent_and_end(self):
        pk = self.create().json()['offer']['id']
        r = self.edit(pk, {'discount_percent': 10, 'starts_on': ymd(0), 'ends_on': ymd(9)})
        self.assertEqual(r.status_code, 200, r.content)
        o = r.json()['offer']
        self.assertEqual((o['discount_percent'], o['ends_on'], o['offer_price']), (10.0, ymd(9), 90.0))

    def test_edit_live_cannot_move_start(self):
        pk = self.create().json()['offer']['id']
        r = self.edit(pk, {'discount_percent': 10, 'starts_on': ymd(1), 'ends_on': ymd(9)})
        self.assertEqual(r.status_code, 400)

    def test_edit_scheduled_can_move_start(self):
        pk = self.create(self.body(starts_on=ymd(2), ends_on=ymd(4))).json()['offer']['id']
        r = self.edit(pk, {'discount_percent': 12, 'starts_on': ymd(3), 'ends_on': ymd(6)})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()['offer']['starts_on'], ymd(3))

    def test_edit_ended_blocked(self):
        now = timezone.now()
        o = self.raw(start=now - timedelta(days=4), end=now - timedelta(days=1))
        r = self.edit(o.pk, {'discount_percent': 10, 'ends_on': ymd(3)})
        self.assertEqual(r.status_code, 409)

    def test_edit_respects_cap_and_overlap(self):
        pk = self.create(self.body(starts_on=ymd(0), ends_on=ymd(2))).json()['offer']['id']
        self.assertEqual(self.edit(pk, {'discount_percent': 50, 'ends_on': ymd(2)}).status_code, 400)
        self.assertEqual(self.create(self.body(starts_on=ymd(4), ends_on=ymd(6))).status_code, 200)
        self.assertEqual(self.edit(pk, {'discount_percent': 10, 'ends_on': ymd(5)}).status_code, 409)

    def test_edit_other_vendor_404(self):
        o = self.raw()
        r = self.edit(o.pk, {'discount_percent': 5, 'ends_on': ymd(3)}, profile=self.b)
        self.assertEqual(r.status_code, 404)
        o.refresh_from_db()
        self.assertEqual(o.discount_percent, D('15'))

    def test_toggle_off_on(self):
        o = self.raw()
        r = self.toggle(o.pk, {'active': False})
        self.assertEqual((r.status_code, r.json()['offer']['state']), (200, 'paused'))
        r = self.toggle(o.pk, {'active': True})
        self.assertEqual(r.json()['offer']['state'], 'live')
        self.assertEqual(self.toggle(o.pk).json()['offer']['state'], 'paused')      # body na ho to ulta

    def test_toggle_on_blocked_when_overlap_or_ended(self):
        a = self.raw(is_active=False)
        self.raw(pct='10')                                                           # isi dauran doosra chalu
        self.assertEqual(self.toggle(a.pk, {'active': True}).status_code, 409)
        now = timezone.now()
        e = self.raw(product=self.mk(self.a, 'P9'), start=now - timedelta(days=3), end=now - timedelta(days=1),
                     is_active=False)
        self.assertEqual(self.toggle(e.pk, {'active': True}).status_code, 409)

    def test_toggle_other_vendor_404(self):
        o = self.raw()
        self.assertEqual(self.toggle(o.pk, profile=self.b).status_code, 404)

    def test_delete(self):
        o = self.raw()
        r = self.delete(o.pk)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()['deleted'])
        self.assertFalse(ProductOffer.objects.filter(pk=o.pk).exists())
        self.assertTrue(Product.objects.filter(pk=self.p.pk).exists())

    def test_delete_other_vendor_404(self):
        o = self.raw()
        self.assertEqual(self.delete(o.pk, profile=self.b).status_code, 404)
        self.assertTrue(ProductOffer.objects.filter(pk=o.pk).exists())


class CustomerPriceTests(OfferBase):
    """Customer ko price: offer chalu ho to kam, warna bilkul pehle jaisi."""

    def final(self):
        return get_product_final_price(Product.objects.get(pk=self.p.pk))

    def test_no_offer_normal_price(self):
        self.assertEqual(self.final(), D('100'))

    def test_live_offer_applies(self):
        self.raw(pct='15')
        self.assertEqual(self.final(), D('85'))

    def test_paused_scheduled_ended_do_not_apply(self):
        now = timezone.now()
        o = self.raw(is_active=False)
        self.assertEqual(self.final(), D('100'))
        o.delete()
        self.raw(start=now + timedelta(days=1), end=now + timedelta(days=3))
        self.assertEqual(self.final(), D('100'))
        ProductOffer.objects.all().delete()
        self.raw(start=now - timedelta(days=3), end=now - timedelta(seconds=1))
        self.assertEqual(self.final(), D('100'))

    def test_unapproved_product_offer_ignored(self):
        self.raw()
        Product.objects.filter(pk=self.p.pk).update(approval_status='pending')
        self.assertEqual(self.final(), D('100'))

    def test_best_of_product_discount_and_offer_no_stacking(self):
        Product.objects.filter(pk=self.p.pk).update(discount_percentage=D('10'))
        self.raw(pct='15')
        self.assertEqual(self.final(), D('85'))          # 15% (10 + 15 nahi)
        ProductOffer.objects.all().delete()
        self.raw(pct='5')
        self.assertEqual(self.final(), D('90'))          # product ka apna 10% bara

    def test_overlay_is_memory_only(self):
        self.raw(pct='15')
        p = Product.objects.get(pk=self.p.pk)
        engine.overlay([p])
        self.assertEqual(p.discount_percentage, D('15'))
        self.assertTrue(p.has_offer)
        p.save()                                          # offer DB mein kabhi nahi likha jata
        fresh = Product.objects.get(pk=self.p.pk)
        self.assertEqual(fresh.discount_percentage, D('0'))
        self.assertEqual(fresh.price, D('100'))
        self.assertEqual(fresh.original_price, D('100'))

    def test_overlay_without_offer_untouched(self):
        p = Product.objects.get(pk=self.p.pk)
        engine.overlay([p])
        self.assertEqual(p.discount_percentage, D('0'))
        self.assertFalse(p.has_offer)

    def test_offer_ends_price_returns(self):
        o = self.raw(pct='15')
        self.assertEqual(self.final(), D('85'))
        ProductOffer.objects.filter(pk=o.pk).update(ends_at=timezone.now() - timedelta(seconds=1))
        self.assertEqual(self.final(), D('100'))

    def test_store_page_shows_offer_price(self):
        self.raw(pct='15')
        r = self.client.get(reverse('store_detail', args=[self.a.pk]))
        self.assertEqual(r.status_code, 200)
        prods = {p.name: p for p in r.context['page_obj']}
        self.assertEqual(prods['Biryani'].final_price, D('85'))
        self.assertTrue(prods['Biryani'].has_discount)
