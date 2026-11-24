import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Server fixed hai (app mein kahin dikhaya nahi jata, rider badal nahi sakta).
/// Sirf developer build ke waqt badal sakta hai:  --dart-define=API_BASE=https://...
const String kDefaultServer =
    String.fromEnvironment('API_BASE', defaultValue: 'https://khanewalconnect.store');

class ApiException implements Exception {
  final String message;
  final int status;

  /// true = token ghalat / expire (dobara login chahiye). Ghalat password jaise 401 par false.
  final bool authExpired;
  ApiException(this.message, this.status, {this.authExpired = false});
  @override
  String toString() => message;
}

class Api {
  static const String server = kDefaultServer;
  static String? token;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('server'); // purane build ka saved address ab use nahi hota
    token = p.getString('token');
  }

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    if (token == null) {
      await p.remove('token');
    } else {
      await p.setString('token', token!);
    }
  }

  static Uri _u(String path) {
    final base = server.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
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
      throw ApiException('Internet ya server se rabta nahi ho raha', 0);
    }
    Map<String, dynamic> data = <String, dynamic>{};
    try {
      final decoded = jsonDecode(utf8.decode(r.bodyBytes));
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    if (r.statusCode == 401 && path != '/api/rider/login/') {
      // Server token ghalat ho to error == 'auth'. Warna (jaise ghalat purana password) sirf message dikhao.
      if (data['error'] == 'auth' || data['message'] == null) {
        throw ApiException('Dobara login karein', 401, authExpired: true);
      }
    }
    if (r.statusCode >= 400 || data['ok'] == false) {
      throw ApiException((data['message'] ?? 'Error ${r.statusCode}').toString(), r.statusCode);
    }
    return data;
  }

  // ------------------------------------------------------------------
  // Purani methods (waisi hi)
  // ------------------------------------------------------------------

  static Future<void> login(String phone, String password) async {
    token = null;
    final d = await _req('POST', '/api/rider/login/', body: {'phone': phone, 'password': password});
    token = d['token'] as String?;
    await _save();
  }

  static Future<void> logout({String? pushToken}) async {
    try {
      await _req('POST', '/api/rider/logout/',
          body: {if (pushToken != null) 'push_token': pushToken});
    } catch (_) {}
    token = null;
    await _save();
  }

  /// Push notification token (FCM) server par register karo.
  static Future<void> registerPushToken(String pushToken) async {
    await _req('POST', '/api/rider/push-token/', body: {'token': pushToken, 'platform': 'android'});
  }

  static Future<Map<String, dynamic>> orders() => _req('GET', '/api/rider/orders/');

  static Future<void> setOnline(bool online) async {
    await _req('POST', '/api/rider/online/', body: {'online': online});
  }

  static Future<String> accept(int id) async {
    final d = await _req('POST', '/api/rider/orders/$id/accept/');
    return (d['message'] ?? 'Order mil gaya').toString();
  }

  /// action: 'pickup' ya 'deliver'
  static Future<String> action(int id, String action) async {
    final d = await _req('POST', '/api/rider/orders/$id/$action/');
    return (d['message'] ?? 'Ho gaya').toString();
  }

  static Future<void> sendLocation(
      double lat, double lng, double acc, double spd, double hdg) async {
    await _req('POST', '/api/rider/location/',
        body: {'lat': lat, 'lng': lng, 'acc': acc, 'spd': spd, 'hdg': hdg});
  }

  // ------------------------------------------------------------------
  // Naye endpoints (backend Phase 1-3). Screens Phase 5-8 mein inhein use karengi.
  // ------------------------------------------------------------------

  /// Aaj / hafta / mahina stats, cash, rating, 7-din chart, warnings.
  static Future<Map<String, dynamic>> dashboard() => _req('GET', '/api/rider/dashboard/');

  /// Delivered / cancelled orders. from / to format: YYYY-MM-DD.
  static Future<Map<String, dynamic>> history(
      {int page = 1, int pageSize = 20, String? from, String? to, String? status}) {
    final q = <String, String>{
      'page': '$page',
      'page_size': '$pageSize',
      if (from != null && from.isNotEmpty) 'from': from,
      if (to != null && to.isNotEmpty) 'to': to,
      if (status != null && status.isNotEmpty) 'status': status,
    };
    return _req('GET', '/api/rider/history/?${Uri(queryParameters: q).query}');
  }

  /// Aik order ki mukammal detail + status timeline (id = order ki id).
  static Future<Map<String, dynamic>> orderDetail(int id) => _req('GET', '/api/rider/orders/$id/');

  static Future<Map<String, dynamic>> wallet() => _req('GET', '/api/rider/wallet/');

  /// status: pending / confirmed / rejected (optional filter)
  static Future<Map<String, dynamic>> handovers({String? status}) {
    final q = (status == null || status.isEmpty) ? '' : '?status=$status';
    return _req('GET', '/api/rider/cash/handovers/$q');
  }

  /// receiver: 'admin' ya 'vendor' (vendor par vendorId zaroori).
  static Future<Map<String, dynamic>> submitHandover({
    required String receiver,
    int? vendorId,
    required double amount,
    String note = '',
    List<int>? orderIds,
  }) {
    return _req('POST', '/api/rider/cash/handover/', body: {
      'receiver': receiver,
      if (vendorId != null) 'vendor_id': vendorId,
      'amount': amount,
      'note': note,
      if (orderIds != null) 'order_ids': orderIds,
    });
  }

  static Future<Map<String, dynamic>> profile() => _req('GET', '/api/rider/profile/');

  /// Naam / vehicle badlein (phone nahi badalta).
  static Future<Map<String, dynamic>> updateProfile({String? name, String? vehicle}) {
    return _req('POST', '/api/rider/profile/', body: {
      if (name != null) 'name': name,
      if (vehicle != null) 'vehicle': vehicle,
    });
  }

  /// Password badlein. Server naya token deta hai - wo yahin save ho jata hai.
  static Future<String> changePassword(String oldPassword, String newPassword) async {
    final d = await _req('POST', '/api/rider/password/',
        body: {'old_password': oldPassword, 'new_password': newPassword});
    final t = d['token'];
    if (t is String && t.isNotEmpty) {
      token = t;
      await _save();
    }
    return (d['message'] ?? 'Password badal gaya.').toString();
  }
}
