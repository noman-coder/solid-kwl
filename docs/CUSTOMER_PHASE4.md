# Customer App - Phase C4 (Area / location + Home tab)

Backend + app. **Koi migration nahi** (sirf maujooda tables). Pichli migration 0065 (C2). Agli migration C16 ki (0066).
Purani web portal / rider / vendor API nahi chhedi: sirf nayi `api/customer/...` routes.

## Backend

Nayi file `app/customer/views_customer_home.py`; `views_customer_api.py` mein ek naya decorator `customer_api_optional`
(guest bhi chalta hai, token ghalat ho to 401); `app/urls.py` mein 4 routes; tests `app/tests_customer_home.py`.

| Route | Kaam |
|---|---|
| `GET api/customer/home/?area=&master=&lat=&lng=` | banners, store types, categories (tiles), nazdeeki stores, offers, recently viewed, coupons, free-delivery limit |
| `GET api/customer/areas/` | DeliveryArea ki list shehar ke hisab se (+ delivery charges mein likhe shehar) |
| `POST api/customer/area/` `{area}` | chuna hua area saaf karke wapas + `known` + us mein kitne stores (khali area = sab) |
| `POST api/customer/location/` `{lat,lng}` | GPS: login customer ki profile mein save, nazdeeki store se area ka mashwara |
| `DELETE api/customer/location/` | saved location hata do |

Web ka logic reuse (naya nahi): `_home_tiles` / `_home_categories` / `_home_masters`, `store_serves_area`, `store_rating_map`,
`attach_distances`, `get_product_final_price`, `offers.live_offers_qs` + `overlay`, `coupons.available_for_customer`,
`ShopBanner.live()`, `RecentlyViewed`, `StoreCategory`, `DeliveryArea`.

Rules:
- **Area server par save nahi hota** (session nahi, migration nahi): app phone mein rakhti aur har request par `?area=` bhejti hai.
  `?area=` na ho to login customer ke default address ka shehar (web jaisa). `?area=` khali = "sab areas".
- Sirf approved stores jin ka koi product live (`is_active` + `approved`) ho. Area ke bahar wale stores nahi (`outside_count` batata hai).
- Band store: `is_open=false` + `closed_message` ("X abhi band hai, baad mein order karein."), list mein sab se neeche.
- Recently viewed: sirf **us customer ka** apna, aur sirf live products / us area ke stores. Guest ko khali.
- Privacy: customer / store ki coordinates kabhi wapas nahi aati, sirf "2.3 km".
- Home ka har hissa alag try/except mein: ek hissa kharab ho to baqi chalte hain (jawab 200).
- Jawab `Cache-Control: no-store`.

## App

| File | Kaam |
|---|---|
| `lib/screens/home_tab.dart` | Home: location header, search bar, free-delivery patti, offers carousel, store types, categories (bari category dabane par uski sub-categories, "Sab categories" se wapas), coupons (copy), offers, stores, recently viewed. Pull-to-refresh, skeleton, error + retry, net band par save kiya hua purana Home |
| `lib/screens/area_picker.dart` | Area chunne ka sheet: "Meri location" (GPS), shehar / area search, "Sab areas". Pehli dafa khud khulta hai (area na ho to) |
| `lib/models/home.dart` | Server ke jawab ke safe models |
| `lib/widgets/` | `net_image` (cache), `store_card`, `product_mini`, `banner_carousel`, `section_header` |
| `lib/services/api.dart` | area / location phone mein save, `home()`, `areas()`, `sendLocation()`, `clearLocation()`, `cachedHome()`, DELETE support |
| `lib/services/app_state.dart` | `setArea()`, `locationChanged()`, `areaVersion` (barhte hi Home dobara load) |
| `pubspec.yaml` | naye packages: `geolocator`, `cached_network_image` |

Abhi "jald aa raha hai" dikhne wale hisse (aglay phases): search bar (C6), store / product / category / store type par tap (C5, C6).
GPS ke liye manifest mein location permission pehle se hai (`patch_manifest.py`); background location nahi maangi.

## GitHub / server par
1. Zip repo mein push karein. Koi naya secret nahi.
2. Actions > Django CI/CD: tests chalayein: `python manage.py test app.tests_customer_home -v 2` (migrate ki zaroorat nahi, koi migration nahi).
3. Actions > **Build Customer APK** > artifact `customer-apk`.

## Test kaise karein (5 line)
1. Naya install: app khulte hi area picker aaye. "Meri location" se (ya list se) area chunein; Home par us area ke stores aayein.
2. Header se area badlein: stores badlein; "Sab areas" par sab stores. Area ke bahar wala store na dikhe.
3. Web `/shop/` ke barabar categories / banners / stores; bari category dabayein to sub-categories, "Sab categories" se wapas.
4. Band store par "abhi band hai" likha ho; coupon par dabane se code copy ho. Login ke baad "Haal hi mein dekhe" sirf apne products.
5. Net band karke Home kholen: purana Home + "Internet nahi hai" patti; net on karke pull-to-refresh.

## Agla phase
C5 - Stores list + store detail.
