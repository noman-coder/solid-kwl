import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/dashboard.dart';
import '../models/orders.dart';
import '../models/vendor.dart';
import 'api.dart';

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
    await Future.wait([refresh(), loadDashboard(), refreshOrders()]);
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
      if (hasNewer) _alertNewOrder();
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
