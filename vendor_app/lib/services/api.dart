import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/dashboard.dart';
import '../models/order_detail.dart';
import '../models/orders.dart';
import '../models/products.dart';
import '../models/stock.dart';
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

/// Multipart request jo upload ke dauran bheje gaye bytes ka haal batata hai (progress bar ke liye).
class _ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(int sent, int total)? onProgress;
  _ProgressMultipartRequest(super.method, super.url, {this.onProgress});

  @override
  http.ByteStream finalize() {
    final stream = super.finalize();
    final cb = onProgress;
    if (cb == null) return stream;
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(stream.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (data, sink) {
        sent += data.length;
        cb(sent, total);
        sink.add(data);
      },
    )));
  }
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
    return _decode(r);
  }

  /// Server ka jawab JSON mein kholo; galti ho to ApiException.
  static Map<String, dynamic> _decode(http.Response r) {
    var data = <String, dynamic>{};
    try {
      final decoded = jsonDecode(utf8.decode(r.bodyBytes));
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    if (r.statusCode >= 400 || data['ok'] == false) {
      var msg = s(data['message'] ?? data['error']);
      if (msg.isEmpty && r.statusCode == 413) {
        msg = 'Photo server ke liye bohat bari hai. Chhoti photo chunein.';
      }
      throw ApiException(
        msg.isEmpty ? 'Kuch masla aa gaya (${r.statusCode}). Dobara koshish karein.' : msg,
        r.statusCode,
        code: s(data['code']).isEmpty ? 'error' : s(data['code']),
      );
    }
    return data;
  }

  /// Photo ke saath POST (multipart). [onProgress] 0.0 - 1.0 (bheje gaye bytes). Net / time-out par 'network' error.
  static Future<Map<String, dynamic>> _multipart(String path,
      {required Map<String, dynamic> fields, required File file, void Function(double)? onProgress}) async {
    http.Response r;
    try {
      final req = _ProgressMultipartRequest('POST', _u(path), onProgress: (sent, total) {
        if (onProgress != null && total > 0) onProgress((sent / total).clamp(0.0, 1.0).toDouble());
      });
      req.headers['Accept'] = 'application/json';
      if (token != null) req.headers['Authorization'] = 'Bearer $token';
      fields.forEach((k, v) {
        if (v != null) req.fields[k] = v.toString();
      });
      req.files.add(await http.MultipartFile.fromPath('image', file.path, filename: 'photo.jpg'));
      final streamed = await req.send().timeout(const Duration(seconds: 120));
      r = await http.Response.fromStream(streamed).timeout(const Duration(seconds: 120));
    } catch (_) {
      throw ApiException('Internet ya server se rabta nahi ho raha. Photo upload nahi hui.', 0, code: 'network');
    }
    return _decode(r);
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

  // ------------------------------------------------------------------
  // Phase V6: Order detail + live track + rider dena
  // ------------------------------------------------------------------

  /// Order ka poora detail (items, customer, steps, rider, commission).
  static Future<OrderDetail> orderDetail(int id) async {
    final d = await _req('GET', '/api/vendor/orders/$id/');
    return OrderDetail.fromJson(asMap(d['order']));
  }

  /// Rider ki taza location. `active == false` ho to map nahi dikhana.
  static Future<TrackData> orderTrack(int id) async {
    final d = await _req('GET', '/api/vendor/orders/$id/track/');
    return TrackData.fromJson(d);
  }

  /// Dene layak riders (online pehle).
  static Future<RiderList> riders(int orderId) async {
    final d = await _req('GET', '/api/vendor/orders/$orderId/assign-rider/');
    return RiderList.fromJson(d);
  }

  /// Rider dena. Kamyab ho to (message, taza detail).
  static Future<({String message, OrderDetail detail})> assignRider(int orderId, int riderId) async {
    final d = await _req('POST', '/api/vendor/orders/$orderId/assign-rider/', body: {'rider_id': riderId});
    return (message: s(d['message']), detail: OrderDetail.fromJson(asMap(d['order'])));
  }

  // ------------------------------------------------------------------
  // Phase V8: Products
  // ------------------------------------------------------------------

  /// Products ka ek page. [filter]: all | approved | pending | rejected | low | out, [q]: naam / barcode.
  static Future<ProductsPage> products(String filter, {int page = 1, String q = ''}) async {
    final params = <String, String>{'page': '$page'};
    if (filter == 'approved' || filter == 'pending' || filter == 'rejected') params['status'] = filter;
    if (filter == 'low' || filter == 'out') params['stock'] = filter;
    final query = q.trim();
    if (query.isNotEmpty) params['q'] = query;
    final qs = Uri(queryParameters: params).query;
    final d = await _req('GET', '/api/vendor/products/?$qs');
    return ProductsPage.fromJson(d);
  }

  /// Product shop par dikhao / chhupao. [active] bheja ho to wahi set hota hai (double tap se ulta nahi hota).
  static Future<ProductChange> toggleProduct(int id, {bool? active}) async {
    final d = await _req('POST', '/api/vendor/products/$id/toggle/',
        body: {if (active != null) 'active': active});
    return ProductChange.fromJson(d);
  }

  /// Rate / discount / naya stock (web quick-update jaisi validation). Sirf wohi cheez bhejein jo badalni ho.
  static Future<ProductChange> quickUpdateProduct(int id,
      {double? price, double? discount, double? addStock}) async {
    final d = await _req('POST', '/api/vendor/products/quick-update/', body: {
      'items': [
        {
          'id': id,
          if (price != null) 'price': price,
          if (discount != null) 'discount': discount,
          if (addStock != null && addStock > 0) 'add': addStock,
        }
      ],
    });
    final results = listOfMaps(d['results']);
    final first = results.isEmpty ? <String, dynamic>{} : results.first;
    return ProductChange(
      s(d['message']),
      first['product'] is Map ? VendorProduct.fromJson(asMap(first['product'])) : null,
      countsFrom(d['counts']),
    );
  }

  // ------------------------------------------------------------------
  // Phase V10: Stock & inventory
  // ------------------------------------------------------------------

  /// Stock ki list. [filter]: need (kam + khatam) | low | out | all, [q]: naam / barcode.
  static Future<StockPage> stock(String filter, {int page = 1, String q = ''}) async {
    final params = <String, String>{'filter': filter, 'page': '$page'};
    final query = q.trim();
    if (query.isNotEmpty) params['q'] = query;
    final d = await _req('GET', '/api/vendor/stock/?${Uri(queryParameters: params).query}');
    return StockPage.fromJson(d);
  }

  /// Stock add / minus. [items]: {id, mode: add|minus, qty, reason, note?}. [requestKey] wahi dobara bhejein to
  /// (net toot kar retry par) stock do dafa nahi badalta.
  static Future<StockAdjustResult> adjustStock(List<Map<String, dynamic>> items, {String? requestKey}) async {
    final d = await _req('POST', '/api/vendor/stock/adjust/', body: {
      'items': items,
      if (requestKey != null) 'request_key': requestKey,
    });
    return StockAdjustResult.fromJson(d);
  }

  /// Kam stock ki hadd (is se kam ya barabar = kam, push alert bhi isi par).
  static Future<StockItem> setStockThreshold(int id, double threshold) async {
    final d = await _req('POST', '/api/vendor/stock/threshold/', body: {'id': id, 'threshold': threshold});
    return StockItem.fromJson(asMap(d['product']));
  }

  /// Stock ki tabdeeliyon ka record. [productId] na ho to poore store ka.
  static Future<StockHistoryPage> stockHistory({int? productId, int page = 1}) async {
    final params = <String, String>{'page': '$page', if (productId != null) 'product': '$productId'};
    final d = await _req('GET', '/api/vendor/stock/history/?${Uri(queryParameters: params).query}');
    return StockHistoryPage.fromJson(d);
  }

  // ------------------------------------------------------------------
  // Phase V9-A: product add / edit
  // ------------------------------------------------------------------

  /// Form ke dropdown (category / brand / unit), hadood, commission %. [productId] dein to edit ki maujooda values bhi.
  static Future<ProductFormData> productFormData({int? productId}) async {
    final d = await _req('GET', '/api/vendor/products/form-data/${productId == null ? '' : '?product=$productId'}');
    return ProductFormData.fromJson(d);
  }

  /// Naya product ([id] null) ya purana edit. [requestKey] dono mein bhejein: double tap / retry par server dobara
  /// product nahi banata / stock dobara jama nahi karta. Edit mein `stock` = naya stock jo jama karna hai.
  ///
  /// Phase V9-B: [photo] dein (compressed JPEG) to multipart mein `image` ke saath jata hai aur [onProgress]
  /// (0.0 - 1.0) upload ka haal batata hai. Photo na ho to purana JSON tareeqa.
  static Future<ProductSaveResult> saveProduct({
    int? id,
    required Map<String, dynamic> fields,
    String? requestKey,
    File? photo,
    void Function(double)? onProgress,
  }) async {
    final body = <String, dynamic>{...fields, if (requestKey != null) 'request_key': requestKey};
    final path = id == null ? '/api/vendor/products/' : '/api/vendor/products/$id/';
    final d = photo == null
        ? await _req('POST', path, body: body)
        : await _multipart(path, fields: body, file: photo, onProgress: onProgress);
    return ProductSaveResult.fromJson(d);
  }

  /// "+" button: naya category / brand / unit ([kind]: category | brand | unit). Wohi naam ho to wohi wapas.
  static Future<NamedItem> createMaster(String kind, String name) async {
    final d = await _req('POST', '/api/vendor/masters/$kind/', body: {'name': name});
    return NamedItem(toI(d['id']), s(d['name']));
  }

  /// Push notification token (FCM) server par register karo (app side Phase V7 mein use hoga).
  static Future<void> registerPushToken(String pushToken) async {
    await _req('POST', '/api/vendor/push-token/', body: {'token': pushToken, 'platform': 'android'});
  }
}
