import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cart.dart';
import '../utils.dart';
import 'api.dart';

/// Guest ke local cart ki ek line (phone mein save). Server par kuch nahi jata jab tak login + merge na ho.
class GuestLine {
  final int productId;
  final int qty;
  final int storeId;
  final String storeName;

  const GuestLine({required this.productId, required this.qty, required this.storeId, required this.storeName});

  GuestLine withQty(int q) => GuestLine(productId: productId, qty: q, storeId: storeId, storeName: storeName);

  Map<String, dynamic> toJson() => {'id': productId, 'q': qty, 's': storeId, 'sn': storeName};

  static GuestLine? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = toI(j['id']);
    final q = toI(j['q']);
    if (id <= 0 || q <= 0) return null;
    return GuestLine(productId: id, qty: q, storeId: toI(j['s']), storeName: s(j['sn']));
  }
}

/// `CartController.add` ka nateeja.
class CartAddOutcome {
  final bool ok;
  final String message;

  /// Doosre store ka maal: customer se poochna hai (purana cart khali karein?).
  final bool conflict;
  final String currentStore;
  final String newStore;

  const CartAddOutcome({
    required this.ok,
    this.message = '',
    this.conflict = false,
    this.currentStore = '',
    this.newStore = '',
  });
}

/// Cart ki poori halat: login customer ka server cart ya guest ka local cart (dono ek jaisa dikhte hain).
/// - Login: har kaam server API par (qeemat / stock server dekhta hai).
/// - Guest: phone mein (shared_preferences), dikhane ke liye server `cart/preview/` se qeemat aati hai.
/// - Login par guest cart `cart/merge/` se server cart mein judta hai.
class CartController extends ChangeNotifier {
  static const String _kGuest = 'guest_cart_v1';
  static const int _maxQty = 1000;

  CartData? data;
  bool loading = false;

  /// Aakhri refresh fail hua (net / server) - data purana ho sakta hai.
  ApiException? error;

  /// Un products ke ids jin par abhi kaam chal raha hai (stepper band rahe).
  final Set<int> busy = <int>{};

  List<GuestLine> _guest = <GuestLine>[];
  int _count = 0;
  int _seq = 0;
  bool _disposed = false;

  /// Tab ke badge ki ginti.
  int get count => _count;

  bool get _loggedIn => Api.token != null;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  int get _guestCount => _guest.fold<int>(0, (a, l) => a + l.qty);

  // ------------------------------------------------------------------ shuruaat / login / logout

  /// App khulte hi: guest cart phone se, login ho to server se.
  Future<void> init() async {
    await _loadGuest();
    _count = _loggedIn ? _count : _guestCount;
    _notify();
    unawaited(refresh(silent: true));
  }

  /// Logout / session khatam: cart saaf (guest ka bhi - login mein merge ho chuka hota hai).
  Future<void> reset() async {
    _seq++;
    data = null;
    error = null;
    busy.clear();
    _guest = <GuestLine>[];
    _count = 0;
    await _saveGuest();
    _notify();
  }

  /// Login ke baad: guest cart ho to server cart mein jodo. Paigham (ho to) wapas.
  Future<String> onLogin() async {
    var message = '';
    if (_guest.isNotEmpty) {
      try {
        final r = await Api.cartMerge(_guest.map((l) => {'product_id': l.productId, 'quantity': l.qty}).toList());
        _guest = <GuestLine>[];
        await _saveGuest();
        _seq++;                                   // merge se pehle chali refresh ka puraana jawab na lage
        data = r.cart;
        _count = r.cart.count;
        error = null;
        if (r.skipped > 0) {
          message = 'Kuch items cart mein nahi aa sake (khatam ya doosre store ke).';
        } else if (r.merged > 0) {
          message = 'Aap ka cart mehfooz hai.';
        }
        _notify();
        return message;
      } on ApiException {
        // merge nahi hua: guest cart phone mein rehne do, server ka cart dikhao
      } catch (_) {}
    }
    await refresh(silent: true);
    return message;
  }

