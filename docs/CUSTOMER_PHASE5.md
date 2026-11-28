# Customer App - Phase C5 (Stores list + Store detail)

Backend + app. **Koi migration nahi** (sirf maujooda tables). Pichli migration 0065 (C2). Agli migration C16 ki (0066).
Purani web portal / rider / vendor API nahi chhedi: sirf nayi `api/customer/stores/...` routes.

## Backend

Nayi file `app/customer/views_customer_stores.py`; `app/urls.py` mein 2 routes; tests `app/tests_customer_stores.py`.
Guest bhi dekh sakta hai (token na ho to guest, ghalat token par 401). Jawab `Cache-Control: no-store`.

| Route | Kaam |
|---|---|
| `GET api/customer/stores/?q=&area=&category=&type=&sort=&open=1&free=1&top=1&new=1&page=&lat=&lng=` | stores ki list: search, filters, sort, page (20 ka) + filter ke liye store types / categories / sort options |
| `GET api/customer/stores/<id>/?category=&q=&page=` | store ka poora page: info (naam, logo, cover, timing, rating, fee, min order, free-delivery, coupons, favorite, share link), menu (categories), products (24 ka page) |

Web ka logic reuse (naya nahi): `views_stores` (`store_serves_area`, `SORTS`, `STATUS_ORDER`, search ka rule), C4 ke helpers
(`resolve_area`, `_live_stores_qs`, `_store_json`, `_product_json`), `store_rating_map` / `store_reviews` (rating bars),
`coupons.available_for_customer`, `offers.overlay`, `FavoriteStore`.

Rules:
- List mein sirf approved stores jin ka koi product live ho; **sirf us area ke stores** (`store_serves_area`). Area ke bahar
  wale kitne hain: `outside_count`. `?area=` khali = sab; na ho to login customer ke default address ka shehar (C4 jaisa).
- Filters: `open=1` (khula / busy), `free=1` (store ki delivery free), `top=1` (rating 4.0+), `new=1` (30 din ke andar approve),
  `type` (dukan ki qism), `category` (jis category ka koi live product ho). `sort`: recommended / nearest (sirf location ho to) /
  rating / fastest / fee / min_order. Ghalat sort / page / id par crash nahi: default par wapas.
- Band store hamesha list ke aakhir mein (har sort ke andar), `is_open=false` + `closed_message`.
- Store detail: approved na ho / na mile to JSON 404 (`code: not_found`). Area ke bahar ka store khul jata hai magar
  `serves_area=false` + `area_message`. Band store / khatam stock ke har product par `can_add=false` ("add" band).
- Sirf live products (`is_active` + `approved`): inactive / pending / rejected kabhi nahi aate.
- Privacy: store ya customer ki coordinates kabhi wapas nahi aati, sirf "2.3 km".
- Rating ke bars aate hain; reviews ki list C14 mein.

## App

| File | Kaam |
|---|---|
| `lib/screens/stores_tab.dart` | Stores tab: "Deliver to" patti, search (0.45 sec ruk kar), chips (Khula hai / Top rated / Free delivery / Naye / Category / Tarteeb), dukan ki qism, store cards, neeche scroll par agla page. Pull-to-refresh, skeleton, error + retry, khali list ka paigham, net band par save kiya hua aakhri pehla page. Tab pehli dafa khulne par hi load hota hai |
| `lib/screens/store_detail.dart` | Store page: cover + back / search / share, info card (rating dabane par bars), band / busy / "area mein deliver nahi" patti, coupons (copy), sticky category tabs, products (category ke hisaab se), search, agla page |
| `lib/widgets/store_product_tile.dart` | Product ki row: tasveer, offer badge, qeemat + purani qeemat, "Add" (band store / khatam stock par band + wajah) |
| `lib/models/stores.dart` | Server ke jawab ke safe models, `StoreQuery` (filters) |
| `lib/widgets/store_card.dart` | "Naya" badge + top categories ke tags |
| `lib/services/api.dart` | `stores()`, `cachedStores()`, `storeDetail()` |
| `lib/services/app_state.dart` | `openStores(params)`: Home ka banner / dukan ki qism / category / search bar se Stores tab filter ke saath khulta hai |
| `lib/screens/home_tab.dart` | Store card, "Sab dekhein", banner (store / stores), dukan ki qism, category, search bar, offers / recently viewed ab chalte hain (product par dabane se uske store ka page; product ka apna page C6 mein) |
| `pubspec.yaml` | naya package `share_plus ^10.1.4` (vendor_app mein pehle se chal raha version) |

Abhi "jald aa raha hai": product detail (C6), "Add" / cart (C7). "Add" dabane par sirf paigham aata hai.

## GitHub / server par
1. Zip repo mein push karein. Koi naya secret nahi.
2. Actions > Django CI/CD: `python manage.py test app.tests_customer_stores -v 2` (migrate ki zaroorat nahi, koi migration nahi).
3. Actions > **Build Customer APK** > artifact `customer-apk`.

## Test kaise karein (5 line)
1. Stores tab: us area ke stores aayein (Home ke barabar); search se naam / shehar / product ke naam se store mile; "Khula hai", "Free delivery", "Top rated", "Naye", Category, Tarteeb kaam karein.
2. Area badlein (upar "Badlein"): doosre area ka store list mein na aaye; "N aur doosre areas mein" likha ho. 20 se zyada stores hon to neeche scroll par agla page.
3. Store kholein: timing, fee, kam az kam order, free-delivery web `/shop/stores/<id>/` ke barabar. Category tab dabane se sirf wahi products; search se store ke andar dhoondhein; share se link jaye.
4. Band store par laal patti aur har product par "Add" band; khatam stock par "Abhi available nahi". Inactive / pending product kabhi na dikhe.
5. Net band karke Stores tab kholen: purani list + "Internet nahi hai" patti; net on karke pull-to-refresh. Home se banner / dukan ki qism / store par dabayein: sahi jagah khule.

## Yaad rakhein
- Is phase ka code bhi Flutter SDK / Django ke baghair likha gaya: `tool/check_app.py` (brackets / imports / server URL / secrets) aur Python compile
  check hui, lekin Django tests aur APK build pehli dafa GitHub par chalenge. Koi error aaye to log (ya screenshot) bhej dein, wohi phase theek kar dein.

## Agla phase
C6 - Products: search, list, detail.
