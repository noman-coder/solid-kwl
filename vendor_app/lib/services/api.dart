import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/dashboard.dart';
import '../models/orders.dart';
import '../models/vendor.dart';
import '../utils.dart';

/// Server fixed hai (app mein kahin dikhaya nahi jata, vendor badal nahi sakta).
/// Sirf developer build ke waqt badal sakta hai:  --dart-define=API_BASE=https://...
const String kDefaultServer =
    String.fromEnvironment('API_BASE', defaultValue: 'https://khanewalconnect.store');

class ApiException implements Exception {
  final String message;
  final int status;

  /// Server ka `code`: auth / pending / locked / bad_login / error ... (net na ho to 'network').
  final String code;

  ApiException(this.message, this.status, {this.code = 'error'});

  /// Token ghalat / expire / password badal gaya -> dobara login chahiye.
  bool get authExpired => status == 401 && code == 'auth';

  /// Account ki approval baqi hai.
  bool get pending => code == 'pending';

  @override
  String toString() => message;
}

/// Login ka natija: vendor + (agar approval baqi ho to) server ka message.
class LoginResult {
  final Vendor vendor;
  final String? message;
  const LoginResult(this.vendor, this.message);
}

class Api {
  static const String server = kDefaultServer;
  static String? token;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    token = p.getString('vendor_token');
  }

  static const String _dashKey = 'vendor_dash_cache';

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    if (token == null) {
      await p.remove('vendor_token');
    } else {
      await p.setString('vendor_token', token!);
    }
  }

  static Uri _u(String path) {
    final base = server.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  /// Server ke relative path (/media/...) ko poora link banao (image dikhane ke liye). Poora link ho to waise hi.
  static String absUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final base = server.trim().replaceAll(RegExp(r'/+$'), '');
    return '$base${path.startsWith('/') ? '' : '/'}$path';
  }

  static Future<Map<String, dynamic>> _req(String method, String path,
      {Map<String, dynamic>? body}) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    http.Response r;
    try {
      if (method == 'GET') {
        r = await http.get(_u(path), headers: headers).timeout(const Duration(seconds: 20));
      } else {
        r = await http
            .post(_u(path), headers: headers, body: jsonEncode(body ?? <String, dynamic>{}))
            .timeout(const Duration(seconds: 20));
      }
    } catch (_) {
      throw ApiException('Internet ya server se rabta nahi ho raha', 0, code: 'network');
    }
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
      );
    }
    return data;
  }

  // ------------------------------------------------------------------
  // Phase V1 / V2 ki API (baqi endpoints aglay phases mein yahin judenge)
  // ------------------------------------------------------------------

  static Future<LoginResult> login(String phone, String password) async {
    token = null;
    await _clearDashCache();
    final d = await _req('POST', '/api/vendor/login/', body: {'phone': phone, 'password': password});
    token = d['token'] as String?;
    await _save();
    final msg = s(d['message']);
    return LoginResult(Vendor.fromJson(asMap(d['vendor'])), msg.isEmpty ? null : msg);
  }

  static Future<void> logout({String? pushToken}) async {
    try {
      await _req('POST', '/api/vendor/logout/',
          body: {if (pushToken != null) 'push_token': pushToken});
    } catch (_) {}
    await clearToken();
  }

  /// Sirf phone se token hatao (server ko bataye baghair) - session khatam hone par.
  static Future<void> clearToken() async {
    token = null;
    await _save();
    await _clearDashCache();
  }

  /// Apna profile / approval status. Approval baqi ho to bhi chalti hai.
  static Future<LoginResult> me() async {
    final d = await _req('GET', '/api/vendor/me/');
    final msg = s(d['message']);
    return LoginResult(Vendor.fromJson(asMap(d['vendor'])), msg.isEmpty ? null : msg);
  }

  // ------------------------------------------------------------------
  // Phase V4: Dashboard
  // ------------------------------------------------------------------

  /// Ek nazar mein poora business. Kamyab jawab phone mein bhi save hota hai (net na ho to purana data dikhane ke liye).
  static Future<DashboardData> dashboard() async {
    final d = await _req('GET', '/api/vendor/dashboard/');
    final data = DashboardData.fromJson(d);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_dashKey, jsonEncode(d));
    } catch (_) {}
    return data;
  }

  /// Phone mein save kiya hua aakhri dashboard (na ho ya kharab ho to null).
  static Future<DashboardData?> cachedDashboard() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_dashKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? DashboardData.fromJson(Map<String, dynamic>.from(decoded)) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearDashCache() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_dashKey);
    } catch (_) {}
  }

  /// Store Open / Closed switch.
  static Future<StoreSwitchResult> setStoreOpen(bool open) async {
    final d = await _req('POST', '/api/vendor/store/open/', body: {'open': open});
    return StoreSwitchResult(
      StoreInfo.fromJson(asMap(d['store'])),
      d['vendor'] is Map ? Vendor.fromJson(asMap(d['vendor'])) : null,
      s(d['message']),
    );
  }

  // ------------------------------------------------------------------
  // Phase V5: Orders
  // ------------------------------------------------------------------

  /// Orders ka ek page. tab: new | active | done, q: order no / customer naam / phone.
  static Future<OrdersPage> orders(String tab, {int page = 1, String q = ''}) async {
    final params = <String, String>{'tab': tab, 'page': '$page'};
    final query = q.trim();
    if (query.isNotEmpty) params['q'] = query;
    final qs = Uri(queryParameters: params).query;
    final d = await _req('GET', '/api/vendor/orders/?$qs');
    return OrdersPage.fromJson(d);
  }

  /// accept | reject | ready | delivered. accept par [prepMinutes], reject par [reasonCode] + [reasonNote].
  static Future<OrderActionResult> orderAction(
    int id,
    String action, {
    int? prepMinutes,
    String? reasonCode,
    String? reasonNote,
  }) async {
    final body = <String, dynamic>{
      if (prepMinutes != null) 'prep_minutes': prepMinutes,
      if (reasonCode != null) 'reason_code': reasonCode,
      if (reasonNote != null && reasonNote.trim().isNotEmpty) 'reason_note': reasonNote.trim(),
    };
    final d = await _req('POST', '/api/vendor/orders/$id/$action/', body: body);
    return OrderActionResult.fromJson(d);
  }

  /// Halka poll: naye orders ki ginti + sab se naya order id.
  static Future<OrdersPoll> ordersPoll() async {
    final d = await _req('GET', '/api/vendor/orders/poll/');
    return OrdersPoll.fromJson(d);
  }

  /// Push notification token (FCM) server par register karo (app side Phase V7 mein use hoga).
  static Future<void> registerPushToken(String pushToken) async {
    await _req('POST', '/api/vendor/push-token/', body: {'token': pushToken, 'platform': 'android'});
  }
}
