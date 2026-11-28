# Customer App (Khanewal Connect - Android)

Grahak (customer) ke liye app. Vendor app (`vendor_app/`) aur rider app ke dhanche par; backend JSON API `api/customer/...`
(`app/customer/views_customer_api.py`). Phase wise ban rahi hai (plan: `docs/Customer_App_Master_Plan.pdf`).

**Abhi: Phase C5 (Stores list + Store detail)** - Stores tab: search, filters (Khula hai / Top rated / Free delivery / Naye / Category),
dukan ki qism, tarteeb, store cards, agla page; Store page: cover, info, coupons, category tabs, products, search, share.
Home ka store card / banner / dukan ki qism / category / search bar ab inhi screens par le jata hai.
Backend: `app/customer/views_customer_stores.py`. Pehle: C3 (Flutter foundation + APK build) - `docs/CUSTOMER_PHASE3.md`;
C4 (Area + Home) - `docs/CUSTOMER_PHASE4.md`; C5 - `docs/CUSTOMER_PHASE5.md`.

- App ka naam (placeholder): **Customer App** - `.github/workflows/build_customer_apk.yml` ke `env: APP_NAME` se.
- Package: `com.khanewal.customer.app` (`env: APP_ID`). Server: `env: API_BASE` (app mein kahin dikhta nahi).
- Build: GitHub > Actions > **Build Customer APK** > artifact `customer-apk`. Push ke liye secret `GOOGLE_SERVICES_JSON_CUSTOMER`.
- Static jaanch: `python3 tool/check_app.py`.
