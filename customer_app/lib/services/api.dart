import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/customer.dart';
import '../models/home.dart';
import '../models/stores.dart';
import '../utils.dart';

/// Server fixed hai (app mein kahin dikhaya nahi jata, customer badal nahi sakta).
/// Sirf developer build ke waqt badal sakta hai:  --dart-define=API_BASE=https://...
const String kDefaultServer =
    String.fromEnvironment('API_BASE', defaultValue: 'https://khanewalconnect.store');

class ApiException implements Exception {
  final String message;
  final int status;

  /// Server ka `code`: auth / locked / bad_login / phone_exists / wait ... (net na ho to 'network').
  final String code;

  /// Server ke jawab ki baqi cheezen (jaise `resend_after`).
  final Map<String, dynamic> data;

  ApiException(this.message, this.status, {this.code = 'error', this.data = const {}});

  /// Token ghalat / expire / password badal gaya -> dobara login chahiye.
  bool get authExpired => status == 401 && code == 'auth';

  /// Net / server se rabta nahi hua.
  bool get isNetwork => code == 'network';

  /// Server ne bohat zyada requests / koshishon par rok diya (429).
  bool get rateLimited => status == 429;

  @override
  String toString() => message;
}

/// Customer app ka server se rabta (Bearer token, JSON). Customer API: `/api/customer/...`.
class Api {
  static const String server = kDefaultServer;

  /// Login ke baad ka token (30 din). Null = guest.
  static String? token;

  /// Phone mein save kiya hua customer (app khulte hi naam dikhane ke liye, net ke baghair bhi).
  static Customer? cachedCustomer;

  // ---- Browse (Phase C4): customer ka chuna hua area + GPS location. Guest ke liye bhi (phone mein save).
  /// Chuna hua area ('' = sab areas). `areaChosen` false ho to server login customer ke default address ka shehar leta hai.
  static String area = '';
  static bool areaChosen = false;

  /// Pehli dafa area picker dikha diya? (dobara zabardasti nahi dikhta)
  static bool areaPrompted = false;

  /// GPS location (sirf tab jab customer ne khud 'Meri location' dabaya). Server ko faasle ke liye jati hai.
  static double? lat;
  static double? lng;

  static const String _kArea = 'browse_area';
  static const String _kAreaChosen = 'browse_area_chosen';
  static const String _kAreaPrompted = 'browse_area_prompted';
  static const String _kLat = 'browse_lat';
  static const String _kLng = 'browse_lng';
  static const String _kHomeCache = 'home_cache_v1';
  static const String _kStoresCache = 'stores_cache_v1';

  /// Internet / server se rabta nahi (aakhri request fail hui) - shell par 'offline' patti dikhti hai.
  /// Kisi bhi request ke kamyab hote hi khud band.
  static final ValueNotifier<bool> offline = ValueNotifier<bool>(false);

  /// Token ghalat / expire hone par (AppState lagata hai): customer ko guest bana do + message.
  static void Function()? onAuthExpired;

