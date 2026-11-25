import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api.dart';
import '../services/app_state.dart';
import '../services/push.dart';
import '../widgets/empty_state.dart';
import '../widgets/in_app_banner.dart';
import '../widgets/skeleton.dart';
import 'dashboard.dart';
import 'more.dart';
import 'notification_permission.dart';
import 'order_detail.dart';
import 'orders.dart';
import 'pending.dart';
import 'products.dart';
import 'rider_cash.dart';
import 'sales.dart';
import 'stock.dart';

/// Login ke baad ka main screen: 5 tabs (Dashboard, Orders, Products, Sales, More).
/// Approval baqi ho to sirf PendingScreen. Dashboard (V4), Orders (V5), Products (V8) aur Sales (V11) tabs bhar chuke hain;
/// baqi (More) aglay phases mein bharta jayega.
/// Phase V7: push (token register, banner, notification tap -> order detail) yahin se judta hai.
class VendorShell extends StatefulWidget {
  final LoginResult? initial;
  final Future<void> Function() onLogout;
  const VendorShell({super.key, this.initial, required this.onLogout});

  @override
  State<VendorShell> createState() => _VendorShellState();
}

class _VendorShellState extends State<VendorShell> with WidgetsBindingObserver {
  late final AppState _state;
  StreamSubscription<AppEvent>? _sub;
  PushTarget? _pendingOpen; // tap hua par vendor abhi load nahi hua
  bool _permAsked = false;

  static const _titles = ['Dashboard', 'Orders', 'Products', 'Sales', 'More'];

