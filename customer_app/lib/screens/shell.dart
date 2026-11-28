import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart' show kAppName;
import '../widgets/app_logo.dart';
import '../widgets/offline_banner.dart';
import 'account_tab.dart';
import 'home_tab.dart';
import 'login.dart';
import 'placeholder_tab.dart';
import 'stores_tab.dart';

/// App ka main screen: 5 tabs (Home, Stores, Cart, Orders, Account).
/// Guest (bina login) bhi sab tabs dekh sakta hai; login sirf checkout / orders / account jaisi jagah par maanga jata hai.
/// Home, Stores (Phase C5) aur Account tab bhare hue hain; baqi tabs aglay phases mein bharte jayenge ("jald aa raha hai").
class CustomerShell extends StatefulWidget {
  const CustomerShell({super.key});

  @override
  State<CustomerShell> createState() => _CustomerShellState();
}

class _CustomerShellState extends State<CustomerShell> {
  StreamSubscription<AppEvent>? _sub;
  AppState? _state;

  static const _titles = ['Home', 'Stores', 'Cart', 'Orders', 'Account'];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final st = AppScope.read(context);
    if (!identical(st, _state)) {
      _sub?.cancel();
      _state = st;
      _sub = st.events.listen(_toast);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _toast(AppEvent e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(e.message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final tab = state.tab;
    return PopScope(
      // Home par nahi hain to back dabane se pehle Home tab, phir app band
      canPop: tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) state.goTab(0);
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: tab == 0 ? 12 : null,
          title: tab == 0
              ? Row(
                  children: [
                    const AppLogo(size: 32),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(kAppName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w900, color: kOrangeDark)),
                    ),
                  ],
                )
              : Text(_titles[tab]),
        ),
        body: Column(
          children: [
            OfflineBanner(onRetry: state.refreshMe),
            Expanded(
              child: IndexedStack(
                index: tab,
                children: [
                  const HomeTab(),
                  const StoresTab(),
                  const PlaceholderTab(
                    icon: Icons.shopping_cart_outlined,
                    title: 'Cart khali hai',
                    message: 'Products add karne ka hissa jald aa raha hai.',
                  ),
                  _OrdersTab(loggedIn: state.loggedIn),
                  const AccountTab(),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) {
            if (i != tab) HapticFeedback.selectionClick();
            state.goTab(i);
          },
          destinations: [
            const NavigationDestination(
                icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
            const NavigationDestination(
                icon: Icon(Icons.storefront_outlined),
                selectedIcon: Icon(Icons.storefront_rounded),
                label: 'Stores'),
            NavigationDestination(
                icon: _CartIcon(count: state.cartCount, selected: false),
                selectedIcon: _CartIcon(count: state.cartCount, selected: true),
                label: 'Cart'),
            const NavigationDestination(
                icon: Icon(Icons.receipt_long_outlined),
                selectedIcon: Icon(Icons.receipt_long),
                label: 'Orders'),
            const NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Account'),
          ],
        ),
      ),
    );
  }
}

/// Orders tab: guest ko login ka kehna, login ho to (abhi) "jald aa raha hai".
class _OrdersTab extends StatelessWidget {
  final bool loggedIn;
  const _OrdersTab({required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    if (!loggedIn) {
      return PlaceholderTab(
        icon: Icons.receipt_long_outlined,
        title: 'Apne orders dekhein',
        message: 'Orders dekhne aur track karne ke liye login karein.',
        action: FilledButton(
          onPressed: () => ensureLoggedIn(context),
          child: const Text('Login karein'),
        ),
      );
    }
    return const PlaceholderTab(
      icon: Icons.receipt_long_outlined,
      title: 'Abhi koi order nahi',
      message: 'Aap ke orders yahan nazar aayenge.',
    );
  }
}

/// Cart tab ka icon; items hon to badge.
class _CartIcon extends StatelessWidget {
  final int count;
  final bool selected;
  const _CartIcon({required this.count, required this.selected});

  @override
  Widget build(BuildContext context) {
    final icon = Icon(selected ? Icons.shopping_cart : Icons.shopping_cart_outlined);
    if (count <= 0) return icon;
    return Badge(label: Text(count > 99 ? '99+' : '$count'), child: icon);
  }
}
