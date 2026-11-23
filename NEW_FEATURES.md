# Naye Customer / Vendor Features

## Vendor (`/shop/vendor/...`)
| Feature | URL | Kya karta hai |
|---|---|---|
| Sales Analytics | `/shop/vendor/analytics/` | Aaj / 7 / 30 / 90 din ki bikri, orders, average order, cancel %, din ba din chart, top 10 products, kam stock alert |
| CSV Export | `/shop/vendor/analytics/export/` | Usi muddat ke orders Excel-ready CSV mein |
| Quick Update | `/shop/vendor/quick-update/` | Tamam products ki price, discount aur naya stock ek hi page par; sirf badle hue rows save hote hain |

Dashboard ke header mein "Analytics" aur "Quick Update" buttons hain.

## Customer (`/shop/...`)
| Feature | URL | Kya karta hai |
|---|---|---|
| Dobara order | `/shop/order/<id>/reorder/` | Purane order ka maal aaj ki price/stock ke sath cart mein (My Orders aur Order Detail dono mein button) |
| Favorites (heart) | `/shop/favorites/` | Product page par heart; Favorites page se ek click mein cart; My Account aur My Orders se link |

## Technical
- Naya table: `ShopWishlist` (migration `0055_shop_wishlist`, sirf CreateModel; koi table drop/wipe nahi).
- Naye files: `app/customer/views_vendor_tools.py`, `app/customer/views_customer_tools.py`, `app/models/trade/shop_wishlist.py`.
- Admin mein "Shop Favorites" read-only list.
- Quick Update purani logic hi use karta hai (`reprice_open_batches`, `_add_stock`, commission), is liye FIFO/cost/profit ka hisaab waisa hi rehta hai.
- Naya stock sirf jama hota hai (purana stock kabhi overwrite nahi hota).
