"""
Phase V14 tests: vendor reviews API (list, summary / bars, filters, paging, reply, ownership, privacy, web reply still works).

Run:  python manage.py test app.tests_vendor_reviews
Asli FCM ko koi call nahi jati (VendorPushBase push mock karta hai).
"""
import json

from django.urls import reverse

from app.customer.views_extras import MAX_REPLY_LEN
from app.customer.views_vendor_api import REVIEWS_PAGE_SIZE
from app.models import OrderReview
from app.tests_vendor_push import VendorPushBase


class ReviewBase(VendorPushBase):
    def review(self, profile=None, stars=5, comment='', reply='', rider_only=False):
        profile = profile or self.a
        order = self._order(vendor=profile)
        return OrderReview.objects.create(
            sale_order=order, vendor=profile.vendor, vendor_rating=None if rider_only else stars,
            vendor_comment=comment, vendor_reply=reply)

    def list(self, profile=None, **params):
        return self.client.get(reverse('vendor_api_reviews'), params, **self.bearer(profile or self.a))

    def reply(self, pk, text, profile=None):
        return self.client.post(reverse('vendor_api_review_reply', args=[pk]), json.dumps({'reply': text}),
                                content_type='application/json', **self.bearer(profile or self.a))


class AuthTests(ReviewBase):
    def test_requires_token(self):
        self.assertEqual(self.client.get(reverse('vendor_api_reviews')).status_code, 401)
        r = self.client.post(reverse('vendor_api_review_reply', args=[1]), '{}', content_type='application/json')
        self.assertEqual(r.status_code, 401)

    def test_unapproved_vendor_blocked(self):
        from app.tests_vendor_api import make_vendor
        pending = make_vendor('Naya Store', '03005555555', approved=False)
        r = self.list(pending)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()['code'], 'pending')

    def test_wrong_method(self):
        self.assertEqual(self.client.post(reverse('vendor_api_reviews'), '{}', content_type='application/json',
                                          **self.bearer(self.a)).status_code, 405)
        self.assertEqual(self.client.get(reverse('vendor_api_review_reply', args=[1]), **self.bearer(self.a)).status_code, 405)


