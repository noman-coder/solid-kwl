import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Build ke waqt badal sakte hain:  flutter build apk --dart-define=API_BASE=https://shop.example.com
const String kDefaultServer =
    String.fromEnvironment('API_BASE', defaultValue: 'https://YOUR-DOMAIN.com');

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, this.status);
  @override
  String toString() => message;
}

class Api {
  static String server = kDefaultServer;
  static String? token;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    server = p.getString('server') ?? kDefaultServer;
    token = p.getString('token');
  }

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('server', server);
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
      throw ApiException('Dobara login karein', 401);
    }
    if (r.statusCode >= 400 || data['ok'] == false) {
      throw ApiException((data['message'] ?? 'Error ${r.statusCode}').toString(), r.statusCode);
    }
    return data;
  }

  static Future<void> login(String serverUrl, String phone, String password) async {
    server = serverUrl.trim();
    token = null;
    final d = await _req('POST', '/api/rider/login/', body: {'phone': phone, 'password': password});
    token = d['token'] as String?;
    await _save();
  }

  static Future<void> logout() async {
    try {
      await _req('POST', '/api/rider/logout/');
    } catch (_) {}
    token = null;
    await _save();
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
}
