import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/dashboard.dart';
import '../models/orders.dart';
import '../models/products.dart';
import '../models/vendor.dart';
import 'api.dart';
import 'push.dart';

/// Chhota message (toast).
class AppEvent {
  final String message;
  const AppEvent(this.message);
}

/// Orders ki ek tab (Naye / Chal rahe / Mukammal) ki list aur uski haalat.
class OrderList {
  List<VendorOrder> orders = [];
  int page = 0; // aakhri load hua page
  bool hasMore = false;
  bool loaded = false; // kam az kam ek dafa kamyab load hua
  bool stale = false; // dobara load karni hai (action / naye order ke baad)
  bool loading = false; // pehla page load ho raha hai
  bool loadingMore = false; // agla page load ho raha hai
  String? error; // aakhri koshish nakam hui (internet / server)
  int seq = 0; // sirf sab se nayi request apply hoti hai
}

/// Products ki list (ek filter chip ki) aur uski haalat.
class ProductList {
  List<VendorProduct> products = [];
  int page = 0;
  bool hasMore = false;
  bool loaded = false;
  bool stale = false;
  bool loading = false;
  bool loadingMore = false;
  String? error;
  int seq = 0;
}

/// Poore app ka shared hissa: vendor ka profile / approval status, tab navigation aur dashboard.
/// Saare tabs isi ko dekhte hain (AppScope.of(context)). Aglay phases mein orders, products wagairah yahin judenge.
class AppState extends ChangeNotifier {
  AppState({required this.onLogout});

  /// Session khatam (token ghalat/expire) ya logout par call hota hai.
  final Future<void> Function() onLogout;

  bool _disposed = false;
  int _seq = 0; // sirf sab se naya refresh apply hota hai

  Vendor? vendor;
  String? pendingMessage; // approval baqi ho to server ka message
  bool loading = true;
  String? error; // internet / server ka masla
  int tab = 0; // 0 Dashboard, 1 Orders, 2 Products, 3 Sales, 4 More

  // ---- Phase V4: Dashboard
  DashboardData? dashboard;
  bool dashLoading = false; // pehli dafa (data na ho tab) load ho raha hai
  String? dashError; // aakhri koshish nakam hui (internet / server)
  bool storeSwitching = false; // Open/Closed switch ka double-tap lock
  int _dashSeq = 0;

  // ---- Phase V5: Orders
  static const List<RejectReason> _defaultReasons = [
    RejectReason('out_of_stock', 'Item abhi stock mein nahi'),
    RejectReason('store_busy', 'Store abhi bohat busy hai'),
    RejectReason('store_closed', 'Store band ho raha hai'),
    RejectReason('out_of_area', 'Aap ke area mein delivery nahi'),
    RejectReason('price_issue', 'Item ki price/detail mein ghalti'),
    RejectReason('other', 'Doosri wajah'),
  ];
  static const Duration _pollEvery = Duration(seconds: 25);

  final Map<String, OrderList> _orderLists = {for (final t in kOrderTabs) t: OrderList()};
  Map<String, int>? orderCounts; // server se aakhri ginti (Naye / Chal rahe / Mukammal)
  String ordersQuery = ''; // search (order no / customer)
  String activeOrderTab = 'new'; // screen par abhi kaun si tab khuli hai
  List<RejectReason> rejectReasons = _defaultReasons;
  List<int> prepOptions = const [10, 20, 30, 45];
  final Set<int> orderBusy = <int>{}; // jin orders par action chal raha hai (double-tap lock)
  Timer? _pollTimer;
  bool _polling = false;
  int _lastLatestId = -1; // -1 = abhi baseline nahi bana
  int _alertedId = 0; // sab se naya order jis ki awaaz / banner ho chuka (push + poll dono ek hi baar bajayen)

  // ---- Phase V8: Products
  final Map<String, ProductList> _productLists = {for (final f in kProductFilters) f: ProductList()};
  Map<String, int>? productCounts; // chips ke badge (server se)
  String productsQuery = ''; // search (naam / barcode)
  String productFilter = 'all'; // abhi kaun sa chip chuna hai
  final Set<int> productBusy = <int>{}; // jin products par toggle / update chal raha hai (double-tap lock)

  final StreamController<AppEvent> _events = StreamController<AppEvent>.broadcast();
  Stream<AppEvent> get events => _events.stream;