  static const String _kToken = 'customer_token';
  static const String _kCustomer = 'customer_cache';

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      area = p.getString(_kArea) ?? '';
      areaChosen = p.getBool(_kAreaChosen) ?? false;
      areaPrompted = p.getBool(_kAreaPrompted) ?? false;
      lat = p.getDouble(_kLat);
      lng = p.getDouble(_kLng);
      token = p.getString(_kToken);
      final raw = p.getString(_kCustomer);
      if (token != null && raw != null) {
        final m = jsonDecode(raw);
        if (m is Map) cachedCustomer = Customer.fromJson(Map<String, dynamic>.from(m));
      }
    } catch (_) {
      // kharab save kiya hua data: guest ki tarah shuru
      token = null;
      cachedCustomer = null;
    }
  }

  static Future<void> _saveSession(String tok, Customer c) async {
    token = tok;
    cachedCustomer = c;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kToken, tok);
      await p.setString(_kCustomer, jsonEncode(c.raw));
    } catch (_) {}
  }

  /// Customer ka taza data phone mein save (me() ke baad).
  static Future<void> saveCustomer(Customer c) async {
    cachedCustomer = c;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kCustomer, jsonEncode(c.raw));
    } catch (_) {}
  }

  /// Token + save kiya hua customer mita do (logout / session khatam).
  static Future<void> clearSession() async {
    token = null;
    cachedCustomer = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kToken);
      await p.remove(_kCustomer);
    } catch (_) {}
  }

  static Uri _u(String path) {
    final base = server.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  /// Server ke relative path (/media/...) ko poora link banao (image / privacy page ke liye). Poora link ho to waise hi.
  static String absUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final base = server.trim().replaceAll(RegExp(r'/+$'), '');
    return '$base${path.startsWith('/') ? '' : '/'}$path';
  }

  /// Timeout ya net toot'ne par GET ek dafa khud dobara try hota hai (sust / VPN wale net par aksar dusri koshish chal jati hai).
  /// POST kabhi khud dobara nahi bheja jata (double action / double order na ho).
  /// Cloudflare / gateway ke 52x aur 502-504: server tak raasta nahi bana (VPN ke baghair aksar 522).
  static bool _gateway(int s) => s == 502 || s == 503 || s == 504 || (s >= 520 && s <= 524);

  static Future<Map<String, dynamic>> _req(String method, String path,
      {Map<String, dynamic>? body, bool notifyAuth = true}) async {
    final sentToken = token;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (sentToken != null) 'Authorization': 'Bearer $sentToken',
    };
    final attempts = method == 'GET' ? 3 : 1;   // sirf GET dobara (POST / DELETE nahi)
    var timedOut = false;
    for (var i = 0; i < attempts; i++) {
      try {
        http.Response r;
        if (method == 'GET') {
          r = await http.get(_u(path), headers: headers).timeout(const Duration(seconds: 25));
        } else if (method == 'DELETE') {
          r = await http.delete(_u(path), headers: headers).timeout(const Duration(seconds: 25));
        } else {
          r = await http
              .post(_u(path), headers: headers, body: jsonEncode(body ?? <String, dynamic>{}))
              .timeout(const Duration(seconds: 25));
        }
        final out = _decode(r);
        if (offline.value) offline.value = false;
        return out;
      } on ApiException catch (e) {
        if (_gateway(e.status)) {
          if (i < attempts - 1) { await Future.delayed(Duration(seconds: i + 1)); continue; }
          offline.value = true;
          throw ApiException('Server tak raasta nahi ban raha. Thori dair baad dobara koshish karein.', e.status, code: 'network');
        }
        if (offline.value) offline.value = false; // server ne jawab diya = net chal raha hai
        // Is token se request gayi aur server ne kaha "dobara login": session khatam
        if (e.authExpired && notifyAuth && sentToken != null && token == sentToken) {
          await clearSession();
          onAuthExpired?.call();
        }
        rethrow; // server ne jawab de diya (ghalat password, 404 ...) - dobara bhejne ka faida nahi
      } on TimeoutException {
        timedOut = true;
      } catch (_) {
        timedOut = false;
      }
    }
    offline.value = true;
    throw ApiException(
      timedOut
          ? 'Server se jawab bohat dair se aa raha hai. Net / VPN check karke dobara koshish karein.'
          : 'Internet ya server se rabta nahi ho raha. Net / VPN check karein.',
      0,
      code: 'network',
    );
  }

  /// Server ka jawab JSON mein kholo; galti ho to ApiException.
  static Map<String, dynamic> _decode(http.Response r) {
    var data = <String, dynamic>{};
    try {
      final decoded = jsonDecode(utf8.decode(r.bodyBytes));
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    if (r.statusCode >= 400 || data['ok'] == false) {
      final msg = s(data['message'] ?? data['error']);
      throw ApiException(
        msg.isEmpty ? 'Kuch masla aa gaya (${r.statusCode}). Dobara koshish karein.' : msg,
        r.statusCode,
        code: s(data['code']).isEmpty ? 'error' : s(data['code']),
        data: data,
      );
    }
    return data;
  }

  static Customer _customerOf(Map<String, dynamic> d) {
    final c = d['customer'];
    if (c is! Map) throw ApiException('Server ka jawab theek nahi aaya. Dobara koshish karein.', 500);
    return Customer.fromJson(Map<String, dynamic>.from(c));
  }

  static AuthResult _authResult(Map<String, dynamic> d) {
    final tok = s(d['token']);
    if (tok.isEmpty) throw ApiException('Server ka jawab theek nahi aaya. Dobara koshish karein.', 500);
    final c = _customerOf(d);
    unawaited(_saveSession(tok, c)); // token / customer foran set hota hai, phone mein save peeche chalta hai
    return AuthResult(c, s(d['message']));
  }

  // ------------------------------------------------------------------ auth (Phase C1 ki API)

  static Future<AuthResult> login(String phone, String password) async {
    final d = await _req('POST', '/api/customer/login/', body: {'phone': phone, 'password': password});
    return _authResult(d);
  }

  static Future<AuthResult> register({
    required String fullName,
    required String phone,
    required String email,
    required String city,
    required String address,
    required String password,
    required String confirmPassword,
  }) async {
    final d = await _req('POST', '/api/customer/register/', body: {
      'full_name': fullName,
      'phone': phone,
      'email': email,
      'city': city,
      'address': address,
      'password': password,
      'confirm_password': confirmPassword,
      'accept_privacy': true,
    });
    return _authResult(d);
  }

  /// Token ka customer (+ order OTP ki halat). Token ghalat ho to ApiException (authExpired) aur session khatam.
  static Future<MeResult> me() async {
    final d = await _req('GET', '/api/customer/me/');
    final c = _customerOf(d);
    await saveCustomer(c);
    return MeResult(c, toB(d['order_otp_required']), toB(d['order_verified']));
  }

  /// Logout: server ko batao (is phone ka push token wahan se hat jaye), phir phone se token mita do.
  /// Net na ho to bhi phone se logout ho jata hai.
  static Future<void> logout({String? pushToken}) async {
    if (token != null) {
      try {
        await _req('POST', '/api/customer/logout/',
            body: {if (pushToken != null && pushToken.isNotEmpty) 'push_token': pushToken}, notifyAuth: false);
      } catch (_) {}
    }
    await clearSession();
  }

  /// Order OTP bhejo (email par). Bharosay-mand customer ko `skip` true milta hai.
  static Future<OtpSendResult> otpSend() async {
    final d = await _req('POST', '/api/customer/otp/send/');
    return OtpSendResult(
      skip: toB(d['skip_otp']),
      email: s(d['email']),
      message: s(d['message']),
      resendAfter: toI(d['resend_after'], 60),
      emailSent: d['email_sent'] == null ? true : toB(d['email_sent']),
    );
  }

  /// 6-digit OTP check. Theek ho to taza customer (phone_verified true).
  static Future<Customer> otpVerify(String code) async {
    final d = await _req('POST', '/api/customer/otp/verify/', body: {'code': code});
    final c = _customerOf(d);
    await saveCustomer(c);
    return c;
  }

  /// Password bhool gaye: phone par code bhejo. Jawab hamesha ek jaisa (phone registered ho ya na ho).
  static Future<String> forgotPassword(String phone) async {
    final d = await _req('POST', '/api/customer/forgot-password/', body: {'phone': phone});
    return s(d['message']);
  }

  /// Code + naya password. Kamyabi par server ka message; purane saare login band ho jate hain.
  static Future<String> resetPassword({
    required String phone,
    required String code,
    required String password,
    required String confirmPassword,
  }) async {
    final d = await _req('POST', '/api/customer/reset-password/', body: {
      'phone': phone,
      'code': code,
      'password': password,
      'confirm_password': confirmPassword,
    });
    return s(d['message']);
  }

  /// Push token server par register (Phase C11 yahi use karegi).
  static Future<void> registerPushToken(String pushToken) async {
    await _req('POST', '/api/customer/push-token/', body: {'token': pushToken, 'platform': 'android'});
  }

  // ------------------------------------------------------------------ area / location / home (Phase C4 ki API)

  /// Area chuno (khali = sab areas) aur phone mein save karo.
  static Future<void> saveArea(String value) async {
    area = value.trim();
    areaChosen = true;
    areaPrompted = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kArea, area);
      await p.setBool(_kAreaChosen, true);
      await p.setBool(_kAreaPrompted, true);
    } catch (_) {}
  }

  /// Area picker pehli dafa dikha diya - dobara apne aap nahi khulega.
  static Future<void> markAreaPrompted() async {
    areaPrompted = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAreaPrompted, true);
    } catch (_) {}
  }

  static Future<void> saveLocationLocal(double la, double lo) async {
    lat = la;
    lng = lo;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_kLat, la);
      await p.setDouble(_kLng, lo);
    } catch (_) {}
  }

  static Future<void> clearLocationLocal() async {
    lat = null;
    lng = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kLat);
      await p.remove(_kLng);
    } catch (_) {}
  }

  /// Home ka data. `master` ho to us bari category ki sub-categories. Kamyab (aur master nahi) jawab phone mein save hota hai,
  /// taake net band ho to purana data dikh sake.
  static Future<HomeData> home({int? master}) async {
    final q = <String, String>{
      if (areaChosen) 'area': area,
      if (master != null) 'master': '$master',
      if (lat != null && lng != null) 'lat': lat!.toStringAsFixed(5),
      if (lat != null && lng != null) 'lng': lng!.toStringAsFixed(5),
    };
    final path = Uri(path: '/api/customer/home/', queryParameters: q.isEmpty ? null : q).toString();
    final d = await _req('GET', path);
    if (master == null) {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(_kHomeCache, jsonEncode(d));
      } catch (_) {}
    }
    return HomeData.fromJson(d);
  }

  /// Phone mein save kiya hua aakhri Home (net band ho to). Na ho / kharab ho to null.
  static Future<HomeData?> cachedHome() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kHomeCache);
      if (raw == null) return null;
      final m = jsonDecode(raw);
      return m is Map ? HomeData.fromJson(Map<String, dynamic>.from(m)) : null;
    } catch (_) {
      return null;
    }
  }

  /// Areas ki list (shehar -> areas).
  static Future<List<AreaGroup>> areas() async {
    final d = await _req('GET', '/api/customer/areas/');
    return listOfMaps(d['groups']).map(AreaGroup.fromJson).toList();
  }

  /// GPS location server ko (login customer ki profile mein save + nazdeeki area ka mashwara).
  static Future<LocationResult> sendLocation(double la, double lo) async {
    final d = await _req('POST', '/api/customer/location/', body: {'lat': la, 'lng': lo});
    return LocationResult.fromJson(d);
  }

  /// Saved location hatao (server par bhi, login ho to).
  static Future<void> clearLocation() async {
    await clearLocationLocal();
    if (token != null) {
      try {
        await _req('DELETE', '/api/customer/location/', notifyAuth: false);
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------------ stores (Phase C5 ki API)

  /// Area / location ke params (Home jaise): chuna hua area aur GPS (ho to).
  static Map<String, String> _browseParams() => {
        if (areaChosen) 'area': area,
        if (lat != null && lng != null) 'lat': lat!.toStringAsFixed(5),
        if (lat != null && lng != null) 'lng': lng!.toStringAsFixed(5),
      };

  /// Stores ki list (filters + sort + page). Bina filter / sort ka pehla page kamyab ho to phone mein save hota hai,
  /// taake net band ho to dikh sake.
  static Future<StoreListData> stores(StoreQuery query, {int page = 1}) async {
    final q = <String, String>{
      ..._browseParams(),
      ...query.toParams(),
      if (page > 1) 'page': '$page',
    };
    final path = Uri(path: '/api/customer/stores/', queryParameters: q.isEmpty ? null : q).toString();
    final d = await _req('GET', path);
    if (page == 1 && !query.hasFilters && query.sort.isEmpty) {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(_kStoresCache, jsonEncode(d));
      } catch (_) {}
    }
    return StoreListData.fromJson(d);
  }

  /// Phone mein save kiya hua aakhri (bina filter) pehla page. Na ho / kharab ho to null.
  static Future<StoreListData?> cachedStores() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kStoresCache);
      if (raw == null) return null;
      final m = jsonDecode(raw);
      return m is Map ? StoreListData.fromJson(Map<String, dynamic>.from(m)) : null;
    } catch (_) {
      return null;
    }
  }

  /// Ek store ka poora page. `category`: null = sab, 0 = bina category wale.
  static Future<StoreDetailData> storeDetail(int id, {int? category, String q = '', int page = 1}) async {
    final params = <String, String>{
      ..._browseParams(),
      if (category != null) 'category': '$category',
      if (q.isNotEmpty) 'q': q,
      if (page > 1) 'page': '$page',
    };
    final path =
        Uri(path: '/api/customer/stores/$id/', queryParameters: params.isEmpty ? null : params).toString();
    final d = await _req('GET', path);
    return StoreDetailData.fromJson(d);
  }
}
