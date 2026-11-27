# Customer App (Khanewal Connect - Android)

Grahak (customer) ke liye app. Vendor app (`vendor_app/`) aur rider app ke dhanche par; backend JSON API `api/customer/...`
(`app/customer/views_customer_api.py`). Phase wise ban rahi hai (plan: `docs/Customer_App_Master_Plan.pdf`).

**Abhi: Phase C4 (Area + Home tab)** - area picker (GPS ya list), Home: search bar, offers carousel, store types, categories,
coupons, offers, nazdeeki stores, recently viewed. Backend: `app/customer/views_customer_home.py`.
Pehle: C3 (Flutter foundation + APK build) - `docs/CUSTOMER_PHASE3.md`; C4 - `docs/CUSTOMER_PHASE4.md`.

- App ka naam (placeholder): **Customer App** - `.github/workflows/build_customer_apk.yml` ke `env: APP_NAME` se.
- Package: `com.khanewal.customer.app` (`env: APP_ID`). Server: `env: API_BASE` (app mein kahin dikhta nahi).
- Build: GitHub > Actions > **Build Customer APK** > artifact `customer-apk`. Push ke liye secret `GOOGLE_SERVICES_JSON_CUSTOMER`.
- Static jaanch: `python3 tool/check_app.py`.