  void toast(String msg) {
    if (!_disposed && !_events.isClosed) _events.add(AppEvent(msg));
  }

  bool get approved => vendor?.approved == true;

  /// Naye (jawab ke muntazir) orders - Orders tab ke badge ke liye.
  int get newOrders => orderCounts?['new'] ?? dashboard?.newOrders ?? 0;

  /// Dashboard purana hai (taza load nakam hua, par purana data maujood hai).
  bool get dashStale => dashboard != null && dashError != null;

  void goTab(int i) {
    tab = i;
    notifyListeners();
  }

  /// Login ke foran baad: login se mila vendor seedha set karo (dobara net call ki zaroorat nahi).
  void seed(LoginResult r) {
    vendor = r.vendor;
    pendingMessage = r.message;
    loading = false;
    error = null;
  }

  Future<void> start() async {
    if (vendor == null) await refresh();
    if (!approved) return;
    // Pehle phone mein save kiya hua dashboard (turant), phir taza (net se)
    if (dashboard == null) {
      final cached = await Api.cachedDashboard();
      final cv = cached?.vendor;
      if (!_disposed && cached != null && dashboard == null && cv != null && cv.id == vendor?.id) {
        dashboard = cached;
        notifyListeners();
      }
    }
    await loadDashboard();
    startPolling();
  }

  /// Pull-to-refresh / app resume: profile + dashboard + orders.
  Future<void> refreshAll() async {
    await Future.wait([refresh(), loadDashboard(), refreshOrders(), if (productList(productFilter).loaded) refreshProducts()]);
  }

  /// Dashboard dobara lo. Net na ho to purana data rehta hai aur `dashError` set hota hai.
  Future<void> loadDashboard() async {
    if (!approved) return;
    final seq = ++_dashSeq;
    if (dashboard == null) {
      dashLoading = true;
      notifyListeners();
    }
    try {
      final d = await Api.dashboard();
      if (_disposed || seq != _dashSeq) return;
      dashboard = d;
      dashError = null;
      if (d.vendor != null) vendor = d.vendor; // store status / rating taza
    } on ApiException catch (e) {
      if (_disposed || seq != _dashSeq) return;
      if (e.authExpired) {
        await _sessionExpired();
        return;
      }
      if (e.pending) {
        dashLoading = false;
        await refresh(); // approval hat gayi: pending screen dikhegi
        return;
      }
      dashError = e.message;
    }
    dashLoading = false;
    notifyListeners();
  }

  /// Store Open / Closed switch. Kamyab ho to foran naya status dikhta hai, phir warnings taza hoti hain.
  Future<void> setStoreOpen(bool open) async {
    if (storeSwitching) return;
    storeSwitching = true;
    notifyListeners();
    try {
      final r = await Api.setStoreOpen(open);
      if (_disposed) return;
      final cur = dashboard;
      if (cur != null) dashboard = cur.withStore(r.store, r.vendor);
      if (r.vendor != null) vendor = r.vendor;
      if (r.message.isNotEmpty) toast(r.message);
    } on ApiException catch (e) {
      if (_disposed) return;
      if (e.authExpired) {
        storeSwitching = false;
        await _sessionExpired();
        return;
      }
      toast(e.message);
    }
    storeSwitching = false;
    notifyListeners();
    loadDashboard(); // store band/khula hone se warnings badalti hain
  }

  // ------------------------------------------------------------------
  // Phase V5: Orders
  // ------------------------------------------------------------------

  OrderList orderList(String tab) => _orderLists[tab] ?? _orderLists['new']!;

  void _applyOrdersMeta(OrdersPage p) {
    orderCounts = p.counts;
    if (p.rejectReasons.isNotEmpty) rejectReasons = p.rejectReasons;
    if (p.prepOptions.isNotEmpty) prepOptions = p.prepOptions;
  }

  /// Tab pehli dafa khuli ho ya purani (stale) ho to load karo.
  void ensureOrders(String tab) {
    final l = orderList(tab);
    if ((!l.loaded || l.stale) && !l.loading) loadOrders(tab);
  }

