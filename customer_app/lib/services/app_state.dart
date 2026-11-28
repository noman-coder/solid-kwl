import 'dart:async';

import 'package:flutter/material.dart';

import '../models/customer.dart';
import 'api.dart';
import 'cart_controller.dart';

/// Chhota paigham jo shell snackbar mein dikhata hai (login / logout / session khatam).
class AppEvent {
  final String message;
  const AppEvent(this.message);
}

/// Poore app ki halat: kaun login hai, kaun sa tab khula hai.
/// Guest (bina login) bhi app dekh sakta hai; login sirf checkout / account jaisi jagah par zaroori hota hai.
class AppState extends ChangeNotifier {
  Customer? customer;

  /// Phone se token / save kiya hua customer padh raha hai (bohat chhota waqt) - splash dikhta hai.
  bool booting = true;

  /// Bottom nav ka tab: 0 Home, 1 Stores, 2 Cart, 3 Orders, 4 Account.
  int tab = 0;

  /// Cart (Phase C7): login customer ka server cart ya guest ka local cart. Badalne par AppState bhi sunne walon ko batati hai
  /// (tab ka badge khud badalta hai).
  final CartController cart = CartController();

  /// Cart ke items ki ginti (tab ke badge ke liye).
  int get cartCount => cart.count;

  AppState() {
    cart.addListener(notifyListeners);
  }

  bool refreshing = false;

  /// Area / location badalne par barhta hai - Home (aur aglay phases mein Stores / Products) isay dekh kar dobara load hote hain.
  int areaVersion = 0;

  /// Stores tab ko bheji gayi filter / search (Home ka banner, dukan ki qism, category, search bar se). Har request par
  /// `storesRequestVersion` barhta hai; Stores tab usay dekh kar apne filters badal leta hai. 'focus': '1' = search box khule.
  Map<String, String> storesRequest = const {};
  int storesRequestVersion = 0;

  /// Chuna hua area ('' = sab areas). Phone mein save hota hai.
  String get area => Api.area;
  bool get areaChosen => Api.areaChosen;

  final StreamController<AppEvent> _events = StreamController<AppEvent>.broadcast();
  Stream<AppEvent> get events => _events.stream;

  bool get loggedIn => Api.token != null && customer != null;

  /// Token hai magar customer ka data abhi load ho raha hai.
  bool get sessionLoading => Api.token != null && customer == null;

  Future<void> init() async {
    Api.onAuthExpired = _onAuthExpired;
    await Api.load();
    customer = Api.token != null ? Api.cachedCustomer : null;
    booting = false;
    notifyListeners();
    unawaited(cart.init());
    if (Api.token != null) unawaited(refreshMe());
  }

  /// Taza customer server se. Net na ho to purana (phone mein save) dikhta rehta hai.
  Future<void> refreshMe() async {
    if (Api.token == null || refreshing) return;
    refreshing = true;
    notifyListeners();
    try {
      final r = await Api.me();
      customer = r.customer;
    } on ApiException {
      // authExpired ho to _onAuthExpired chal chuka; net ka masla ho to purana data rehne do
    } catch (_) {
      // ghair-mutawaqqa: purana data rehne do
    }
    refreshing = false;
    notifyListeners();
  }

  /// Login / register / OTP ke baad customer lagao.
  void setCustomer(Customer c) {
    customer = c;
    notifyListeners();
  }

  /// Login ya register kamyab: customer lagao + (ho to) khush-aamdeed.
  void onAuthenticated(Customer c, {String? message}) {
    customer = c;
    notifyListeners();
    if (message != null && message.isNotEmpty) say(message);
    unawaited(_mergeCartAfterLogin());
  }

  /// Guest ka local cart server cart mein jode (login ke baad); kuch na jur sake to paigham.
  Future<void> _mergeCartAfterLogin() async {
    final msg = await cart.onLogin();
    if (msg.isNotEmpty) say(msg);
  }

  Future<void> logout() async {
    await Api.logout();
    customer = null;
    await cart.reset();
    notifyListeners();
    say('Aap logout ho gaye.');
  }

  void _onAuthExpired() {
    customer = null;
    unawaited(cart.reset());
    notifyListeners();
    say('Aap ka session khatam ho gaya. Dobara login karein.');
  }

  /// Area chuno (khali = sab areas): phone mein save, Home dobara load.
  Future<void> setArea(String value) async {
    await Api.saveArea(value);
    areaVersion++;
    notifyListeners();
  }

  /// GPS location badli / hatai gayi (faasle dobara hisab hon).
  void locationChanged() {
    areaVersion++;
    notifyListeners();
  }

  /// Stores tab kholo (filters ke saath): Home ke banner / dukan ki qism / category / search bar se.
  /// Params: q, sort, open, free, top, new, type, category, focus.
  void openStores([Map<String, String> params = const {}]) {
    storesRequest = Map<String, String>.unmodifiable(params);
    storesRequestVersion++;
    tab = 1;
    notifyListeners();
  }

  void goTab(int i) {
    if (i == tab) return;
    tab = i;
    notifyListeners();
  }

  void say(String message) {
    if (!_events.isClosed) _events.add(AppEvent(message));
  }

  @override
  void dispose() {
    cart.removeListener(notifyListeners);
    cart.dispose();
    _events.close();
    super.dispose();
  }
}

/// Widget tree mein `AppScope.of(context)` se AppState milti hai (badalne par widget khud dobara bante hain).
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope nahi mila');
    return scope!.notifier!;
  }

  /// Bina sunne (rebuild ke baghair) AppState: button dabane jaise kaam ke liye.
  static AppState read(BuildContext context) {
    final el = context.getElementForInheritedWidgetOfExactType<AppScope>();
    assert(el != null, 'AppScope nahi mila');
    return (el!.widget as AppScope).notifier!;
  }
}
