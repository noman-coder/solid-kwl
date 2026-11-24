import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/push.dart';
import '../theme.dart';
import 'dashboard.dart';
import 'map_tab.dart';
import 'orders.dart';
import 'profile.dart';
import 'wallet.dart';

/// Login ke baad ka main screen: 5 tabs (Dashboard, Orders, Map, Wallet, Profile).
/// AppState yahan banta hai - 12 sec ka refresh timer sirf yahin chalta hai aur sab tabs share karte hain.
class RiderShell extends StatefulWidget {
  final Future<void> Function() onLogout;
  const RiderShell({super.key, required this.onLogout});

  @override
  State<RiderShell> createState() => _RiderShellState();
}

class _RiderShellState extends State<RiderShell> with WidgetsBindingObserver {
  late final AppState _state;
  StreamSubscription<AppEvent>? _sub;

  static const _titles = ['Dashboard', 'Orders', 'Map', 'Wallet', 'Profile'];

  @override
  void initState() {
    super.initState();
    _state = AppState(onLogout: widget.onLogout);
    _sub = _state.events.listen(_toast);
    WidgetsBinding.instance.addObserver(this);
    _state.start();
    // Push: notification aane par orders refresh, tap par Orders > Naye tab
    Push.onMessage = () => _state.refresh();
    Push.onOpen = () => _state.goTab(1, ordersSub: 0);
    if (Push.takePendingOpen()) _state.goTab(1, ordersSub: 0);
    Push.start();
  }

  @override
  void dispose() {
    Push.onMessage = null;
    Push.onOpen = null;
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _state.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _state.refresh();
  }

  void _toast(AppEvent e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(e.message),
        action: e.actionLabel == null
            ? null
            : SnackBarAction(label: e.actionLabel!, onPressed: e.onAction ?? () {}),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: _state,
      child: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          final offers = _state.offers.length;
          final tab = _state.tab;
          return Scaffold(
            appBar: AppBar(
              title: Text(_titles[tab]),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: _state.online ? kGreen : Colors.grey),
                      const SizedBox(width: 6),
                      Text(_state.online ? 'Online' : 'Offline',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ],
            ),
            body: IndexedStack(
              index: tab,
              children: const [
                DashboardScreen(),
                OrdersScreen(),
                MapTab(),
                WalletScreen(),
                ProfileScreen(),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => _state.goTab(i),
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: 'Dashboard',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: offers > 0,
                    label: Text('$offers'),
                    child: const Icon(Icons.receipt_long_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: offers > 0,
                    label: Text('$offers'),
                    child: const Icon(Icons.receipt_long),
                  ),
                  label: 'Orders',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.map_outlined),
                  selectedIcon: Icon(Icons.map),
                  label: 'Map',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  selectedIcon: Icon(Icons.account_balance_wallet),
                  label: 'Wallet',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: 'Profile',
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