  /// Tab ka pehla page (naya) lo. Net na ho to purani list rehti hai aur `error` set hota hai.
  Future<void> loadOrders(String tab) async {
    if (!approved) return;
    final l = orderList(tab);
    final seq = ++l.seq;
    l.stale = false;
    l.loadingMore = false;
    if (!l.loaded) {
      l.loading = true;
      notifyListeners();
    }
    try {
      final p = await Api.orders(tab, q: ordersQuery);
      if (_disposed || seq != l.seq) return;
      l.orders = p.orders;
      l.page = p.page;
      l.hasMore = p.hasMore;
      l.loaded = true;
      l.error = null;
      _applyOrdersMeta(p);
    } on ApiException catch (e) {
      if (_disposed || seq != l.seq) return;
      if (e.authExpired) {
        l.loading = false;
        await _sessionExpired();
        return;
      }
      if (e.pending) {
        l.loading = false;
        await refresh();
        return;
      }
      l.error = e.message;
    }
    l.loading = false;
    notifyListeners();
  }

  /// Agla page (neeche scroll karne par).
  Future<void> loadMoreOrders(String tab) async {
    final l = orderList(tab);
    if (!approved || !l.loaded || !l.hasMore || l.loading || l.loadingMore) return;
    final seq = l.seq;
    l.loadingMore = true;
    notifyListeners();
    try {
      final p = await Api.orders(tab, page: l.page + 1, q: ordersQuery);
      if (_disposed || seq != l.seq) return;
      final seen = l.orders.map((o) => o.id).toSet();
      l.orders = [...l.orders, ...p.orders.where((o) => !seen.contains(o.id))];
      l.page = p.page;
      l.hasMore = p.hasMore;
      _applyOrdersMeta(p);
    } on ApiException catch (e) {
      if (_disposed || seq != l.seq) return;
      if (e.authExpired) {
        l.loadingMore = false;
        await _sessionExpired();
        return;
      }
      toast(e.message);
    }
    l.loadingMore = false;
    notifyListeners();
  }

  /// Search badli: saari tabs purani ho gayin, khuli hui tab foran dobara load hoti hai.
  Future<void> setOrdersQuery(String q) async {
    final nq = q.trim();
    if (nq == ordersQuery) return;
    ordersQuery = nq;
    for (final t in kOrderTabs) {
      final l = orderList(t);
      l.seq++; // chalti request ka jawab ignore
      l.loading = false;
      l.loaded = false;
      l.stale = true;
      l.loadingMore = false;
    }
    await loadOrders(activeOrderTab);
  }

  /// Pull-to-refresh / naya order / app resume: khuli hui tab taza, baqi tabs agli dafa khulne par taza.
  Future<void> refreshOrders() async {
    if (!approved) return;
    for (final t in kOrderTabs) {
      if (t != activeOrderTab && orderList(t).loaded) orderList(t).stale = true;
    }
    await loadOrders(activeOrderTab);
  }

  /// accept | reject | ready | delivered. Kamyab ho to order ki nayi tab ka naam milta hai (screen wahan chali jaye),
  /// warna null. Jab tak action chal raha ho dobara tap kuch nahi karta (double-tap lock).
  Future<String?> orderAction(
    VendorOrder o,
    String action, {
    int? prepMinutes,
    String? reasonCode,
    String? reasonNote,
  }) async {
    if (orderBusy.contains(o.id)) return null;
    orderBusy.add(o.id);
    notifyListeners();
    String? next;
    var recheck = false;
    try {
      final r = await Api.orderAction(o.id, action,
          prepMinutes: prepMinutes, reasonCode: reasonCode, reasonNote: reasonNote);
      if (_disposed) return null;
      final src = orderList(o.tab);
      final idx = src.orders.indexWhere((e) => e.id == o.id);
      final nextTab = kOrderTabs.contains(r.nextTab) ? r.nextTab : o.tab;
      if (nextTab == o.tab) {
        if (idx >= 0 && r.order != null) src.orders[idx] = r.order!;
      } else {
        if (idx >= 0) src.orders.removeAt(idx);
        orderList(nextTab).stale = true;
      }
      orderCounts = r.counts;
      if (r.message.isNotEmpty) toast(r.message);
      next = nextTab;
    } on ApiException catch (e) {
      if (_disposed) return null;
      if (e.authExpired) {
        orderBusy.remove(o.id);
        await _sessionExpired();
        return null;
      }
      if (e.pending) {
        orderBusy.remove(o.id);
        await refresh();
        return null;
      }
      toast(e.message);
      // Kisi aur phone / web se status badal chuka ho sakta hai: list taza karo
      recheck = e.code == 'conflict' || e.code == 'not_found';
    }
    orderBusy.remove(o.id);
    notifyListeners();
    if (next != null) loadDashboard(); // dashboard ke numbers badal gaye
    if (recheck) loadOrders(o.tab);
    return next;
  }

