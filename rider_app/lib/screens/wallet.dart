import 'dart:async';

import 'package:flutter/material.dart';

import '../models/dashboard.dart';
import '../models/wallet.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/skeleton.dart';
import '../widgets/notice_card.dart';
import '../widgets/section_title.dart';
import '../widgets/stat_card.dart';
import 'handover.dart';

/// Wallet tab (Phase 7): cash in hand, kamai (due), cash handover (Admin / Vendor),
/// handover history (pending / confirmed / rejected), vendor-wise cash, kamai aur ada'egi.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  AppState? _st;
  WalletData? _w;
  bool _loading = false;
  String? _error;
  int _lastTab = -1;
  int _lastVer = -1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Pending handover ho to tab khula rehne par har 20 sec mein status dekho (receiver ne confirm kiya?)
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_st?.tab == 3 && (_w?.hasPending ?? false)) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final st = AppScope.of(context);
    _st = st;
    final tab = st.tab;
    final ver = st.historyVersion; // deliver hone par badhta hai - cash badal gaya
    final reload = tab == 3 && (_lastTab != 3 || ver != _lastVer);
    _lastTab = tab;
    _lastVer = ver;
    if (reload) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (_loading) return;
    _loading = true;
    if (!silent && mounted) setState(() {});
    try {
      final d = await Api.wallet();
      if (!mounted) return;
      _w = WalletData.fromJson(d);
      _error = null;
    } on ApiException catch (e) {
      if (e.authExpired) {
        await _st?.onLogout();
        return;
      }
      if (!silent) _error = e.message;
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _handover() async {
    final st = _st;
    final w = _w;
    if (st == null || w == null) return;
    final done = await openHandover(context, st, w);
    if (done == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final w = _w;

    Widget body;
    if (w == null && _loading) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: const [SkeletonList(count: 4)],
      );
    } else if (w == null) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          const SizedBox(height: 60),
          if (_error != null)
            NoticeCard(level: NoticeLevel.error, icon: Icons.cloud_off, text: _error!)
          else
            const EmptyState(icon: Icons.account_balance_wallet_rounded, title: 'Wallet'),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Dobara koshish'),
            ),
          ),
        ],
      );
    } else {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: _content(st, w),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await _load();
        await st.refresh(withDashboard: true);
      },
      child: body,
    );
  }

  List<Widget> _content(AppState st, WalletData w) {
    final d = st.dashboard;
    final pct = w.cashLimit > 0 ? (w.cashInHand / w.cashLimit).clamp(0.0, 1.0) : 0.0;
    final barColor = w.limitReached
        ? Colors.red.shade600
        : (pct >= 0.8 ? Colors.amber.shade700 : kGreen);

    return [
      if (_error != null) ...[
        NoticeCard(level: NoticeLevel.error, icon: Icons.cloud_off, text: _error!),
        const SizedBox(height: 10),
      ],
      if (w.limitReached) ...[
        NoticeCard(
          level: NoticeLevel.error,
          text: 'Cash ${rs(w.cashInHand)} ho gaya (hadd ${rs(w.cashLimit)}). Naya order lene se pehle handover karein.',
        ),
        const SizedBox(height: 10),
      ],
      // ---- Cash in hand ----
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.payments_rounded, color: barColor),
                  const SizedBox(width: 8),
                  const Text('Cash in hand (COD)',
                      style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black54)),
                ],
              ),
              const SizedBox(height: 6),
              Text(rs(w.cashInHand), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
              if (w.cashLimit > 0) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 8,
                    color: barColor,
                    backgroundColor: Colors.grey.shade200,
                  ),
                ),
                const SizedBox(height: 4),
                Text('Hadd ${rs(w.cashLimit)}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
              if (w.pendingHandover > 0) ...[
                const SizedBox(height: 8),
                Text('${rs(w.pendingHandover)} receiver ke confirm ka intezar kar raha hai',
                    style: TextStyle(color: Colors.amber.shade900, fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: w.canHandover ? _handover : null,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: Text(w.canHandover ? 'Cash handover (Admin / Vendor)' : 'Handover ke liye cash nahi'),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      // ---- Kamai ----
      Row(
        children: [
          Expanded(
            child: StatCard(
              icon: Icons.account_balance_wallet_rounded,
              label: 'Kamai milni hai (due)',
              value: rs(w.due),
              color: Colors.blue.shade700,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StatCard(
              icon: Icons.verified_rounded,
              label: 'Ab tak mil chuki',
              value: rs(w.paidOut),
              color: kGreen,
            ),
          ),
        ],
      ),
      if (d != null) ...[
        const SectionTitle('Kamai (delivery fee)'),
        _earningsCard(d),
      ],
      // ---- Handovers ----
      const SectionTitle('Mere handovers'),
      if (w.handovers.isEmpty)
        const _Hint('Abhi koi handover nahi. Cash dene par yahan status dikhega.')
      else
        for (final h in w.handovers)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: _HandoverTile(h: h)),
      // ---- Vendor-wise ----
      if (w.vendorWise.isNotEmpty) ...[
        const SectionTitle('Vendor-wise cash'),
        for (final v in w.vendorWise)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: _VendorTile(v: v)),
      ],
      // ---- Hisab ki history ----
      const SectionTitle('Hisab ki history'),
      if (w.settlements.isEmpty)
        const _Hint('Abhi koi entry nahi.')
      else
        for (final x in w.settlements)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: _SettlementTile(x: x)),
      const SizedBox(height: 40),
    ];
  }

  Widget _earningsCard(DashboardData d) {
    Widget row(String label, PeriodStat p) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Text('${p.deliveries} deliveries',
                  style: const TextStyle(color: Colors.black54, fontSize: 13)),
              const SizedBox(width: 14),
              SizedBox(
                width: 92,
                child: Text(rs(p.earned),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          children: [
            row('Aaj', d.today),
            const Divider(height: 1),
            row('Is hafta', d.week),
            const Divider(height: 1),
            row('Is mahina', d.month),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(text, style: const TextStyle(color: Colors.black54)),
      );
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
      );
}

class _HandoverTile extends StatelessWidget {
  final Handover h;
  const _HandoverTile({required this.h});

  @override
  Widget build(BuildContext context) {
    final Color c;
    final String label;
    if (h.isConfirmed) {
      c = kGreen;
      label = 'Confirm';
    } else if (h.isRejected) {
      c = Colors.red.shade600;
      label = 'Reject';
    } else {
      c = Colors.amber.shade800;
      label = 'Pending';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(h.receiver == 'vendor' ? Icons.storefront_outlined : Icons.admin_panel_settings_outlined,
                    size: 20, color: Colors.black54),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(h.toWhom,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                _Chip(label, c),
              ],
            ),
            const SizedBox(height: 6),
            Text(rs(h.amount), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(
              h.isPending || h.decidedAt.isEmpty
                  ? fmtDateTime(h.createdAt)
                  : '${fmtDateTime(h.createdAt)}  →  ${fmtDateTime(h.decidedAt)}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            if (h.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Note: ${h.note}', style: const TextStyle(fontSize: 13)),
              ),
            if (h.isRejected) ...[
              const SizedBox(height: 8),
              NoticeCard(
                level: NoticeLevel.error,
                icon: Icons.info_outline,
                text: h.rejectReason.isEmpty
                    ? 'Receiver ne reject kiya. Raqam aap ke paas hi hai.'
                    : 'Wajah: ${h.rejectReason}\nRaqam aap ke paas hi hai.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VendorTile extends StatelessWidget {
  final VendorCash v;
  const _VendorTile({required this.v});

  @override
  Widget build(BuildContext context) {
    Widget kv(String k, double val, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(k, style: const TextStyle(fontSize: 11, color: Colors.black54)),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(rs(val),
                    style: TextStyle(fontWeight: FontWeight.w800, color: color)),
              ),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${v.title}  •  ${v.orders} orders',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Row(
              children: [
                kv('Collect hua', v.collected),
                kv('Vendor ko diya', v.handedToVendor),
                kv('Baqi', v.balance, color: v.balance > 0 ? Colors.red.shade700 : kGreen),
              ],
            ),
            if (v.pendingToVendor > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('${rs(v.pendingToVendor)} pending confirm',
                    style: TextStyle(fontSize: 12, color: Colors.amber.shade900)),
              ),
          ],
        ),
      ),
    );
  }
}

class _SettlementTile extends StatelessWidget {
  final SettlementRow x;
  const _SettlementTile({required this.x});

  @override
  Widget build(BuildContext context) {
    final payout = x.isPayout;
    final c = payout ? Colors.blue.shade700 : kGreen;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: c.withValues(alpha: 0.13),
          child: Icon(payout ? Icons.south_west_rounded : Icons.north_east_rounded, color: c, size: 20),
        ),
        title: Text(payout ? 'Kamai ada ki gayi' : 'Cash jama hua',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          [fmtDateTime(x.createdAt), if (x.note.isNotEmpty) x.note].where((e) => e.isNotEmpty).join('  •  '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(rs(x.amount), style: TextStyle(fontWeight: FontWeight.w900, color: c)),
      ),
    );
  }
}
