import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/skeleton.dart';
import 'dashboard.dart';
import 'more.dart';
import 'orders.dart';
import 'pending.dart';
import 'placeholder_tab.dart';

/// Login ke baad ka main screen: 5 tabs (Dashboard, Orders, Products, Sales, More).
/// Approval baqi ho to sirf PendingScreen. Dashboard (V4) aur Orders (V5) tabs bhar chuke hain; baqi tabs
/// "jald aa raha hai" hain - aglay phases mein bharte jayenge.
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

  static const _titles = ['Dashboard', 'Orders', 'Products', 'Sales', 'More'];

  @override
  void initState() {
    super.initState();
    _state = AppState(onLogout: widget.onLogout);
    final r = widget.initial;
    if (r != null) _state.seed(r);
    _sub = _state.events.listen(_toast);
    WidgetsBinding.instance.addObserver(this);
    _state.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
                const PlaceholderTab(icon: Icons.inventory_2_outlined, title: 'Products'),
                const PlaceholderTab(icon: Icons.bar_chart_rounded, title: 'Sales'),
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