  // ------------------------------------------------------------------
  // Phase V8: Products
  // ------------------------------------------------------------------

  ProductList productList(String filter) => _productLists[filter] ?? _productLists['all']!;

  /// Chip pehli dafa khuli ho ya purani (stale) ho to load karo.
  void ensureProducts([String? filter]) {
    final l = productList(filter ?? productFilter);
    if ((!l.loaded || l.stale) && !l.loading) loadProducts(filter ?? productFilter);
  }

  /// Chip badlo (list turant, load ho chuki ho to).
  void setProductFilter(String f) {
    if (!kProductFilters.contains(f) || f == productFilter) return;
    productFilter = f;
    notifyListeners();
    ensureProducts(f);
  }

  /// Chip ka pehla page. Net na ho to purani list rehti hai aur `error` set hota hai.
  Future<void> loadProducts([String? filter]) async {
    if (!approved) return;
    final f = filter ?? productFilter;
    final l = productList(f);
    final seq = ++l.seq;
    l.stale = false;
    l.loadingMore = false;
    if (!l.loaded) {
      l.loading = true;
      notifyListeners();
    }
    try {
      final p = await Api.products(f, q: productsQuery);
      if (_disposed || seq != l.seq) return;
      l.products = p.products;
      l.page = p.page;
      l.hasMore = p.hasMore;
      l.loaded = true;
      l.error = null;
      productCounts = p.counts;
    } on ApiException catch (e) {
      if (_disposed || seq != l.seq) return;
      if (e.authExpired) {
        l.loading = false;
        await _sessionExpired();
        return;
      }
      if (e.pending) {
        l.loading = false;
        await refresh();
        return;
      }
      l.error = e.message;
    }
    l.loading = false;
    notifyListeners();
  }

  Future<void> loadMoreProducts([String? filter]) async {
    final f = filter ?? productFilter;
    final l = productList(f);
    if (!approved || !l.loaded || !l.hasMore || l.loading || l.loadingMore) return;
    final seq = l.seq;
    l.loadingMore = true;
    notifyListeners();
    try {
      final p = await Api.products(f, page: l.page + 1, q: productsQuery);
      if (_disposed || seq != l.seq) return;
      final seen = l.products.map((e) => e.id).toSet();
      l.products = [...l.products, ...p.products.where((e) => !seen.contains(e.id))];
      l.page = p.page;
      l.hasMore = p.hasMore;
      productCounts = p.counts;
    } on ApiException catch (e) {
      if (_disposed || seq != l.seq) return;
      if (e.authExpired) {
        l.loadingMore = false;
        await _sessionExpired();
        return;
      }
      toast(e.message);
    }
    l.loadingMore = false;
    notifyListeners();
  }

  /// Search badli: saare chips purane ho gaye, khula hua chip foran dobara load hota hai.
  Future<void> setProductsQuery(String q) async {
    final nq = q.trim();
    if (nq == productsQuery) return;
    productsQuery = nq;
    for (final f in kProductFilters) {
      final l = productList(f);
      l.seq++;
      l.loading = false;
      l.loaded = false;
      l.stale = true;
      l.loadingMore = false;
    }
    await loadProducts(productFilter);
  }

  /// Phase V10: Stock screen se stock badla - Products ki lists aur dashboard (kam stock ginti) purane ho gaye.
  void stockChanged() {
    for (final f in kProductFilters) {
      if (productList(f).loaded) productList(f).stale = true;
    }
    notifyListeners();
    if (approved) loadDashboard();
  }

  /// Phase V10: Stock screen ko token expire hone par session band karne ke liye.
  Future<void> handleAuthExpired() => _sessionExpired();

  /// Pull-to-refresh / app resume: khula chip taza, baqi agli dafa khulne par.
  Future<void> refreshProducts() async {
    if (!approved) return;
    for (final f in kProductFilters) {
      if (f != productFilter && productList(f).loaded) productList(f).stale = true;
    }
    await loadProducts(productFilter);
  }

