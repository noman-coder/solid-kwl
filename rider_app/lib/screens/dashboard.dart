import 'package:flutter/material.dart';

import '../models/dashboard.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/skeleton.dart';
import '../widgets/notice_card.dart';
import '../widgets/online_card.dart';
import '../widgets/section_title.dart';
import '../widgets/stat_card.dart';
import '../widgets/week_chart.dart';
import 'order_detail.dart';

/// Dashboard tab: online switch, warnings, aaj / hafta / mahina, cash, rating, 7-din chart, active orders.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  NoticeLevel _level(String l) => l == 'error'
      ? NoticeLevel.error
      : l == 'warn'
          ? NoticeLevel.warn
          : NoticeLevel.info;

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final d = st.dashboard;

    return RefreshIndicator(
      onRefresh: () => st.refresh(withDashboard: true),
      child: (st.loading && d == null)
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              children: const [SkeletonList(count: 5)],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              children: [
                const OnlineCard(),
                ..._notices(st, d),
                if (st.online && st.offers.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _OffersTile(count: st.offers.length),
                ],
                if (st.mine.isNotEmpty) ...[
                  const SectionTitle('Active orders'),
                  for (final o in st.mine)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ActiveTile(
                        title: '#${o.orderNo}',
                        subtitle: o.isAssigned
                            ? 'Maal uthana hai: ${o.store.name}'
                            : 'Customer ko dena hai: ${o.customer.name}',
                        trailing: o.isCod ? 'COD ${rs(o.total)}' : 'Paid',
                        onTap: () => openOrderDetail(context, st, id: o.id, initial: o),
                      ),
                    ),
                ],
                if (d != null) ..._stats(d),
                if (d == null && st.dashboardError != null) ...[
                  const SizedBox(height: 10),
                  NoticeCard(level: NoticeLevel.error, icon: Icons.cloud_off, text: st.dashboardError!),
                ],
                const SizedBox(height: 40),
              ],
            ),
    );
  }

  List<Widget> _notices(AppState st, DashboardData? d) {
    final out = <Widget>[];
    void add(Widget w) {
      out
        ..add(const SizedBox(height: 10))
        ..add(w);
    }

    if (st.error != null) {
      add(NoticeCard(level: NoticeLevel.error, icon: Icons.wifi_off, text: st.error!));
    }
    if (st.gpsWarn != null) {
      add(NoticeCard(
        level: NoticeLevel.warn,
        icon: Icons.location_off,
        text: st.gpsWarn!,
        actionLabel: 'Dobara',
        onAction: st.retryGps,
      ));
    }
    if (d != null) {
      for (final w in d.warnings) {
        // "offline" ka message upar OnlineCard se pehle hi dikh jata hai
        if (w.code == 'offline') continue;
        add(NoticeCard(level: _level(w.level), text: w.text));
      }
    }
    return out;
  }

  List<Widget> _stats(DashboardData d) {
    final pct = d.cashLimit > 0 ? (d.cashInHand / d.cashLimit).clamp(0.0, 1.0) : 0.0;
    final cashColor = d.limitReached
        ? Colors.red
        : pct >= 0.8
            ? Colors.amber.shade800
            : kGreen;
    return [
      const SectionTitle('Aaj'),
      Row(
        children: [
          Expanded(
              child: StatCard(
                  icon: Icons.delivery_dining, label: 'Aaj deliveries', value: numText(d.today.deliveries))),
          const SizedBox(width: 10),
          Expanded(
              child: StatCard(
                  icon: Icons.payments_outlined,
                  label: 'Aaj kamai',
                  value: rs(d.today.earned),
                  color: Colors.indigo)),
        ],
      ),
      const SectionTitle('Hafta aur mahina'),
      Row(
        children: [
          Expanded(
              child: StatCard(
                  icon: Icons.date_range,
                  label: 'Hafta (${d.week.deliveries} deliveries)',
                  value: rs(d.week.earned),
                  color: Colors.teal)),
          const SizedBox(width: 10),
          Expanded(
              child: StatCard(
                  icon: Icons.calendar_month,
                  label: 'Mahina (${d.month.deliveries} deliveries)',
                  value: rs(d.month.earned),
                  color: Colors.deepPurple)),
        ],
      ),
      const SectionTitle('Cash aur kamai'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.account_balance_wallet, color: cashColor),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('Cash in hand',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
                  Text(rs(d.cashInHand),
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: cashColor)),
                ],
              ),
              if (d.cashLimit > 0) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: pct.toDouble(),
                    minHeight: 8,
                    color: cashColor,
                    backgroundColor: Colors.grey.shade200,
                  ),
                ),
                const SizedBox(height: 4),
                Text('Hadd: ${rs(d.cashLimit)}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
              const Divider(height: 24),
              _Line('Kamai milni hai (due)', rs(d.due)),
              if (d.pendingHandover > 0) _Line('Handover pending', rs(d.pendingHandover)),
              _Line('Kul deliveries', numText(d.totalDeliveries)),
            ],
          ),
        ),
      ),
      const SectionTitle('Rating'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.star_rounded, color: Colors.amber, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: d.ratingAvg == null
                    ? const Text('Abhi koi rating nahi', style: TextStyle(color: Colors.black54))
                    : Text('${d.ratingAvg!.toStringAsFixed(1)} / 5   (${d.ratingCount} reviews)',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      ),
      const SectionTitle('Pichle 7 din'),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
          child: WeekChart(days: d.chart),
        ),
      ),
    ];
  }
}

class _Line extends StatelessWidget {
  final String label;
  final String value;
  const _Line(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.black54))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class _OffersTile extends StatelessWidget {
  final int count;
  const _OffersTile({required this.count});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    return Card(
      color: kGreen.withValues(alpha: 0.10),
      child: ListTile(
        leading: Badge(label: Text('$count'), child: const Icon(Icons.notifications_active, color: kGreen)),
        title: Text('$count naye order available',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => st.goTab(1, ordersSub: 0),
      ),
    );
  }
}

class _ActiveTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String trailing;
  final VoidCallback onTap;
  const _ActiveTile(
      {required this.title, required this.subtitle, required this.trailing, required this.onTap});

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          onTap: onTap,
          leading: const Icon(Icons.two_wheeler, color: kGreen),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(trailing, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      );
}
