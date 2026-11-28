# Customer App - Phase C6 (Products: search, list, detail)

Backend + app. **Koi migration nahi** (sirf maujooda tables). Pichli migration 0065 (C2). Agli migration C16 ki (0066).
Purani web portal / rider / vendor API nahi chhedi: sirf nayi `api/customer/products/...` aur `search/suggest/` routes.

## Backend

Nayi file `app/customer/views_customer_products.py`; `app/urls.py` mein 3 routes; tests `app/tests_customer_products.py`.
Guest bhi dekh sakta hai (token na ho to guest, ghalat token par 401). Jawab `Cache-Control: no-store`.

| Route | Kaam |
|---|---|
| `GET api/customer/products/?q=&category=&master=&store=&sort=&price_min=&price_max=&in_stock=1&area=&page=` | products ki talash / list (24 ka page), galat spelling par bhi, filters + sort |
| `GET api/customer/products/<id>/` | product ka poora page: tasveeren, qeemat + purani qeemat, offer (% + khatam hone ka waqt), stock, store, milte julte (8), share link |
| `GET api/customer/search/suggest/?q=` | typing ke liye halki suggestions: products (6), stores (3), categories (3) + `did_you_mean` |

Web ka logic reuse (naya nahi): `find_typo_correction` (galat spelling), `get_product_final_price` (batch + discount + offer),
`_alias_product_ids` (admin ke alias), `offers.overlay`, C4/C5 ke helpers (`resolve_area`, `_product_json`, `_with_stock`,
`store_serves_area`), `store_rating_map`, `RecentlyViewed` (web `track_view` jaisa).

Rules:
- Sirf wohi product jo `is_active` + `approved` ho, vendor wala ho aur us ka store approved ho. Inactive / rejected / pending kabhi nahi
  aata (list mein nahi, detail mein JSON 404 `code: not_found`, suggestions mein nahi).
- Area chuna ho to list mein sirf us area ke stores ke products. Detail mein area ke bahar ka product khulta hai magar
  `serves_area=false`, `can_add=false` + `area_message`.
- Talash: naam, serial, barcode, description, category, brand, alias. Kuch na mile aur lafz 3+ harf ka ho to `find_typo_correction`;
  sahi lafz se products mile to `did_you_mean` + `typo_corrected=true` (nateeje sahi lafz ke). `sort=relevance` (naam se shuru hone wale pehle).
- Qeemat / tarteeb: `price_min`, `price_max`, `sort=price_low|price_high` **final qeemat** (batch + discount + offer) par, Python mein
  (pehle 600 products), taake jo qeemat dikhti hai wahi filter / sort ho. Baqi sorts: newest, name.
- Khatam stock: `in_stock=false`, `can_add=false`, `max_qty=0`. Band store: `store_open=false`, `can_add=false`.
  Stock ki asli tadaad (`low_stock`, "Sirf N bache hain") sirf kam hone par (`low_stock_threshold` ke andar).
- Recently viewed: login customer ka record detail kholne par (purana hata kar upar, max 20). Guest ka nahi. Home ka `recently_viewed` isi se bharta hai.
- Talash ka lafz Traffic Analytics (`ShopSearchLog`) mein bhi jata hai (sirf page 1), session bana kar nahi.
- Privacy: store ki coordinates kabhi wapas nahi aati.

## App

| File | Kaam |
|---|---|
| `lib/screens/search_screen.dart` | Search: haal ki talashein (phone mein, max 8), likhte waqt suggestions, nateeje grid (infinite scroll), filter sheet (category / qeemat / sirf stock mein), tarteeb sheet, filter chips, "kya aap ye dhoondh rahe the" patti, skeleton, error + retry, khali list |
| `lib/screens/product_detail.dart` | Product page: tasveer (swipe + pinch zoom), offer badge + countdown, qeemat + bachat, stock badge, band store / area patti, tafseel, store card (dabane par store page), milte julte, qty stepper, "Cart mein dalein" |
| `lib/widgets/product_grid_card.dart` | Grid card (chhote / bare phone aur text scale par overflow nahi): tasveer, offer badge, "Khatam" / "Store band", add button |
| `lib/models/products.dart` | Server ke jawab ke safe models, `ProductQuery` (filters) |
| `lib/services/api.dart` | `products()`, `productDetail()`, `suggest()`, haal ki talashein |
| `lib/screens/home_tab.dart` | Search bar -> Search screen; offers / recently viewed ke product -> Product page |
| `lib/screens/store_detail.dart` | Product par dabane se Product page |

Abhi "jald aa raha hai": "Cart mein dalein" / "+" (C7). Dabane par sirf paigham aata hai, qty yaad rehti hai. "Khatam hone par batayein"
(optional) nahi banaya. Koi naya package nahi.

## GitHub / server par
1. Zip repo mein push karein. Koi naya secret nahi.
2. Actions > Django CI/CD: `python manage.py test app.tests_customer_products -v 2` (migrate ki zaroorat nahi, koi migration nahi).
3. Actions > **Build Customer APK** > artifact `customer-apk`.

## Test kaise karein (5 line)
1. Home ki search bar dabayein: likhte hi suggestions aayein; "Pepsii" jaisi galat spelling par "kya aap ye dhoondh rahe the" ya sahi nateeje (patti ke sath).
2. Nateeje: filter (category, qeemat Rs min-max, sirf stock mein) aur tarteeb (qeemat kam / zyada, naye, naam) kaam karein; qeemat web `/shop/product/<id>/` ke barabar (offer ke sath).
3. Product kholein: tasveer par dabane se zoom, offer wale product par "% off" + countdown, kam stock par "Sirf N bache hain", khatam stock / band store par button band + wajah.
4. Inactive / pending / rejected product kabhi na dikhe (na list, na suggestions, na seedha link). Area badal kar dekhein: doosre area ke store ke products list mein na aayein.
5. Login karke 2-3 products kholein: Home par "Haal mein dekhe gaye" mein aayein. Net band karke product kholein: saaf error + "Dobara koshish karein".
