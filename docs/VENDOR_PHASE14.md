# Vendor App - Phase V14: Reviews & ratings

**Database:** koi migration nahi. `OrderReview` (migrations 0047 / 0056) pehle se hai. Agla migration number **0065**.
Purani web / rider API aur JSON keys nahi badli. Web ka `vendor_reviews` / `vendor_review_reply` waise hi chalta hai.

## Backend (Django) - `app/customer/views_vendor_api.py`
| Endpoint | Kaam |
|---|---|
| `GET /api/vendor/reviews/?filter=all\|unanswered\|replied&stars=1..5&page=1` | `summary` (`avg`, `count`, `replied`, `unanswered`, `bars[5..1]` = `{stars, count, pct}`) + `reviews[]` (naya pehle, 20 ka page) + `has_more` + `max_reply_len` |
| `POST /api/vendor/reviews/<id>/reply/` | body `{reply}`: jawab dein / badlein. Khali = jawab hata dein. Jawab mein `review` + naya `summary` |

Review row: `id, order_id, order_no, stars, comment, name, created_at, reply, replied_at`.

- **Logic dobara nahi likhi:** jawab save karna web wali `views_extras.save_vendor_reply` (web view ab wahi helper use karta hai, behaviour wahi - web 300 se lamba jawab kaat deta hai).
  Rating ka khulasa wahi hisaab (`Avg` of `vendor_rating`, 1 decimal) jo dashboard / store page ka hai.
- **API par lamba jawab (>300 akshar) = 400 `too_long`** (chupke kaatna nahi), taake app aur server ka jawab ek jaisa rahe.
- **Ownership:** sirf `vendor=profile.vendor` ke reviews; doosre vendor ka review ya jis mein store ki rating hi nahi (sirf rider ki) = **404**. Unapproved vendor = 403, token nahi = 401.
- **Privacy:** customer ka naam sirf "Hadi A." (web wala `_reviewer_name`). Phone / address kabhi nahi.
- `summary` aur `bars` filter se alag hain (hamesha poore reviews ka); ghalat `filter` -> `all`, ghalat `stars` -> sab.
- Naye review par push (V2 `notify_new_review`) pehle se thi; ab app mein tap par Reviews screen khulti hai.
- Tests: `app/tests_vendor_reviews.py`.

## App (Flutter) - version 0.14.0+16
- **More > Customers > Reviews** (subtitle mein rating). Screen: average + star patti (tap se star filter), chips Sab / Jawab nahi diya / Jawab diya, review cards, jawab bottom sheet,
  jawab hatana (confirm ke saath), "Order dekhein".
- Pull-to-refresh, agla page, skeleton, empty ("Abhi koi review nahi"), error + retry, net band par purani list (phone mein save), double-tap lock.
- Naye / badle files: `lib/screens/reviews.dart`, `lib/models/reviews.dart`, `Api.reviews / cachedReviews / replyReview`, `screens/more.dart`, `screens/shell.dart` + `services/push.dart` (review push -> Reviews screen).
  Naya package koi nahi.

## Test (5 steps)
1. Server: `python manage.py test app.tests_vendor_reviews app.tests_vendor_push` (migrate ki zaroorat nahi).
2. Customer se ek delivered order par store ko 2 star + comment dilwayein. Vendor app: **push aaye**, tap par seedha Reviews screen khule, review sab se upar ho.
3. **Jawab dein** > likhein > bhejein. Customer ke store page par jawab dikhe. Dobara **Badlein**, phir **Hatayein**: jawab gayab, "Jawab nahi diya" ginti wapas barhe.
4. 300 se zyada akshar likhne ki koshish: counter rok de. Chips (Jawab nahi diya / Jawab diya) aur star patti par tap: list sahi filter ho; average web dashboard ke barabar ho.
5. Net band karke screen kholein: purani list + message. Doosre vendor ka review kabhi na dikhe.
