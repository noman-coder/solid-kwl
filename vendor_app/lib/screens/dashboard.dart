import 'package:flutter/material.dart';

import '../models/dashboard.dart';
import '../models/vendor.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/notice_card.dart';
import '../widgets/section_title.dart';
import '../widgets/skeleton.dart';
import '../widgets/stat_card.dart';
import '../widgets/week_chart.dart';

/// Dashboard tab: salam + store naam + Open/Closed switch, alerts, aaj / hafta / mahina ki sale,
/// orders, earnings, rating, products / stock, rider cash, 7 din ka chart, quick actions.
/// Pull-to-refresh; loading par skeleton; net na ho to purana data + "offline" message.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  static const int _tabOrders = 1;
  static const int _tabProducts = 2;

  NoticeLevel _level(String l) => l == 'error'
      ? NoticeLevel.error
      : l == 'warn'
          ? NoticeLevel.warn
          : NoticeLevel.info;

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final d = st.dashboard;
    final v = st.vendor;

    return RefreshIndicator(
      onRefresh: st.refreshAll,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          if (v != null) _StoreHeader(vendor: v, data: d),
          // Pehli dafa load ho raha hai
          if (d == null && st.dashLoading) ...const [
            SizedBox(height: 12),
            SkeletonList(count: 4),
          ],
          // Load nahi hua aur purana data bhi nahi
          if (d == null && !st.dashLoading && st.dashError != null) ...[
            const SizedBox(height: 12),
            NoticeCard(
              level: NoticeLevel.error,
              icon: Icons.cloud_off,
              text: st.dashError!,
              actionLabel: 'Dobara',
              onAction: st.loadDashboard,
            ),
          ],
          if (d != null) ..._content(context, st, d),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context, AppState st, DashboardData d) {
    final out = <Widget>[];

    // ---- offline: purana data
    if (st.dashStale) {
      final t = clockText(d.generatedAt);
      out
        ..add(const SizedBox(height: 10))
        ..add(NoticeCard(
          level: NoticeLevel.warn,
          icon: Icons.wifi_off,
          text: 'Offline - purana data dikh raha hai${t.isEmpty ? '' : ' (aakhri update $t)'}.',
          actionLabel: 'Dobara',
          onAction: st.loadDashboard,
        ));
    }

    // ---- alerts
    for (final w in d.warnings) {
      final VoidCallback? go = _warningTarget(st, w.code);
      out
        ..add(const SizedBox(height: 8))
        ..add(NoticeCard(
          level: _level(w.level),
          text: w.text,
          actionLabel: go == null ? null : 'Dekhein',
          onAction: go,
        ));
    }

    // ---- aaj
    out
      ..add(const SectionTitle('Aaj'))
      ..add(Row(
        children: [
          Expanded(
            child: StatCard(
              icon: Icons.payments_outlined,
              label: 'Aaj ki sale',
              value: rs(d.today.sales),
              color: kTeal,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StatCard(
              icon: Icons.receipt_long_outlined,
              label: 'Aaj ke orders',
              value: numText(d.today.orders),
              color: Colors.indigo,
            ),
          ),
        ],
      ))
      ..add(const SizedBox(height: 10))
      ..add(_NewOrdersTile(count: d.newOrders, onTap: () => st.goTab(_tabOrders)));

    // ---- hafta / mahina
    out
      ..add(const SectionTitle('Hafta aur mahina'))
      ..add(Row(
        children: [
          Expanded(
            child: StatCard(
              icon: Icons.date_range,
              label: 'Hafta (7 din)',
              value: rs(d.week.sales),
              hint: '${numText(d.week.orders)} orders',
              color: Colors.teal,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StatCard(
              icon: Icons.calendar_month,
              label: 'Mahina (30 din)',
              value: rs(d.month.sales),
              hint: '${numText(d.month.orders)} orders',
              color: Colors.deepPurple,
            ),
          ),
        ],
      ));

    // ---- orders ki halat
    out
      ..add(const SectionTitle('Orders'))
      ..add(Row(
        children: [
          Expanded(
              child: _OrderChip(
                  label: 'Naye',
                  count: d.orders.newCount,
                  color: Colors.orange.shade800,
                  onTap: () => st.goTab(_tabOrders))),
          const SizedBox(width: 8),
          Expanded(
              child: _OrderChip(
                  label: 'Chal rahe',
                  count: d.orders.active,
                  color: Colors.blue.shade700,
                  onTap: () => st.goTab(_tabOrders))),
          const SizedBox(width: 8),
          Expanded(
              child: _OrderChip(
                  label: 'Mukammal',
                  count: d.orders.done,
                  color: kTeal,
                  onTap: () => st.goTab(_tabOrders))),
        ],
      ));

    // ---- kamai (earnings)
    out
      ..add(const SectionTitle('Kamai (ab tak)'))
      ..add(Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              _Line('Kul bikri', rs(d.earnings.sales)),
              _Line('Shop ka commission (${numText(d.commissionPercent)}%)', rs(d.earnings.commission)),
              const Divider(height: 20),
              _Line('Aap ka hissa', rs(d.earnings.payable), bold: true, color: kTeal),
            ],
          ),
        ),
      ));

    // ---- rider cash (sirf jab pending ho)
    if (d.riderCash.count > 0) {
      out
        ..add(const SizedBox(height: 10))
        ..add(Card(
          color: Colors.amber.shade50,
          child: ListTile(
            leading: Badge(
              label: Text('${d.riderCash.count}'),
              child: Icon(Icons.payments_outlined, color: Colors.amber.shade900),
            ),
            title: Text('Rider cash confirm karna baqi: ${rs(d.riderCash.amount)}',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('Cash screen jald aa rahi hai'),
          ),
        ));
    }

    // ---- rating
    out
      ..add(const SectionTitle('Rating'))
      ..add(Card(
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
      ));

    // ---- products + stock
    out
      ..add(const SectionTitle('Products'))
      ..add(_ProductsCard(
        products: d.products,
        stock: d.stock,
        onTap: () => st.goTab(_tabProducts),
      ));

    // ---- 7 din
    out
      ..add(const SectionTitle('Pichle 7 din ki sale'))
      ..add(Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
          child: WeekChart(days: d.chart),
        ),
      ));

    // ---- quick actions
    out
      ..add(const SectionTitle('Jaldi kaam'))
      ..add(Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => st.goTab(_tabProducts),
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('Naya product'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => st.goTab(_tabOrders),
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('Naye orders'),
            ),
          ),
        ],
      ));

    return out;
  }

  /// Warning dabane par kahan jayein (None = sirf message).
  VoidCallback? _warningTarget(AppState st, String code) {
    switch (code) {
      case 'new_orders':
        return () => st.goTab(_tabOrders);
      case 'out_of_stock':
      case 'low_stock':
      case 'pending_products':
      case 'rejected_products':
        return () => st.goTab(_tabProducts);
      default:
        return null;
    }
  }
}

