import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/coupons.dart';
import '../models/reviews.dart';
import '../models/offers.dart';
import '../models/dashboard.dart';
import '../models/order_detail.dart';
import '../models/orders.dart';
import '../models/products.dart';
import '../models/rider_cash.dart';
import '../models/sales.dart';
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

  /// Form ki saari ghaltiyan (server `errors` bheje to; warna khali). `message` mein pehli hoti hai.
  final List<String> errors;

  ApiException(this.message, this.status, {this.code = 'error', this.errors = const []});

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
  static const String _salesKeyPrefix = 'vendor_sales_cache_';
  static const String _couponsKey = 'vendor_coupons_cache';
  static const String _offersKey = 'vendor_offers_cache';
  static const String _reviewsKey = 'vendor_reviews_cache';

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

  /// Timeout ya net toot'ne par GET ek dafa khud dobara try hota hai (sust / VPN wale net par aksar dusri koshish chal jati hai).
  /// POST kabhi khud dobara nahi bheja jata (double action na ho).
  static Future<Map<String, dynamic>> _req(String method, String path,
      {Map<String, dynamic>? body}) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final attempts = method == 'GET' ? 2 : 1;
    var timedOut = false;
    for (var i = 0; i < attempts; i++) {
      try {
        http.Response r;
        if (method == 'GET') {
          r = await http.get(_u(path), headers: headers).timeout(const Duration(seconds: 20));
        } else {
          r = await http
              .post(_u(path), headers: headers, body: jsonEncode(body ?? <String, dynamic>{}))
              .timeout(const Duration(seconds: 20));
        }
        return _decode(r);
      } on ApiException {
        rethrow; // server ne jawab de diya (ghalat password, 404 ...) - dobara bhejne ka faida nahi
      } on TimeoutException {
        timedOut = true;
      } catch (_) {
        timedOut = false;
      }
    }
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
      var msg = s(data['message'] ?? data['error']);
      if (msg.isEmpty && r.statusCode == 413) {
        msg = 'Photo server ke liye bohat bari hai. Chhoti photo chunein.';
      }
      throw ApiException(
        msg.isEmpty ? 'Kuch masla aa gaya (${r.statusCode}). Dobara koshish karein.' : msg,
        r.statusCode,
        code: s(data['code']).isEmpty ? 'error' : s(data['code']),
        errors: data['errors'] is List
            ? (data['errors'] as List).map((e) => s(e)).where((e) => e.isNotEmpty).toList()
            : const [],
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
      await p.remove(_couponsKey); // Phase V13: coupons ki purani list bhi
      await p.remove(_offersKey); // Phase V13-B: offers ki purani list bhi
      await p.remove(_reviewsKey); // Phase V14: reviews ki purani list bhi
      for (final k in kSalesPeriods) {
        await p.remove('$_salesKeyPrefix$k'); // Phase V11: sales ka purana data bhi (doosra vendor login kare to)
      }
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
  // Phase V11: Sales, cash & profit
  // ------------------------------------------------------------------

  static String _q(Map<String, String> params) => Uri(queryParameters: params).query;

  /// Sales summary. Kamyab jawab (custom ke ilawa) phone mein save hota hai - net na ho to purana data dikhane ke liye.
  static Future<SalesData> sales(SalesRange r) async {
    final d = await _req('GET', '/api/vendor/sales/?${_q(r.params)}');
    final data = SalesData.fromJson(d);
    if (!r.isCustom) {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString('$_salesKeyPrefix${r.period}', jsonEncode(d));
      } catch (_) {}
    }
    return data;
  }

  /// Phone mein save kiya hua aakhri sales data (na ho / kharab ho / custom ho to null).
  static Future<SalesData?> cachedSales(SalesRange r) async {
    if (r.isCustom) return null;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('$_salesKeyPrefix${r.period}');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? SalesData.fromJson(Map<String, dynamic>.from(decoded)) : null;
    } catch (_) {
      return null;
    }
  }

  /// Din wise kamayi (sirf mukammal orders).
  static Future<StatementData> salesStatement(SalesRange r) async {
    final d = await _req('GET', '/api/vendor/sales/statement/?${_q(r.params)}');
    return StatementData.fromJson(d);
  }

  /// Sales ke number par tap: us hisaab ke orders. [group]: sales | all | done | open | cancelled,
  /// [day]: YYYY-MM-DD, [payment]: cod | online.
  static Future<OrdersPage> salesOrders(SalesRange r,
      {String group = 'sales', String? day, String? payment, int page = 1}) async {
    final params = <String, String>{
      ...r.params,
      'group': group,
      'page': '$page',
      if (day != null && day.isNotEmpty) 'day': day,
      if (payment != null && payment.isNotEmpty) 'payment': payment,
    };
    final d = await _req('GET', '/api/vendor/sales/orders/?${_q(params)}');
    return OrdersPage.fromJson(d);
  }

  /// Sales report file (CSV / PDF) - share sheet ke liye.
  static Future<ExportFile> salesExport(SalesRange r, {String format = 'csv'}) async {
    final fmt = format == 'pdf' ? 'pdf' : 'csv';
    final headers = <String, String>{
      'Accept': '*/*',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    http.Response resp;
    try {
      resp = await http
          .get(_u('/api/vendor/sales/export/?${_q({...r.params, 'format': fmt})}'), headers: headers)
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      throw ApiException('Internet ya server se rabta nahi ho raha', 0, code: 'network');
    }
    if (resp.statusCode >= 400) {
      _decode(resp); // ApiException phenkta hai
      throw ApiException('Report nahi ban saki (${resp.statusCode}). Dobara koshish karein.', resp.statusCode);
    }
    var name = 'sales.$fmt';
    final cd = resp.headers['content-disposition'] ?? '';
    final m = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
    if (m != null && m.group(1)!.trim().isNotEmpty) name = m.group(1)!.trim();
    return ExportFile(resp.bodyBytes, name, fmt == 'pdf' ? 'application/pdf' : 'text/csv');
  }

  // ------------------------------------------------------------------
  // Phase V12: Rider cash handover
  // ------------------------------------------------------------------

  /// Pending (sirf page 1 par) + history + jod. Sirf is vendor ke handovers.
  static Future<CashPage> riderCash({int page = 1}) async {
    final d = await _req('GET', '/api/vendor/rider-cash/?page=$page');
    return CashPage.fromJson(d);
  }

  /// [action]: confirm | reject. [amount]: jo raqam vendor ne screen par dekhi (badal gayi ho to server rok deta hai).
  /// Reject par [reason] zaroori.
  static Future<CashActionResult> riderCashAction(int id, String action, {double? amount, String? reason}) async {
    final d = await _req('POST', '/api/vendor/rider-cash/$id/$action/', body: {
      if (amount != null) 'amount': amount,
      if (reason != null) 'reason': reason,
    });
    return CashActionResult.fromJson(d);
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

  // ------------------------------------------------------------------
  // Phase V13: coupons
  // ------------------------------------------------------------------

  /// Mere saare coupons (+ ginti). Kamyab list phone mein bhi save hoti hai (net na ho to purani dikhane ke liye).
  static Future<CouponsPage> coupons() async {
    final d = await _req('GET', '/api/vendor/coupons/');
    final page = CouponsPage.fromJson(d);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_couponsKey, jsonEncode(d));
    } catch (_) {}
    return page;
  }

  /// Phone mein save ki hui aakhri coupons list (na ho ya kharab ho to null).
  static Future<CouponsPage?> cachedCoupons() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_couponsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? CouponsPage.fromJson(Map<String, dynamic>.from(decoded)) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _cacheCouponsFrom(Map<String, dynamic> d) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_couponsKey, jsonEncode({'summary': d['summary'], 'coupons': d['coupons']}));
    } catch (_) {}
  }

  /// Naya coupon ([id] null) ya purana edit. [requestKey]: double tap / retry par dobara coupon na bane.
  static Future<CouponActionResult> saveCoupon({
    int? id,
    required Map<String, dynamic> fields,
    String? requestKey,
  }) async {
    final body = <String, dynamic>{...fields, if (id == null && requestKey != null) 'request_key': requestKey};
    final d = await _req('POST', id == null ? '/api/vendor/coupons/' : '/api/vendor/coupons/$id/', body: body);
    await _cacheCouponsFrom(d);
    return CouponActionResult.fromJson(d);
  }

  /// Chalu / band (seedha value bhejte hain, retry par ulta nahi hota).
  static Future<CouponActionResult> setCouponActive(int id, bool active) async {
    final d = await _req('POST', '/api/vendor/coupons/$id/toggle/', body: {'active': active});
    await _cacheCouponsFrom(d);
    return CouponActionResult.fromJson(d);
  }

  /// Delete. Istemal ho chuka coupon delete nahi hota, sirf band hota hai (`deleted == false`).
  static Future<CouponActionResult> deleteCoupon(int id) async {
    final d = await _req('POST', '/api/vendor/coupons/$id/delete/');
    await _cacheCouponsFrom(d);
    return CouponActionResult.fromJson(d);
  }

  // ------------------------------------------------------------------
  // Phase V13-B: offers
  // ------------------------------------------------------------------

  /// Mere saare offers (+ ginti). Kamyab list phone mein bhi save hoti hai (net na ho to purani dikhane ke liye).
  static Future<OffersPage> offers() async {
    final d = await _req('GET', '/api/vendor/offers/');
    final page = OffersPage.fromJson(d);
    await _cacheOffersFrom(d);
    return page;
  }

  /// Phone mein save ki hui aakhri offers list (na ho ya kharab ho to null).
  static Future<OffersPage?> cachedOffers() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_offersKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? OffersPage.fromJson(Map<String, dynamic>.from(decoded)) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _cacheOffersFrom(Map<String, dynamic> d) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_offersKey, jsonEncode({'summary': d['summary'], 'offers': d['offers'], 'limits': d['limits']}));
    } catch (_) {}
  }

  /// Offer ke liye products (sirf approved + chalu); [q] naam / barcode.
  static Future<List<OfferPick>> offerProducts({String q = ''}) async {
    final d = await _req('GET', '/api/vendor/offers/products/${q.trim().isEmpty ? '' : '?q=${Uri.encodeQueryComponent(q.trim())}'}');
    return listOfMaps(d['products']).map(OfferPick.fromJson).toList();
  }

  /// Naya offer ([id] null) ya purana edit. [requestKey]: double tap / retry par dobara offer na bane.
  static Future<OfferActionResult> saveOffer({
    int? id,
    required Map<String, dynamic> fields,
    String? requestKey,
  }) async {
    final body = <String, dynamic>{...fields, if (id == null && requestKey != null) 'request_key': requestKey};
    final d = await _req('POST', id == null ? '/api/vendor/offers/' : '/api/vendor/offers/$id/', body: body);
    await _cacheOffersFrom(d);
    return OfferActionResult.fromJson(d);
  }

  /// Chalu / band (seedha value bhejte hain, retry par ulta nahi hota).
  static Future<OfferActionResult> setOfferActive(int id, bool active) async {
    final d = await _req('POST', '/api/vendor/offers/$id/toggle/', body: {'active': active});
    await _cacheOffersFrom(d);
    return OfferActionResult.fromJson(d);
  }

  static Future<OfferActionResult> deleteOffer(int id) async {
    final d = await _req('POST', '/api/vendor/offers/$id/delete/');
    await _cacheOffersFrom(d);
    return OfferActionResult.fromJson(d);
  }

  // ------------------------------------------------------------------
  // Phase V14: reviews & ratings
  // ------------------------------------------------------------------

  /// Reviews ka ek page. [filter]: all | unanswered | replied. [stars]: 0 = sab, 1-5 = sirf itne star.
  /// Sirf "sab, page 1" kamyab ho to phone mein bhi save hota hai (net na ho to purani list dikhane ke liye).
  static Future<ReviewsPage> reviews({String filter = 'all', int stars = 0, int page = 1}) async {
    final q = <String>['filter=$filter', if (stars > 0) 'stars=$stars', 'page=$page'].join('&');
    final d = await _req('GET', '/api/vendor/reviews/?$q');
    final out = ReviewsPage.fromJson(d);
    if (filter == 'all' && stars == 0 && page == 1) {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(_reviewsKey, jsonEncode(d));
      } catch (_) {}
    }
    return out;
  }

  /// Phone mein save kiya hua aakhri (sab, page 1) reviews page (na ho ya kharab ho to null).
  static Future<ReviewsPage?> cachedReviews() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_reviewsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? ReviewsPage.fromJson(Map<String, dynamic>.from(decoded)) : null;
    } catch (_) {
      return null;
    }
  }

  /// Jawab dein / badlein. [reply] khali = jawab hata dein. Zyada se zyada 300 akshar (server rokta hai).
  static Future<ReviewReplyResult> replyReview(int id, String reply) async {
    final d = await _req('POST', '/api/vendor/reviews/$id/reply/', body: {'reply': reply});
    return ReviewReplyResult.fromJson(d);
  }

  /// Push notification token (FCM) server par register karo (app side Phase V7 mein use hoga).
  static Future<void> registerPushToken(String pushToken) async {
    await _req('POST', '/api/vendor/push-token/', body: {'token': pushToken, 'platform': 'android'});
  }
}