  // ------------------------------------------------------------------ refresh

  /// Cart taza karo. `silent`: skeleton na dikhao (pehle se data ho / peeche chale).
  Future<void> refresh({bool silent = false}) async {
    final my = ++_seq;
    if (!silent || data == null) {
      loading = data == null;
      _notify();
    }
    try {
      CartResult r;
      if (_loggedIn) {
        r = await Api.cart();
      } else if (_guest.isEmpty) {
        if (my != _seq) return;
        data = CartData.empty;
        _count = 0;
        error = null;
        loading = false;
        _notify();
        return;
      } else {
        r = await Api.cartPreview(_guest.map((l) => {'product_id': l.productId, 'quantity': l.qty}).toList());
      }
      if (my != _seq) return;
      data = r.cart;
      _count = r.cart.count;
      error = null;
    } on ApiException catch (e) {
      if (my != _seq) return;
      error = e;
    } catch (_) {
      if (my != _seq) return;
      error = ApiException('Cart load nahi ho saka. Dobara koshish karein.', 0, code: 'network');
    }
    loading = false;
    _notify();
  }

  // ------------------------------------------------------------------ add

  /// Cart mein dalo. `maxQty` (>0) guest ke liye stock ki hadd (login ke liye server khud dekhta hai).
  Future<CartAddOutcome> add({
    required int productId,
    required int storeId,
    required String storeName,
    int qty = 1,
    int maxQty = 0,
    bool replace = false,
  }) async {
    if (qty < 1) return const CartAddOutcome(ok: false, message: 'Quantity kam az kam 1 honi chahiye.');
    if (_loggedIn) {
      try {
        final r = await Api.cartAdd(productId, qty, replace: replace);
        _seq++;
        data = r.cart;
        _count = r.cart.count;
        error = null;
        _notify();
        return CartAddOutcome(ok: true, message: r.message.isNotEmpty ? r.message : 'Cart mein add ho gaya.');
      } on ApiException catch (e) {
        if (e.code == 'cart_conflict') {
          return CartAddOutcome(
            ok: false,
            conflict: true,
            message: e.message,
            currentStore: s(e.data['current_store']),
            newStore: s(e.data['new_store']),
          );
        }
        return CartAddOutcome(ok: false, message: e.message);
      } catch (_) {
        return const CartAddOutcome(ok: false, message: 'Cart mein add nahi ho saka. Dobara koshish karein.');
      }
    }
    return _addGuest(productId, storeId, storeName, qty, maxQty, replace);
  }

  Future<CartAddOutcome> _addGuest(
      int productId, int storeId, String storeName, int qty, int maxQty, bool replace) async {
    var lines = List<GuestLine>.from(_guest);
    if (lines.isNotEmpty && lines.first.storeId != storeId) {
      if (!replace) {
        return CartAddOutcome(
          ok: false,
          conflict: true,
          message: 'Aap ke cart mein "${lines.first.storeName}" ka maal hai. Purana cart khali karein?',
          currentStore: lines.first.storeName,
          newStore: storeName,
        );
      }
      lines = <GuestLine>[];
    }
    final idx = lines.indexWhere((l) => l.productId == productId);
    final have = idx >= 0 ? lines[idx].qty : 0;
    final want = have + qty;
    if (want > _maxQty) {
      return const CartAddOutcome(ok: false, message: 'Itna zyada ek dafa mein nahi mangwa sakte.');
    }
    if (maxQty > 0 && want > maxQty) {
      return CartAddOutcome(ok: false, message: 'Sirf $maxQty units available hain.');
    }
    if (idx >= 0) {
      lines[idx] = lines[idx].withQty(want);
    } else {
      if (lines.length >= 100) {
        return const CartAddOutcome(ok: false, message: 'Cart mein is se zyada alag items nahi aa sakte.');
      }
      lines.add(GuestLine(productId: productId, qty: want, storeId: storeId, storeName: storeName));
    }
    _guest = lines;
    _count = _guestCount;
    await _saveGuest();
    _notify();
    unawaited(refresh(silent: true));
    return const CartAddOutcome(ok: true, message: 'Cart mein add ho gaya.');
  }

