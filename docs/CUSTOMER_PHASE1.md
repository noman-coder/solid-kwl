# Customer API - Phase C1 (foundation)

File: `app/customer/views_customer_api.py` | Tests: `app/tests_customer_api.py` | Migration: koi nahi.
Header: `Authorization: Bearer <token>` (salt `customer-api-v1`, 30 din; password badalne par purane token band).
Error: `{ok:false, error, message, code}`.

| Endpoint | Method | Auth | Kaam |
|---|---|---|---|
| `/api/customer/register/` | POST | - | full_name, phone, email, city, address, password, confirm_password, accept_privacy -> 201 + token |
| `/api/customer/login/` | POST | - | phone, password -> token + customer (5 ghalat -> 10 min lock, band account -> 403 `blocked`) |
| `/api/customer/logout/` | POST | token | ok (C2: body `push_token` bhejein to us phone ka push token bhi hat jata hai) |
| `/api/customer/me/` | GET | token | customer + `order_otp_required` + `order_verified` |
| `/api/customer/otp/send/` | POST | token | order OTP email par (60 sec cooldown; trusted ko `skip_otp`) |
| `/api/customer/otp/verify/` | POST | token | `code` (6 digit) -> `verified`, 30 min ke liye order verified |
| `/api/customer/forgot-password/` | POST | - | phone -> code (jawab hamesha ek jaisa) |
| `/api/customer/reset-password/` | POST | - | phone, code, password, confirm_password |

Error codes: `auth`, `bad_login`, `locked`, `blocked`, `rate_limited`, `phone`, `email`, `name`, `city`, `address`,
`password`, `privacy`, `phone_exists`, `email_exists`, `bad_code`, `wait`, `otp_limit`, `email_required`, `no_phone`.

Aglay phases ke helpers: `customer_api([...])` decorator (view ko `(request, profile)` milta hai, customer = `profile.customer`),
`owned_order_or_404(profile, pk)`, `owned_address_or_404(profile, pk)`, `is_order_verified(profile)` (checkout C8 isi se OTP check karega).

Settings (sab optional): `CUSTOMER_API_RATE_LIMIT` / `CUSTOMER_API_RATE_WINDOW` (default band), `CUSTOMER_LOGIN_IP_LIMIT` (60 / 5 min),
`CUSTOMER_REGISTER_IP_LIMIT` (20 / ghanta).

Note: C1 ke waqt migration aakhri **0064** (vendor offers) thi. Customer push token (C2) migration **0065** hai (`docs/CUSTOMER_PHASE2.md`).
