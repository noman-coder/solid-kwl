# Vendor App - Phase V9-A: Product add / edit (bina photo)

Backend (Django API) + Flutter app. **Database mein koi tabdeeli nahi** (migration abhi bhi **0061**, existing Product tables). Purana web portal, rider app / API aur V1-V8 ki
API nahi toote: web ke `vendor_product_add` / `vendor_product_edit` / `vendor_create_master` ka logic sirf **shared helper** mein nikala gaya hai (rawayya wahi).

## Backend (`app/customer/views_vendor_api.py`, `views_vendor_portal.py`, `urls.py`)
| Route | Kaam |
|---|---|
| `GET  /api/vendor/products/form-data/[?product=<id>]` | categories / brands / units, limits, commission %, `auto_approve`, `can_add`; `product=` dein to apne product ki maujooda values (edit form) |
| `POST /api/vendor/products/` | naya product (JSON ya multipart, `image` optional, `request_key` optional) |
| `POST /api/vendor/products/<id>/` | edit (JSON ya multipart). Jo field na bheji jaye wo waisi hi rehti hai |
| `POST /api/vendor/masters/<category\|brand\|unit>/` | "+" button: naya naam (wohi naam ho to `existed: true` ke saath wohi wapas) |

- **Reuse (naya logic nahi):** `_clean_product_form` (ab `post=`, `files=`, `require_image=` leta hai, web ke default wahi), `_validate_image` (5 MB, JPG/PNG/WEBP),
  `_save_new_product` (ab `user=`, `force_pending=`), naya `_apply_product_edit` (web edit ka logic ek jagah), naya `create_master_entry` (web "+" ka logic ek jagah, 20 naam / ghanta).
- **Auto-approve (`VENDOR_AUTO_APPROVE_PRODUCTS`):** True ho to photo wala product foran live; **bina photo wala product auto-approve par bhi pending** (`needs_photo: true`). Pending bina-photo
  product ko edit se photo mil jaye aur auto-approve on ho to wo live ho jata hai.
- **Edit ke usool (web jaise):** `price` = discount se pehle ka rate; `stock` = **naya stock jo jama karna hai** (0 / khali = koi nahi); naam / tafseel / category / brand / photo badle to
  (auto-approve na ho) approved product dobara pending (`resubmitted`); rejected product edit par pending. Open batches ka reprice + margin policy (ValidationError -> saaf 400).
- **Double tap / retry:** `request_key` (8-64 harf/ankre) ek hi vendor ke liye 10 min tak ek hi product banata hai (`duplicate: true`); chalte hue save par doosri request 409 `in_progress`.
- **Ghaltiyan:** `{ok:false, error, message, code:'validation', errors:[...]}` - saari ghaltiyan ek saath. Doosre vendor ka product / ghalat kind -> 404. NaN stock ab web par bhi band.
- Photo (multipart `image`) backend par abhi se chalti hai aur tests mein hai; **app mein photo V9-B mein**.
- Barcode: web ki tarah khud ban jata hai (form mein nahi). "Purchase rate" form mein nahi: web mein bhi nahi, cost = vendor ka hissa (rate - commission) khud nikalta hai - form is ka andaza dikhata hai.

## App (`vendor_app/`)
- **NEW** `lib/screens/product_form.dart`: 3 step - **Basic** (naam, category search sheet, brand, unit, tafseel) > **Rate / Stock** (live "customer ko rate" + "aap ko milega") > **Review** (har section par "Badlein").
  Category / brand / unit ka search sheet: na mile to "+ naya banayein". **Draft** (naye product ka adhoora form phone mein, "Naya shuru" se saaf). Submit par `request_key`. Error / retry / skeleton.
- `lib/screens/products.dart`: **Naya product** floating button, khali list par "Pehla product add karein", quick edit mein **Poora edit**.
- `lib/models/products.dart`, `services/api.dart`, `services/app_state.dart`: form-data, saveProduct, createMaster. Version 0.9.0 (9).

## Kaise test karein (5 line)
1. `python manage.py test app.tests_vendor_product_form app.tests_vendor_products tests.test_vendor_portal` (sab pass hon).
2. Server push karein, Actions ka Django CI/CD (migrate koi nahi) sabz ho.
3. **Build Vendor APK** chalayein, install karein, Products tab > **Naya product**: Basic > Rate/Stock > Review > bhejein (Pending mein "photo baqi" wala product dikhe).
4. Category mein naya naam likh kar "+ naya" banayein; adhoora form chhor kar app band karein - dobara kholne par draft wapas aaye; net band kar ke submit - error aaye, data bacha rahe.
5. Quick edit > **Poora edit**: naam badlein (dobara review), sirf rate badlein (review nahi), stock jama karein; web portal par wahi product dekh kar rate / stock match karein.

## Files
- EDIT `app/customer/views_vendor_api.py`, `app/customer/views_vendor_portal.py`, `app/urls.py`
- NEW  `app/tests_vendor_product_form.py`, `vendor_app/lib/screens/product_form.dart`, `docs/VENDOR_PHASE9A.md`
- EDIT `vendor_app/lib/{models/products,services/api,services/app_state,screens/products,utils}.dart`, `vendor_app/pubspec.yaml`, `vendor_app/README.md`