class ListTests(ReviewBase):
    def test_empty(self):
        d = self.list().json()
        self.assertTrue(d['ok'])
        self.assertEqual(d['reviews'], [])
        self.assertIsNone(d['summary']['avg'])
        self.assertEqual(d['summary']['count'], 0)
        self.assertEqual([b['pct'] for b in d['summary']['bars']], [0, 0, 0, 0, 0])
        self.assertFalse(d['has_more'])
        self.assertEqual(d['max_reply_len'], MAX_REPLY_LEN)

    def test_summary_and_bars(self):
        for s in (5, 5, 4, 1):
            self.review(stars=s)
        d = self.list().json()
        self.assertEqual(d['summary']['count'], 4)
        self.assertEqual(d['summary']['avg'], 3.8)          # 15 / 4 = 3.75 -> 3.8 (web jaisa round)
        bars = {b['stars']: b for b in d['summary']['bars']}
        self.assertEqual([b['stars'] for b in d['summary']['bars']], [5, 4, 3, 2, 1])
        self.assertEqual((bars[5]['count'], bars[5]['pct']), (2, 50))
        self.assertEqual((bars[4]['count'], bars[4]['pct']), (1, 25))
        self.assertEqual(bars[3]['count'], 0)

    def test_avg_matches_dashboard_rating(self):
        from app.customer.views_reviews import vendor_rating
        for s in (5, 4, 4):
            self.review(stars=s)
        self.assertEqual(self.list().json()['summary']['avg'], vendor_rating(self.a.vendor)['avg'])

    def test_only_own_reviews(self):
        mine = self.review(self.a, 5, 'Acha')
        self.review(self.b, 1, 'Bura')
        d = self.list().json()
        self.assertEqual([r['id'] for r in d['reviews']], [mine.pk])
        self.assertEqual(d['summary']['count'], 1)

    def test_rider_only_rating_not_listed(self):
        self.review(rider_only=True)
        self.assertEqual(self.list().json()['summary']['count'], 0)
        self.assertEqual(self.list().json()['reviews'], [])

    def test_row_fields_and_privacy(self):
        rv = self.review(stars=4, comment='Theek tha')
        row = self.list().json()['reviews'][0]
        self.assertEqual(set(row), {'id', 'order_id', 'order_no', 'stars', 'comment', 'name', 'created_at', 'reply', 'replied_at'})
        self.assertEqual(row['id'], rv.pk)
        self.assertEqual(row['order_no'], rv.sale_order.order_no)
        self.assertEqual(row['stars'], 4)
        self.assertEqual(row['comment'], 'Theek tha')
        self.assertEqual(row['name'], 'Zara')               # ek hi naam: poora
        self.assertNotIn('03003333333', json.dumps(row))    # phone / address kabhi nahi

    def test_name_is_shortened(self):
        self.customer.name = 'Hadi Ahmed Khan'
        self.customer.save()
        self.review()
        self.assertEqual(self.list().json()['reviews'][0]['name'], 'Hadi K.')

    def test_newest_first(self):
        first = self.review(stars=5)
        second = self.review(stars=3)
        self.assertEqual([r['id'] for r in self.list().json()['reviews']], [second.pk, first.pk])

    def test_filters(self):
        a = self.review(stars=5)
        b = self.review(stars=2, reply='Maazrat')
        c = self.review(stars=2)
        ids = lambda **p: sorted(r['id'] for r in self.list(**p).json()['reviews'])
        self.assertEqual(ids(), sorted([a.pk, b.pk, c.pk]))
        self.assertEqual(ids(filter='unanswered'), sorted([a.pk, c.pk]))
        self.assertEqual(ids(filter='replied'), [b.pk])
        self.assertEqual(ids(stars=2), sorted([b.pk, c.pk]))
        self.assertEqual(ids(stars=2, filter='unanswered'), [c.pk])
        # summary filter se alag rehti hai
        d = self.list(filter='replied').json()
        self.assertEqual(d['summary']['count'], 3)
        self.assertEqual(d['summary']['unanswered'], 2)
        self.assertEqual(d['summary']['replied'], 1)

    def test_bad_params_fall_back(self):
        self.review(stars=3)
        d = self.list(filter='bogus', stars='abc', page='x').json()
        self.assertEqual((d['filter'], d['stars'], d['page']), ('all', 0, 1))
        self.assertEqual(len(d['reviews']), 1)
        self.assertEqual(self.list(stars=9).json()['stars'], 0)

    def test_paging(self):
        for _ in range(REVIEWS_PAGE_SIZE + 3):
            self.review()
        p1 = self.list().json()
        self.assertEqual(len(p1['reviews']), REVIEWS_PAGE_SIZE)
        self.assertTrue(p1['has_more'])
        p2 = self.list(page=2).json()
        self.assertEqual(len(p2['reviews']), 3)
        self.assertFalse(p2['has_more'])
        self.assertFalse({r['id'] for r in p1['reviews']} & {r['id'] for r in p2['reviews']})


