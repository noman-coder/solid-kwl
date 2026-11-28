# Customer App - Phase C7 (Cart)

Backend + app. **Migration 0066 (additive, sirf 1 nayi table `CustomerCart`)**. Pichli migration 0065 (C2).
Agli migration C16 ki ab **0067** hogi (0066 cart ne le li).
Purani web portal / rider / vendor API nahi chhedi: sirf nayi `api/customer/cart/...` routes.

> Plan mein C7 par "Database: koi nahi" likha tha. Magar web ka cart browser session mein hota hai aur app ke paas session nahi
> (token API), is liye cart server par rakhne ke liye ek chhoti additive table zaroori thi (cache par bharosa nahi: file cache mein
> purani entries khud hat jati hain). Koi purani table / column nahi chhui.

## Backend

Nayi file `app/customer/views_customer_cart.py`, model `app/models/trade/customer_cart.py`, migration
`app/migrations/0066_customer_cart.py`, `app/urls.py` mein 9 routes, tests `app/tests_customer_cart.py`.
Jawab `Cache-Control: no-store`. Login zaroori (sirf `cart/preview/` guest bhi).

| Route | Kaam |
|---|---|
| `GET api/customer/cart/` | cart (qeemat / stock taza dekh kar). Qeemat badli ho to naya dam save + `price_changed` |
| `GET api/customer/cart/count/` | sirf ginti (halka) |
| `POST cart/add/` `{product_id, quantity=1, area?, replace_cart?}` | cart mein dalo |
| `POST cart/update/` `{product_id, quantity}` | quantity badlo (0 = hata do) |
| `POST cart/remove/` `{product_id}` | item hatao (dobara hatane par bhi theek) |
| `POST cart/clear/` | poora cart khali |
| `POST cart/ack/` | "qeemat badal gayi" alert dekh liya |
| `POST cart/merge/` `{items:[{product_id, quantity}]}` | guest ka local cart login ke baad server cart mein |
| `POST cart/preview/` `{items:[...]}` | guest ka cart dikhane ke liye (qeemat, total, warning); kuch save nahi hota |

Web ka logic reuse (naya nahi): `calculate_cart_data` (subtotal / delivery / total / store rules), `get_product_final_price`
(batch + discount + offer), `store_orders.cart_store_id` (ek waqt mein ek store), `cart_store_rules`, `validate_cart_for_order`
(checkout se pehle ka paigham), `offers.overlay`, C4-C6 ke helpers (`_product_json`, `_with_stock`, `resolve_area`, `_live_catalog`,
`store_serves_area`). Cart ka format web session cart jaisa (`{pid: {product_id, name, price, quantity, image, vendor_id}}`), taake
C8 checkout / `place_order` isi ko seedha le sake (`build_cart(items, customer)` -> `payload['can_checkout']`).

Rules:
- Cart sirf us customer ka (`profile.customer`, ek customer = ek cart). Doosre ka cart kabhi nahi.
- Ek waqt mein ek store (web jaisa): doosre store ka maal add ho to 409 `code: cart_conflict` (+ `current_store`, `new_store`);
  `replace_cart=true` se purana cart saaf hoke naya shuru.
- Sirf live product (active + approved + store approved). Band store -> 409 `store_closed`; khatam stock -> 409 `out_of_stock`;
  area ke bahar -> 409 `not_served`; qty barhane par stock se zyada -> 409 `stock` (+ `max_qty`). Ek item max 1000, cart max 100 lines.
- Add / update / remove / clear / merge cart ki row par `select_for_update` + `transaction.atomic` mein (do phone / do tap ek doosre
  ka kaam nahi mitate).
- Cart ki line par `issue`: `unavailable` (hata / inactive / rejected - total mein nahi judta), `out_of_stock`, `store_closed`,
  `low_stock` (qty stock se zyada). `can_checkout` sirf tab true jab koi issue na ho, store khula ho aur minimum order poora ho;
  warna `checkout_message` mein wajah.
- Qeemat badle (batch / discount / offer) to line par `price_changed` + `price_was`; `cart/ack/` ya qty badalne par saaf. Total hamesha naye dam par.
- Qty kam karna stock girne par bhi chalta hai (barhana nahi).
- Merge: server cart ka store bacha rehta hai, doosre store ka guest maal `skipped` (`other_store`), khatam / hata hua bhi `skipped`;
  same product dono mein ho to bari quantity (dobara bhejne par double nahi), stock se zyada nahi.
- Delivery fee / minimum order store ki (web jaisi). `free_delivery` patti sirf jahan web bhi deta hai (abhi vendor stores par `null`).

## App

| File | Kaam |
|---|---|
| `lib/models/cart.dart` | `CartData`, `CartLine`, `CartStore`, `CartFreeDelivery`, `CartResult` (safe parse) |
| `lib/services/cart_controller.dart` | `CartController`: login ho to server cart, guest ho to phone mein (`shared_preferences`) + `cart/preview/` se qeemat; add / qty / remove (foran hat jata hai) / clear / qeemat alert; login par `cart/merge/` |
| `lib/widgets/cart_actions.dart` | `addProductToCart()`: Search, Store page, Product page sab yahi use karte hain; doosre store par "Purana cart khali karein?" dialog; "Cart dekhein" snackbar |
| `lib/screens/cart_tab.dart` | Cart tab: store patti, item card (qty stepper, swipe se hatao + "Wapas"), qeemat badli alert, issue chips, free-delivery bar, minimum order warning, bill, checkout patti, skeleton, khali / error + retry, pull-to-refresh |
| `lib/services/app_state.dart` | `cart` (controller); tab ka badge `cartCount`; login par guest cart merge; logout / session khatam par cart saaf |
| `lib/services/api.dart` | `cart`, `cartPreview`, `cartAdd`, `cartUpdate`, `cartRemove`, `cartClear`, `cartAck`, `cartMerge` |
| `lib/screens/shell.dart`, `product_detail.dart`, `store_detail.dart`, `search_screen.dart` | placeholder hat gaye, asli cart |

Abhi baqi (agle phase): **Checkout karein** button login karwata hai aur cart theek ho to batata hai ke checkout C8 mein judega.

## Kaise test karein (5 steps)

1. Backend: `python manage.py migrate` (0066) phir `python manage.py test app.tests_customer_cart -v 2`.
2. App (guest): Stores > store > "+" dabayein. Cart tab par item, badge, total dikhe. Doosre store ka product dalen to "Purana cart khali karein?" poochhe.
3. Qty +/- , swipe se hatao ("Wapas" se wapas aaye), stock se zyada na lage, "Cart khali karein" chale.
4. Guest cart bhara rakh kar login karein: cart bana rahe (server par), total web cart ke barabar.
5. Vendor panel se qeemat badal kar / stock khatam karke Cart tab dobara kholein: "Qeemat badli" aur "Stock khatam" chips aayen, Checkout band ho.