  @override
  void initState() {
    super.initState();
    _state = AppState(onLogout: widget.onLogout);
    final r = widget.initial;
    if (r != null) _state.seed(r);
    _sub = _state.events.listen(_toast);
    WidgetsBinding.instance.addObserver(this);
    // Push: app khuli ho to banner, notification par tap to sahi screen (teeno haalat: band / background / khuli)
    Push.onMessage = _onPushMessage;
    Push.onOpen = _openTarget;
    _pendingOpen = Push.takePendingOpen();
    _state.addListener(_onStateChanged);
    Push.start();
    _state.start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onStateChanged()); // login se seed hua vendor pehle se maujood ho sakta hai
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Push.onMessage = null;
    Push.onOpen = null;
    InAppBanner.hide();
    _state.removeListener(_onStateChanged);
    _sub?.cancel();
    _state.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _state.refreshAll();
      _state.startPolling(); // naye orders ka poll sirf app khuli ho tab
    } else if (s == AppLifecycleState.paused) {
      _state.stopPolling();
    }
  }

  // ------------------------------------------------------------------ push

  /// App khuli hai aur push aayi: list/dashboard taza + in-app banner + awaaz.
  void _onPushMessage(PushTarget t) {
    if (!mounted || !_state.approved) return;
    _state.onPushArrived();
    if (t.isNewOrder) {
      if (!_state.claimOrderAlert(t.orderId)) return; // poll pehle hi bata chuka
      _ring();
    } else {
      HapticFeedback.mediumImpact();
    }
    InAppBanner.show(
      context,
      title: t.title.isEmpty ? (t.isNewOrder ? 'Naya order aaya hai' : 'Naya alert') : t.title,
      body: t.body,
      highlight: t.isNewOrder,
      onTap: () => _openTarget(t),
    );
  }

  /// Naye order ki awaaz + do dafa vibration (app khuli ho tab).
  void _ring() {
    try {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      Future<void>.delayed(const Duration(milliseconds: 450), HapticFeedback.heavyImpact);
    } catch (_) {}
  }

  /// Notification / banner par tap: order detail (ya sahi tab) kholo.
  void _openTarget(PushTarget t) {
    if (!mounted) return;
    if (_state.vendor == null) {
      _pendingOpen = t; // abhi load ho raha hai: load hote hi khulega
      return;
    }
    if (!_state.approved) return; // approval baqi: kholne ko kuch nahi
    InAppBanner.hide();
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst); // pehle se khula detail / sheet band
    if (t.hasOrder) {
      _state.goTab(1);
      unawaited(openOrderById(context, _state, t.orderId));
      if (t.isNewOrder || t.type == 'order_cancelled') _state.ordersChanged(); // list bhi taza
    } else if (t.isStock) {
      _state.goTab(2);
      _state.stockChanged(); // lists purani: taza ho jayen
      unawaited(openStockScreen(context)); // seedha Stock screen (kam / khatam list)
    } else if (t.isRiderCash) {
      _state.goTab(4);
      _state.loadDashboard(); // cash badge taza
      unawaited(openRiderCashScreen(context)); // seedha Rider cash screen (confirm / reject)
    } else {
      _state.goTab(0);
      _state.loadDashboard();
    }
  }

  /// State badli: tap ka intezar ho to kholo, aur approve hote hi ek dafa notification ki ijazat ka screen.
  void _onStateChanged() {
    if (!mounted) return;
    if (_pendingOpen != null && _state.vendor != null) {
      final t = _pendingOpen!;
      _pendingOpen = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openTarget(t));
    }
    if (!_permAsked && _state.approved) {
      _permAsked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _askNotifications());
    }
  }

  Future<void> _askNotifications() async {
    if (!mounted || !Push.ready) return;
    if (await Push.notificationsOn()) return;
    final p = await SharedPreferences.getInstance();
    if (p.getBool('notif_prompt_done') == true || !mounted) return;
    await p.setBool('notif_prompt_done', true);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const NotificationPermissionScreen(),
    ));
  }

  void _toast(AppEvent e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(e.message)));
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: _state,
      child: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          // Pehli dafa load ho raha hai
          if (_state.vendor == null && _state.loading) {
            return Scaffold(
              appBar: AppBar(title: const Text('Vendor App')),
              body: const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 4)),
            );
          }
          // Load nahi hua (internet / server)
          if (_state.vendor == null) {
            return Scaffold(
              appBar: AppBar(title: const Text('Vendor App')),
              body: EmptyState(
                icon: Icons.wifi_off_rounded,
                title: 'Load nahi ho saka',
                message: _state.error ?? 'Internet check karein.',
                action: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: _state.refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Dobara koshish karein'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: widget.onLogout, child: const Text('Logout')),
                  ],
                ),
              ),
            );
          }
          if (!_state.approved) {
            return PendingScreen(state: _state, onLogout: widget.onLogout);
          }
          final tab = _state.tab;
          return Scaffold(
            appBar: AppBar(title: Text(tab == 0 ? _state.vendor!.name : _titles[tab])),
            body: IndexedStack(
              index: tab,
              children: [
                const DashboardScreen(),
                const OrdersScreen(),
                const ProductsScreen(),
                const SalesScreen(),
                MoreScreen(onLogout: widget.onLogout),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: _state.goTab,
              destinations: [
                const NavigationDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: 'Dashboard'),
                NavigationDestination(
                    icon: _OrdersIcon(count: _state.newOrders, selected: false),
                    selectedIcon: _OrdersIcon(count: _state.newOrders, selected: true),
                    label: 'Orders'),
                const NavigationDestination(
                    icon: Icon(Icons.inventory_2_outlined),
                    selectedIcon: Icon(Icons.inventory_2),
                    label: 'Products'),
                const NavigationDestination(
                    icon: Icon(Icons.bar_chart_outlined),
                    selectedIcon: Icon(Icons.bar_chart),
                    label: 'Sales'),
                const NavigationDestination(
                    icon: Icon(Icons.menu_rounded),
                    selectedIcon: Icon(Icons.menu_open_rounded),
                    label: 'More'),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Orders tab ka icon; naye (jawab ke muntazir) orders hon to badge.
class _OrdersIcon extends StatelessWidget {
  final int count;
  final bool selected;
  const _OrdersIcon({required this.count, required this.selected});

  @override
  Widget build(BuildContext context) {
    final icon = Icon(selected ? Icons.receipt_long : Icons.receipt_long_outlined);
    if (count <= 0) return icon;
    return Badge(label: Text(count > 99 ? '99+' : '$count'), child: icon);
  }
}
