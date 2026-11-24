import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/dashboard.dart';
import '../models/order.dart';
import '../models/rider.dart';
import '../utils.dart';
import 'api.dart';
import 'push.dart';
import 'tracker.dart';

/// Chhota message (toast). Optional button (jaise "Dekhein").
class AppEvent {
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const AppEvent(this.message, {this.actionLabel, this.onAction});
}

/// Poore app ka shared hissa: orders, online status, 12-sec refresh timer aur GPS tracking.
/// Saare tabs isi ko dekhte hain (AppScope.of(context)), is liye timer sirf EK jagah chalta hai.
class AppState extends ChangeNotifier {
  AppState({required this.onLogout});

  /// Session khatam (401) ya logout par call hota hai.
  final Future<void> Function() onLogout;

  static const Duration refreshEvery = Duration(seconds: 12);

  Timer? _timer;
  bool _disposed = false;
  int _seq = 0; // sirf sab se naya refresh apply hota hai
  int _lastOffers = -1;
  bool _permAsked = false;

  RiderMini profile = RiderMini.empty;
  List<RiderOrder> offers = [];
  List<RiderOrder> mine = [];
  bool online = false;
  bool loading = true;
  bool busy = false;
  String? error; // internet / server ka masla
  String? gpsWarn; // GPS / permission ka masla

  // ---- Phase 5: dashboard + tab navigation ----
  DashboardData? dashboard;
  String? dashboardError;
  int tab = 0; // 0 Dashboard, 1 Orders, 2 Map, 3 Wallet, 4 Profile
  int ordersSubTab = 0; // 0 Naye, 1 Active, 2 History
  int historyVersion = 0; // deliver hone par badhta hai - History dobara load hoti hai
  bool _dashDirty = true;
  int _tick = 0;

  final StreamController<AppEvent> _events = StreamController<AppEvent>.broadcast();

  /// Chhote messages (toast) - shell inhein SnackBar mein dikhata hai.
  Stream<AppEvent> get events => _events.stream;

  void toast(String msg, {String? actionLabel, VoidCallback? onAction}) {
    if (!_disposed && !_events.isClosed) {
      _events.add(AppEvent(msg, actionLabel: actionLabel, onAction: onAction));
    }
  }

  /// Cash hadd poori ho to naya order accept nahi hona chahiye (pehle handover).
  bool get cashLimitReached => dashboard?.limitReached == true;

  void goTab(int i, {int? ordersSub}) {
    tab = i;
    if (ordersSub != null) ordersSubTab = ordersSub;
    notifyListeners();
  }

  void setOrdersSub(int i) {
    ordersSubTab = i;
    notifyListeners();
  }

  void start() {
    refresh();
    _timer?.cancel();
    _timer = Timer.periodic(refreshEvery, (_) => refresh());
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _events.close();
    super.dispose();
  }

  /// withDashboard: true ho to dashboard bhi lazmi dobara aata hai (warna har 3rd refresh par).
  Future<void> refresh({bool withDashboard = false}) async {
    if (_disposed) return;
    if (withDashboard) _dashDirty = true;
    final my = ++_seq;
    try {
      final d = await Api.orders();
      if (_disposed || my != _seq) return;
      final newOffers = listOfMaps(d['offers']).map(RiderOrder.fromJson).toList();
      final newMine = listOfMaps(d['mine']).map(RiderOrder.fromJson).toList();
      if (_lastOffers >= 0 && newOffers.length > _lastOffers) _alertNewOrder();
      _lastOffers = newOffers.length;
      offers = newOffers;
      mine = newMine;
      online = d['online'] == true;
      profile = RiderMini.fromJson(d['profile']);
      error = null;
      loading = false;
      notifyListeners();
      Push.ensureRegistered(); // push token server tak na pohncha ho to dobara koshish
      try {
        await _syncTracking(d['tracking'] == true);
      } catch (_) {
        // GPS / permission ka masla app ko na roke
      }
      if (_dashDirty || dashboard == null || _tick++ % 3 == 0) {
        await _loadDashboard();
      }
    } on ApiException catch (e) {
      if (_disposed || my != _seq) return;
      if (e.authExpired) {
        await onLogout();
        return;
      }
      error = e.message;
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _loadDashboard() async {
    _dashDirty = false;
    try {
      final d = await Api.dashboard();
      if (_disposed) return;
      dashboard = DashboardData.fromJson(d);
      dashboardError = null;
    } on ApiException catch (e) {
      if (_disposed) return;
      if (e.authExpired) {
        await onLogout();
        return;
      }
      dashboardError = e.message;
      _dashDirty = true;
    }
    notifyListeners();
  }

  /// Naya offer aaya: sound + do dafa vibration + toast ("Dekhein" button se Naye orders khulte hain).
  Future<void> _alertNewOrder() async {
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    toast('🆕 Naya order available!',
        actionLabel: 'Dekhein', onAction: () => goTab(1, ordersSub: 0));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    HapticFeedback.heavyImpact();
  }

  Future<void> _syncTracking(bool need) async {
    if (need) {
      if (Tracker.running) return;
      if (_permAsked) return;
      _permAsked = true;
      final err = await Tracker.ensurePermissions();
      if (err != null) {
        gpsWarn = err;
        notifyListeners();
        return;
      }
      await Tracker.start();
      gpsWarn = null;
      notifyListeners();
    } else {
      _permAsked = false;
      if (Tracker.running) await Tracker.stop();
      if (gpsWarn != null) {
        gpsWarn = null;
        notifyListeners();
      }
    }
  }

  /// GPS warning par "Dobara" dabane se.
  Future<void> retryGps() async {
    _permAsked = false;
    await refresh();
  }

  /// Koi bhi action (accept / pickup / deliver) - busy flag, toast, aur phir refresh.
  /// true = kaam ho gaya.
  Future<bool> run(Future<String> Function() job) async {
    if (busy) return false;
    busy = true;
    notifyListeners();
    var ok = false;
    try {
      toast(await job());
      ok = true;
    } on ApiException catch (e) {
      if (e.authExpired) {
        await onLogout();
        return false;
      }
      toast('❌ ${e.message}');
    } finally {
      busy = false;
      notifyListeners();
    }
    await refresh(withDashboard: true);
    return ok;
  }

  Future<bool> accept(RiderOrder o) => run(() => Api.accept(o.id));
  Future<bool> pickup(RiderOrder o) => run(() => Api.action(o.id, 'pickup'));

  Future<bool> deliver(RiderOrder o) async {
    final ok = await run(() => Api.action(o.id, 'deliver'));
    if (ok) {
      historyVersion++;
      notifyListeners();
    }
    return ok;
  }

  Future<void> toggleOnline(bool v) async {
    online = v;
    notifyListeners();
    try {
      await Api.setOnline(v);
    } on ApiException catch (e) {
      if (e.authExpired) {
        await onLogout();
        return;
      }
      toast('❌ ${e.message}');
    }
    await refresh();
  }
}

/// Widget tree mein AppState tak pahunchne ka raasta:  final st = AppScope.of(context);
/// (State badalne par ye widget khud rebuild hota hai.)
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope nahi mila');
    return scope!.notifier!;
  }
}
