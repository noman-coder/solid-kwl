# Vendor App - Phase V9-B: Product ki photo

V9-A (form, bina photo) ke upar. **Faisla:** product ki sirf **ek main photo** (`Product.image`) - koi gallery table nahi, **koi migration nahi** (migration abhi bhi aakhri 0061, agla 0062).
Multiple images chahiye hon to alag phase mein `ProductImage` table (migration 0062) + shop / admin par dikhane ka kaam banega.

## App (Flutter)
- `lib/services/photo.dart` (naya): `PhotoService` - `pick` (image_picker camera / gallery), `crop` (image_cropper), `compress` (flutter_image_compress:
  lambi side ~1280 px, quality 80 -> 70 -> 65 -> 60 -> 50 aur size 1280 -> 640 jab tak 1 MB se kam; server limit se bari ho to saaf message), `recoverLost` (camera ke dauran app band ho gayi ho to photo wapas).
- `lib/screens/product_form.dart`: 4 steps (Basic / Rate-Stock / **Photo** / Review). Photo step: preview, Camera, Gallery, Dobara crop, Hatayein. Review mein photo card, upload progress card.
  Submit par double tap lock, upload ke dauran peeche jana band, fail par retry (form + photo + request key wohi). Draft mein `photo` path (sirf `vendor_photos` temp folder ki file); kamyab submit par draft + temp photo saaf.
- `lib/services/api.dart`: `saveProduct(photo:, onProgress:)` - photo ho to multipart (`image`), upload progress; 413 par saaf message.
- `lib/screens/products.dart`: `needs_photo` wale card par **Photo lagayein** nishan -> edit form seedha Photo step par.
- `pubspec.yaml`: `image_picker`, `image_cropper`, `flutter_image_compress`. `tool/patch_manifest.py`: `UCropActivity` + camera `queries` (CAMERA permission jaan-boojh kar nahi).

## Backend (Django) - chhoti tabdeeliyan
- `needs_photo` har product JSON mein (list card).
- Edit jawab mein `live` + photo ke hisab se message (photo lagi / badli / dobara review). Photo storage fail ho to edit mein saaf message aur kuch nahi badalta.
- Add mein photo upload (storage) fail ho to product **na toote**: bina photo ke save (pending), `photo_failed: true`.
- Tests: `app/tests_vendor_product_photo.py`.

## Test
`python manage.py test app.tests_vendor_product_photo app.tests_vendor_product_form`
