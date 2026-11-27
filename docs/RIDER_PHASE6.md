# Rider App - Phase 6: Map tab (live location + direction)

Sirf Flutter (`rider_app/`). Backend, migrations, web portals waise hi (koi naya API / table nahi). Version 1.3.0+4.
Backend mein "assigned" par tracking pehle se on hai (`TRACK_STATUSES`, Phase 3), is liye server ko location accept ke baad se jati hai.

## Map tab
- OpenStreetMap tiles (`flutter_map` + `latlong2`), API key nahi chahiye.
- Rider ka marker (green, chalte hue arrow heading ke saath). Store (orange) aur customer (laal) ke markers.
- Active order ho to route line (OSRM): `assigned` -> store tak, `picked_up / in_transit` -> customer tak. Doori + ETA upar card mein.
- Ek se zyada active order hon to upar chips se order chunein.
- Buttons: "Mujhe center karo" (follow mode; nakshe ko haath lagane par follow band), "Poora route" (zoom out), "Google Maps mein navigate" (+ Call).
- Store/customer ka lat-lng na ho to route nahi banta; navigate button address se Google Maps kholta hai (purana tareeqa).
- Offline ho, GPS band ho, ya internet na ho to saaf message (app crash nahi).

## Location kaise aati hai
- **Server ko** (customer/admin tracking): sirf `Tracker` bhejta hai, sirf jab active order ho (accept se deliver tak). Offline / koi order nahi = kuch nahi jata.
- **Map ko**: `LocationHub`. Tracker chal raha ho to wahi feed karta hai; warna Map tab khulne par chhota local GPS stream
  (server ko kuch nahi jata) aur tab chhodte hi band (battery).

## Files
- NEW  `services/route_service.dart` (RouteProvider interface + OsrmProvider + RouteService cache), `services/location_hub.dart`
- EDIT `screens/map_tab.dart` (poora naya), `services/tracker.dart` (har fix LocationHub ko; notification text), `pubspec.yaml` (flutter_map, latlong2)
- Manifest mein naya kuch nahi (INTERNET + location pehle se hain).

## Route provider badalna (Google / Mapbox / apna OSRM)
`RouteProvider` ka naya class banayein aur `RouteService.provider = ...` set karein. OSRM demo server heavy production ke liye nahi.
Route sirf tab dobara mangta hai jab destination badle, rider 150 m se zyada chale, ya 90 sec guzar jayein.

## Test (asli phone)
1. `cd rider_app && flutter pub get && flutter run --dart-define=API_BASE=https://aap-ki-site` (ya GitHub Action se APK).
2. Online hon, Map tab kholen: marker dikhe aur chalne par move kare.
3. Order accept karein: store tak route line + doori + ETA. "Maal le liya" ke baad route customer tak badal jaye.
4. App minimize / screen lock: server par location update hoti rahe (admin tracking page / `/api/rider/location/`).
5. Internet band: "Route nahi mila" message, app chale. Location band: "Location nahi mil rahi" card + Dobara.
6. Deliver ke baad route hat jaye aur tracking band ho.

## Agla: Phase 7 (Wallet tab: cash handover + kamai)