class ReplyTests(ReviewBase):
    def test_reply_saves_and_customer_sees_it(self):
        rv = self.review(stars=4, comment='Acha')
        r = self.reply(rv.pk, '  Shukriya!  ')
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d['ok'])
        self.assertEqual(d['review']['reply'], 'Shukriya!')
        self.assertTrue(d['review']['replied_at'])
        self.assertEqual(d['summary']['unanswered'], 0)
        rv.refresh_from_db()
        self.assertEqual(rv.vendor_reply, 'Shukriya!')
        self.assertIsNotNone(rv.vendor_replied_at)
        # customer store page wahi `store_reviews` use karta hai
        from app.customer.views_reviews import store_reviews
        self.assertEqual(store_reviews(self.a.vendor)['latest'][0]['reply'], 'Shukriya!')

    def test_edit_reply(self):
        rv = self.review(reply='Pehla')
        self.assertEqual(self.reply(rv.pk, 'Doosra').json()['review']['reply'], 'Doosra')
        rv.refresh_from_db()
        self.assertEqual(rv.vendor_reply, 'Doosra')

    def test_empty_reply_removes_it(self):
        rv = self.review(reply='Purana')
        rv.vendor_replied_at = rv.created_at
        rv.save()
        d = self.reply(rv.pk, '   ').json()
        self.assertEqual(d['review']['reply'], '')
        self.assertEqual(d['review']['replied_at'], '')
        self.assertEqual(d['summary']['unanswered'], 1)
        rv.refresh_from_db()
        self.assertEqual(rv.vendor_reply, '')
        self.assertIsNone(rv.vendor_replied_at)

    def test_length_limit(self):
        rv = self.review()
        ok = self.reply(rv.pk, 'a' * MAX_REPLY_LEN)
        self.assertEqual(ok.status_code, 200)
        r = self.reply(rv.pk, 'b' * (MAX_REPLY_LEN + 1))
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()['code'], 'too_long')
        rv.refresh_from_db()
        self.assertEqual(rv.vendor_reply, 'a' * MAX_REPLY_LEN)      # lamba jawab chupke kata nahi, purana bacha

    def test_non_text_reply_rejected(self):
        rv = self.review()
        for bad in (123, ['x'], {'a': 1}):
            self.assertEqual(self.reply(rv.pk, bad).status_code, 400)
        rv.refresh_from_db()
        self.assertEqual(rv.vendor_reply, '')

    def test_other_vendors_review_404(self):
        theirs = self.review(self.b, 1, 'Bura')
        r = self.reply(theirs.pk, 'Hacked')
        self.assertEqual(r.status_code, 404)
        theirs.refresh_from_db()
        self.assertEqual(theirs.vendor_reply, '')

    def test_missing_and_rider_only_review_404(self):
        self.assertEqual(self.reply(99999, 'x').status_code, 404)
        rider_only = self.review(rider_only=True)
        self.assertEqual(self.reply(rider_only.pk, 'x').status_code, 404)

    def test_unapproved_vendor_cannot_reply(self):
        from app.tests_vendor_api import make_vendor
        pending = make_vendor('Naya Store', '03005555555', approved=False)
        rv = self.review(pending)
        self.assertEqual(self.reply(rv.pk, 'x', pending).status_code, 403)

    def test_reply_does_not_change_rating(self):
        rv = self.review(stars=3)
        self.reply(rv.pk, 'Shukriya')
        rv.refresh_from_db()
        self.assertEqual(rv.vendor_rating, 3)


class WebPortalStillWorks(ReviewBase):
    """Web `vendor_review_reply` ab shared helper use karta hai - purana raasta waise hi chalna chahiye."""
    def test_web_reply_and_truncate(self):
        rv = self.review()
        self.client.force_login(self.a.user)
        r = self.client.post(reverse('vendor_review_reply', args=[rv.pk]), {'reply': 'w' * (MAX_REPLY_LEN + 50)})
        self.assertEqual(r.status_code, 302)
        rv.refresh_from_db()
        self.assertEqual(rv.vendor_reply, 'w' * MAX_REPLY_LEN)        # web purane tareeqe se kaat deta hai
        self.assertIsNotNone(rv.vendor_replied_at)

    def test_web_clear_reply(self):
        rv = self.review(reply='Purana')
        self.client.force_login(self.a.user)
        self.client.post(reverse('vendor_review_reply', args=[rv.pk]), {'reply': ''})
        rv.refresh_from_db()
        self.assertEqual(rv.vendor_reply, '')
        self.assertIsNone(rv.vendor_replied_at)
