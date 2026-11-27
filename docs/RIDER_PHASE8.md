# Rider App - Phase 8: Profile tab

Sirf Flutter (`rider_app/`). Backend, migrations, web portals waise hi - Phase 3 ki `/api/rider/profile/` aur `/api/rider/password/` use hoti hain. Naye packages nahi. Version 1.5.0+6.

## Profile tab
- **Header**: naam, phone, vehicle, deliveries, fee per delivery, kab shamil hue. Edit (pencil) se **naam / vehicle** badal sakte hain (phone login ID hai, nahi badalta).
- **Rating aur reviews**: average + sitare + pichle 10 reviews (order no, comment, tareekh).
- **Password badlein**: purana + naya (kam az kam 6) + dobara; show/hide. Server naya token deta hai, app khud save karti hai (logout nahi hota). Server ki 5-ghalat-koshish ki lock ka message dikhta hai.
- **Permissions madad**: GPS, Location, "Allow all the time", Notifications, Battery Unrestricted - har ek ka status (theek / baqi) + seedha button; Settings se wapas aane par khud dobara check. Xiaomi / Oppo / Vivo / Huawei / Samsung ke steps.
- **Server address**: badalne par pehle purane server se logout, phir naya address save, dobara login. (Token naye server ko nahi jata.)
- **About / version**, **Account delete** (website ka delete page kholta hai - confirm ke baad), **Logout** (confirm dialog).
- Tab khulte hi aur pull-to-refresh par data taaza.

## Files
- NEW  `models/profile.dart`, `screens/password.dart`, `screens/permissions_help.dart`
- EDIT `screens/profile.dart` (poora naya), `services/api.dart` (`changeServer`), `utils.dart` (`kAppVersion`), `pubspec.yaml` (version), `README.md`
- Version badalte waqt `pubspec.yaml` aur `utils.dart` ka `kAppVersion` dono milayein.

## Test (asli phone)
1. Profile kholen: naam / phone / rating / reviews dikhein. Edit se naam badlein -> dashboard / header mein badal jaye.
2. Password: ghalat purana -> error; sahi -> "Password badal gaya", app login rahe; logout karke naye password se login.
3. Permissions madad: status sahi dikhe; "Allow all the time" / battery button kaam kare; Settings se wapas aane par tick aa jaye.
4. Server address badlein (galat bhi) -> logout, login screen par naya address. Account delete -> browser mein page khule.
5. Internet band: error card, app chale.

## Agla: Phase 9 (Polish + APK + QA)
