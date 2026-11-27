import 'package:flutter/material.dart';

import '../models/order.dart';
import '../services/app_state.dart';
import '../widgets/deliver_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/skeleton.dart';
import '../widgets/notice_card.dart';
import '../widgets/order_card.dart';
import 'history_tab.dart';
import 'order_detail.dart';

/// Orders tab: 3 sub-tabs - Naye (offers) / Active (mere orders) / History.
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final sub = st.ordersSubTab;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 0, label: Text('Naye (${st.offers.length})')),
                ButtonSegment(value: 1, label: Text('Active (${st.mine.length})')),
                const ButtonSegment(value: 2, label: Text('History')),
              ],
              selected: {sub},
              onSelectionChanged: (s) => st.setOrdersSub(s.first),
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: sub,
            children: const [_OrderList(offer: true), _OrderList(offer: false), HistoryTab()],
          ),
        ),
      ],
    );
  }
}

/// Naye ya Active orders ki list.
class _OrderList extends StatelessWidget {
  final bool offer;
  const _OrderList({required this.offer});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final list = offer ? st.offers : st.mine;

    Widget body;
    if (st.loading) {
      body = const Padding(padding: EdgeInsets.all(12), child: SkeletonList(count: 3, height: 150));
    } else if (offer && !st.online) {
      body = SizedBox(
        height: 380,
        child: EmptyState(
          icon: Icons.power_settings_new,
          title: 'Aap offline hain',
          message: 'Naye orders dekhne ke liye online hon.',
          action: FilledButton(
            onPressed: st.busy ? null : () => st.toggleOnline(true),
            child: const Text('Online hon'),
          ),
        ),
      );
    } else if (list.isEmpty) {
      body = SizedBox(
        height: 380,
        child: EmptyState(
          icon: offer ? Icons.hourglass_empty : Icons.inbox_outlined,
          title: offer ? 'Abhi koi naya order nahi' : 'Koi active order nahi',
          message: offer
              ? 'Naya order aate hi sound aur vibration se pata chal jayega.'
              : 'Naye tab se order accept karein.',
        ),
      );
    } else {
      body = Column(children: [
        for (final o in list)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OrderCard(
              order: o,
              offer: offer,
              busy: st.busy || (offer && st.cashLimitReached),
              onTap: () => openOrderDetail(context, st, id: o.id, initial: o, offer: offer),
              onAccept: () => _accept(context, st, o),
              onPickup: () => st.pickup(o),
              onDeliver: () => _deliver(context, st, o),
            ),
          ),
      ]);
    }

    return RefreshIndicator(
      onRefresh: () => st.refresh(withDashboard: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          if (st.error != null) ...[
            NoticeCard(level: NoticeLevel.error, icon: Icons.wifi_off, text: st.error!),
            const SizedBox(height: 10),
          ],
          if (st.gpsWarn != null && !offer) ...[
            NoticeCard(
              level: NoticeLevel.warn,
              icon: Icons.location_off,
              text: st.gpsWarn!,
              actionLabel: 'Dobara',
              onAction: st.retryGps,
            ),
            const SizedBox(height: 10),
          ],
          if (offer && st.cashLimitReached) ...[
            const NoticeCard(
              level: NoticeLevel.error,
              icon: Icons.account_balance_wallet,
              text: 'Cash hadd poori hai. Naya order lene se pehle cash handover karein.',
            ),
            const SizedBox(height: 10),
          ],
          body,
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Future<void> _accept(BuildContext context, AppState st, RiderOrder o) async {
    final ok = await st.accept(o);
    if (ok) st.setOrdersSub(1); // ab ye "Active" mein hai
  }

  Future<void> _deliver(BuildContext context, AppState st, RiderOrder o) async {
    if (await confirmDeliver(context, o)) await st.deliver(o);
  }
}