  /// Ek product ka taza roop saari lists mein badlo (chip ke hisaab se jo ab us list mein nahi banta use hatao).
  void _applyProduct(VendorProduct p) {
    for (final f in kProductFilters) {
      final l = productList(f);
      final i = l.products.indexWhere((e) => e.id == p.id);
      if (i < 0) continue;
      final stillHere = switch (f) {
        'approved' => p.isApproved,
        'pending' => p.isPending,
        'rejected' => p.isRejected,
        'low' => p.isApproved && p.stockState == 'low',
        'out' => p.isApproved && p.stockState == 'out',
        _ => true,
      };
      if (stillHere) {
        l.products[i] = p;
      } else {
        l.products.removeAt(i);
      }
    }
  }

  /// Shop par show/hide. Kamyab ho to true. Jab tak chal raha ho dobara tap kuch nahi karta.
  Future<bool> toggleProduct(VendorProduct p, {required bool active}) async {
    if (productBusy.contains(p.id)) return false;
    productBusy.add(p.id);
    notifyListeners();
    var ok = false;
    try {
      final r = await Api.toggleProduct(p.id, active: active);
      if (_disposed) return false;
      if (r.product != null) _applyProduct(r.product!);
      productCounts = r.counts;
      if (r.message.isNotEmpty) toast(r.message);
      ok = true;
    } on ApiException catch (e) {
      if (_disposed) return false;
      if (e.authExpired) {
        productBusy.remove(p.id);
        await _sessionExpired();
        return false;
      }
      if (e.pending) {
        productBusy.remove(p.id);
        await refresh();
        return false;
      }
      toast(e.message);
      if (e.code == 'not_approved' || e.code == 'not_found') productList(productFilter).stale = true;
    }
    productBusy.remove(p.id);
    notifyListeners();
    if (ok) loadDashboard(); // dashboard ke numbers
    if (productList(productFilter).stale) loadProducts();
    return ok;
  }

  /// Rate / discount / naya stock. Kamyab ho to null, warna server ka saaf message (sheet mein dikhane ke liye).
  Future<String?> quickUpdateProduct(VendorProduct p, {double? price, double? discount, double? addStock}) async {
    if (productBusy.contains(p.id)) return 'Update chal raha hai, zara ruken.';
    productBusy.add(p.id);
    notifyListeners();
    String? err;
    var changed = false;
    try {
      final r = await Api.quickUpdateProduct(p.id, price: price, discount: discount, addStock: addStock);
      if (_disposed) return null;
      if (r.product != null) _applyProduct(r.product!);
      productCounts = r.counts;
      if (r.message.isNotEmpty) toast(r.message);
      changed = true;
    } on ApiException catch (e) {
      if (_disposed) return null;
      if (e.authExpired) {
        productBusy.remove(p.id);
        await _sessionExpired();
        return null;
      }
      if (e.pending) {
        productBusy.remove(p.id);
        await refresh();
        return null;
      }
      err = e.message;
    }
    productBusy.remove(p.id);
    notifyListeners();
    if (changed) loadDashboard(); // stock / low-stock ginti badal sakti hai
    return err;
  }

  /// Product add ([id] null) ya edit. Kamyab ho to result, warna server ka saaf message (form mein dikhane ke liye).
  /// Session khatam / approval hat gayi ho to yahin sambhal leta hai (dono null).
  Future<({ProductSaveResult? result, String? error})> saveProduct({
    int? id,
    required Map<String, dynamic> fields,
    String? requestKey,
    File? photo,
    void Function(double)? onProgress,
  }) async {
    try {
      final r = await Api.saveProduct(
          id: id, fields: fields, requestKey: requestKey, photo: photo, onProgress: onProgress);
      if (_disposed) return (result: null, error: null);
      if (id != null && r.product != null) _applyProduct(r.product!);
      productCounts = r.counts;
      if (id == null || r.product == null) {
        // naya product kisi list mein nahi hai: sab lists purani, abhi wali dobara load
        for (final f in kProductFilters) {
          if (f != productFilter && productList(f).loaded) productList(f).stale = true;
        }
        loadProducts(productFilter);
      }
      notifyListeners();
      loadDashboard(); // products / pending ginti
      return (result: r, error: null);
    } on ApiException catch (e) {
      if (_disposed) return (result: null, error: null);
      if (e.authExpired) {
        await _sessionExpired();
        return (result: null, error: null);
      }
      if (e.pending) {
        await refresh();
        return (result: null, error: null);
      }
      return (result: null, error: e.message);
    }
  }