  // ------------------------------------------------------------------ quantity / remove / clear / ack

  /// Quantity badlo. Nateeja: null = theek, warna paigham (stock khatam, net...).
  Future<String?> setQty(int productId, int qty) async {
    if (qty <= 0) return remove(productId);
    if (busy.contains(productId)) return null;
    busy.add(productId);
    _notify();
    try {
      if (_loggedIn) {
        final r = await Api.cartUpdate(productId, qty);
        _seq++;
        data = r.cart;
        _count = r.cart.count;
        error = null;
      } else {
        final i = _guest.indexWhere((l) => l.productId == productId);
        if (i >= 0) {
          _guest[i] = _guest[i].withQty(qty > _maxQty ? _maxQty : qty);
          await _saveGuest();
        }
        _count = _guestCount;
        await refresh(silent: true);
      }
      return null;
    } on ApiException catch (e) {
      if (e.code == 'stock' || e.code == 'unavailable' || e.code == 'not_in_cart') {
        unawaited(refresh(silent: true));
      }
      return e.message;
    } catch (_) {
      return 'Quantity badal nahi saki. Dobara koshish karein.';
    } finally {
      busy.remove(productId);
      _notify();
    }
  }

  /// Item hatao (foran screen se hat jata hai, server baad mein). Nateeja: null = theek, warna paigham.
  Future<String?> remove(int productId) async {
    final before = data;
    if (data != null) {
      data = data!.withoutProduct(productId);
      _count = data!.count;
    }
    _notify();
    try {
      if (_loggedIn) {
        final r = await Api.cartRemove(productId);
        _seq++;
        data = r.cart;
        _count = r.cart.count;
        error = null;
      } else {
        _guest = _guest.where((l) => l.productId != productId).toList();
        await _saveGuest();
        _count = _guestCount;
        await refresh(silent: true);
      }
      _notify();
      return null;
    } on ApiException catch (e) {
      data = before;
      _count = before?.count ?? _count;
      _notify();
      return e.message;
    } catch (_) {
      data = before;
      _count = before?.count ?? _count;
      _notify();
      return 'Item hata nahi saka. Dobara koshish karein.';
    }
  }

  /// Poora cart khali.
  Future<String?> clear() async {
    try {
      if (_loggedIn) {
        final r = await Api.cartClear();
        _seq++;
        data = r.cart;
        _count = r.cart.count;
      } else {
        _guest = <GuestLine>[];
        await _saveGuest();
        data = CartData.empty;
        _count = 0;
      }
      error = null;
      _notify();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Cart khali nahi ho saka. Dobara koshish karein.';
    }
  }

  /// 'Qeemat badal gayi' alert dekh liya (login customer; guest ko server alert nahi hota).
  Future<void> acknowledgePrices() async {
    if (!_loggedIn) return;
    try {
      final r = await Api.cartAck();
      _seq++;
      data = r.cart;
      _count = r.cart.count;
      _notify();
    } catch (_) {
      // alert phir dikh jayega - koi nuqsan nahi
    }
  }

  // ------------------------------------------------------------------ phone mein guest cart

  Future<void> _loadGuest() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kGuest);
      if (raw == null || raw.isEmpty) {
        _guest = <GuestLine>[];
        return;
      }
      final j = jsonDecode(raw);
      _guest = j is List ? j.map(GuestLine.fromJson).whereType<GuestLine>().toList() : <GuestLine>[];
    } catch (_) {
      _guest = <GuestLine>[];
    }
  }

  Future<void> _saveGuest() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (_guest.isEmpty) {
        await p.remove(_kGuest);
      } else {
        await p.setString(_kGuest, jsonEncode(_guest.map((l) => l.toJson()).toList()));
      }
    } catch (_) {}
  }
}