// ---------------------------------------------------------------------------

/// Salam + store naam + Open/Closed switch.
class _StoreHeader extends StatelessWidget {
  final Vendor vendor;
  final DashboardData? data;
  const _StoreHeader({required this.vendor, required this.data});

  Future<void> _onSwitch(BuildContext context, AppState st, bool want) async {
    if (!want) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Store band karein?'),
          content: const Text('Store band hone par customer is store se naya order nahi de sakega.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(80, 44)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Band karein'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await st.setStoreOpen(want);
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final store = data?.store;
    // Dashboard aane tak profile (me / login) ka status
    final switchOn = store?.switchOn ?? (vendor.storeStatus != 'closed');
    final isOpen = store?.isOpen ?? vendor.isOpen;
    final busy = (store?.status ?? vendor.storeStatus) == 'busy';
    final hasLogo = vendor.logo != null && vendor.logo!.isNotEmpty;

    late final String title;
    late final String sub;
    late final Color color;
    if (!switchOn) {
      title = 'Store band hai';
      sub = 'Customer abhi order nahi de sakta';
      color = Colors.red.shade700;
    } else if (store != null && !store.withinHours) {
      title = 'Store khula hai (timing se bahar)';
      sub = store.hasHours
          ? 'Timing ${store.opensAt} - ${store.closesAt}; abhi customer ko band dikhega'
          : 'Abhi customer ko band dikhega';
      color = Colors.amber.shade900;
    } else if (busy) {
      title = 'Store khula hai (Busy)';
      sub = 'Orders milte hain, customer ko der ka bataya jata hai';
      color = Colors.amber.shade900;
    } else {
      title = 'Store khula hai';
      sub = 'Customer order de sakte hain';
      color = kTeal;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: kTeal.withValues(alpha: 0.13),
                  backgroundImage: hasLogo ? NetworkImage(Api.absUrl(vendor.logo!)) : null,
                  onBackgroundImageError: hasLogo ? (_, __) {} : null,
                  child: hasLogo
                      ? null
                      : Text(vendor.initial,
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: kTeal)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Assalam o Alaikum', style: TextStyle(fontSize: 12, color: Colors.black54)),
                      Text(vendor.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
                if (vendor.rating > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star_rounded, color: Colors.amber, size: 18),
                        const SizedBox(width: 2),
                        Text(vendor.rating.toStringAsFixed(1),
                            style: const TextStyle(fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Icon(isOpen ? Icons.storefront : Icons.storefront_outlined, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: color)),
                      Text(sub, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                ),
                if (st.storeSwitching)
                  const SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    ),
                  )
                else
                  Switch(
                    value: switchOn,
                    onChanged: (v) => _onSwitch(context, st, v),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Naye orders ka bara tile (0 ho to "koi naya order nahi").
class _NewOrdersTile extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _NewOrdersTile({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final has = count > 0;
    final c = has ? Colors.orange.shade800 : Colors.black45;
    return Card(
      color: has ? Colors.orange.shade50 : null,
      child: ListTile(
        onTap: onTap,
        leading: Badge(
          isLabelVisible: has,
          label: Text('$count'),
          child: Icon(Icons.notifications_active_outlined, color: c),
        ),
        title: Text(
          has ? '$count naye orders ka jawab dein' : 'Koi naya order nahi',
          style: TextStyle(fontWeight: FontWeight.w800, color: has ? Colors.orange.shade900 : null),
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _OrderChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final VoidCallback onTap;
  const _OrderChip({required this.label, required this.count, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          child: Column(
            children: [
              Text(numText(count), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color)),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductsCard extends StatelessWidget {
  final ProductsInfo products;
  final StockInfo stock;
  final VoidCallback onTap;
  const _ProductsCard({required this.products, required this.stock, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Mini(label: 'Live', value: products.approved, color: kTeal),
                  _Mini(label: 'Intezar', value: products.pending, color: Colors.amber.shade800),
                  _Mini(label: 'Reject', value: products.rejected, color: Colors.red.shade700),
                ],
              ),
              if (stock.low > 0 || stock.out > 0) ...[
                const Divider(height: 24),
                Row(
                  children: [
                    Icon(Icons.inventory_2_outlined, size: 18, color: Colors.red.shade700),
                    const SizedBox(width: 6),
                    Text(
                      [
                        if (stock.out > 0) '${stock.out} khatam',
                        if (stock.low > 0) '${stock.low} kam stock',
                      ].join('  •  '),
                      style: TextStyle(fontWeight: FontWeight.w800, color: Colors.red.shade700),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                for (final it in stock.items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        Text(it.out ? 'Khatam' : '${numText(it.stock)} bacha',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: it.out ? Colors.red.shade700 : Colors.amber.shade900)),
                      ],
                    ),
                  ),
              ] else if (products.total > 0) ...[
                const Divider(height: 24),
                Row(
                  children: [
                    const Icon(Icons.check_circle_outline, size: 18, color: kTeal),
                    const SizedBox(width: 6),
                    const Text('Stock theek hai', style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              ],
              if (products.total == 0) ...[
                const SizedBox(height: 8),
                const Text('Abhi koi product nahi - pehla product add karein.',
                    style: TextStyle(color: Colors.black54)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _Mini({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text(numText(value), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color)),
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
      );
}

class _Line extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? color;
  const _Line(this.label, this.value, {this.bold = false, this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: bold ? null : Colors.black54,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
            ),
            Text(value,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
                    fontSize: bold ? 17 : 14,
                    color: color)),
          ],
        ),
      );
}