  /// Detail screen jaisi jagah se aaya ApiException: session khatam / approval hat gayi ho to yahin sambhal lo
  /// (true = sambhal liya, screen kuch na kare). Warna false - screen apna message dikhaye.
  Future<bool> handleApiError(ApiException e) async {
    if (_disposed) return true;
    if (e.authExpired) {
      await _sessionExpired();
      return true;
    }
    if (e.pending) {
      await refresh();
      return true;
    }
    return false;
  }

  /// Order detail se (rider diya, status badla) lautne par: sab tabs aur dashboard taza.
  void ordersChanged() {
    if (_disposed) return;
    for (final t in kOrderTabs) {
      orderList(t).stale = true;
    }
    refreshOrders();
    loadDashboard();
  }

  /// Orders ka halka poll shuru (app khuli ho tab har 25 sec). Pehla poll sirf baseline banata hai.
  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_disposed || !approved) return;
    _pollTimer = Timer.periodic(_pollEvery, (_) => pollOrders());
    pollOrders();
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> pollOrders() async {
    if (_polling || _disposed || !approved) return;
    _polling = true;
    try {
      final p = await Api.ordersPoll();
      if (_disposed) return;
      final baseline = _lastLatestId < 0;
      final hasNewer = !baseline && p.latestId > _lastLatestId;
      final c = orderCounts;
      final countChanged = c != null && c['new'] != p.newCount;
      _lastLatestId = p.latestId;
      if (hasNewer && p.latestId > _alertedId) {
        _alertedId = p.latestId; // push pehle bata chuki ho to dobara awaaz nahi
        _alertNewOrder();
      }
      if (hasNewer || countChanged) {
        refreshOrders();
        loadDashboard();
      }
    } on ApiException catch (e) {
      if (_disposed) return;
      if (e.authExpired) {
        await _sessionExpired();
      } else if (e.pending) {
        await refresh();
      }
      // net ka masla: khamoshi, agli baar dobara poochenge
    } finally {
      _polling = false;
    }
  }

  // ------------------------------------------------------------------
  // Phase V7: Push (app khuli ho tab)
  // ------------------------------------------------------------------

  /// Push se naya order aaya (app khuli hai). true = pehli dafa: banner + awaaz dikhao.
  /// false = ye order poll pehle hi bata chuka hai (dobara awaaz nahi).
  bool claimOrderAlert(int orderId) {
    if (orderId <= _alertedId) return false;
    _alertedId = orderId;
    return true;
  }

  /// Koi bhi push khuli app mein aayi: orders + dashboard (ginti, badge, alerts) foran taza.
  void onPushArrived() {
    if (_disposed || !approved) return;
    refreshOrders();
    loadDashboard();
    pollOrders(); // baseline / badge sahi rahe
  }

  void _alertNewOrder() {
    toast('Naya order aaya hai!');
    try {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
    } catch (_) {}
  }

  Future<void> _sessionExpired() async {
    await Api.clearToken();
    toast('Dobara login karein');
    await onLogout();
  }

  /// Profile dobara lo (pull-to-refresh, app resume, "Dobara check karein").
  Future<void> refresh() async {
    final seq = ++_seq;
    if (vendor == null) {
      loading = true;
      notifyListeners();
    }
    final wasPending = vendor != null && !vendor!.approved;
    try {
      final r = await Api.me();
      if (_disposed || seq != _seq) return;
      vendor = r.vendor;
      pendingMessage = r.message;
      error = null;
    } on ApiException catch (e) {
      if (_disposed || seq != _seq) return;
      if (e.authExpired) {
        await _sessionExpired();
        return;
      }
      error = e.message;
    }
    loading = false;
    notifyListeners();
    if (approved) Push.sync(); // push token server tak na pohncha ho (net / approval) to dobara koshish
    // Abhi abhi approve hua ("Dobara check karein" ke baad): dashboard pehli dafa lao
    if (wasPending && approved) {
      loadDashboard();
      startPolling();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _events.close();
    super.dispose();
  }
}

/// Widget tree mein AppState tak pahunchne ka raasta: AppScope.of(context).
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  /// Bina rebuild subscribe kiye (callback / initState ke baad) state tak pahunchna.
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope nahi mila');
    return scope!.notifier!;
  }

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope nahi mila');
    return scope!.notifier!;
  }
}
