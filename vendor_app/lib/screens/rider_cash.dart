import 'package:flutter/material.dart';

import '../models/rider_cash.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/section_title.dart';
import '../widgets/skeleton.dart';

/// Phase V12: Rider se cash. Rider COD ka cash vendor ko deta hai aur app mein handover bhejta hai - yahan vendor
/// raqam gin kar Confirm ya (wajah ke saath) Reject karta hai. Confirm ke baghair rider ka balance nahi badalta.
/// Pull-to-refresh, skeleton, empty, error + retry, double-tap lock, purani history (infinite scroll).
class RiderCashScreen extends StatefulWidget {
  const RiderCashScreen({super.key});

  @override
  State<RiderCashScreen> createState() => _RiderCashScreenState();
}

/// More tab / dashboard / push se Rider cash screen kholo.
Future<void> openRiderCashScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const RiderCashScreen()),
  ));
}

class _RiderCashScreenState extends State<RiderCashScreen> {
  final ScrollController _scroll = ScrollController();
  CashSummary _summary = const CashSummary();
  List<CashHandover> _pending = [];
  List<CashHandover> _history = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loaded = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  final Set<int> _busy = <int>{}; // jin handovers par action chal raha hai (double-tap lock)
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _loadMore();
  }

  void _snack(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _expired() async {
    await AppScope.read(context).handleAuthExpired();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await Api.riderCash();
      if (!mounted || seq != _seq) return;
      setState(() {
        _summary = p.summary;
        _pending = p.pending;
        _history = p.history;
        _page = p.page;
        _hasMore = p.hasMore;
        _loaded = true;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      if (e.authExpired) {
        await _expired();
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || !_loaded) return;
    final seq = _seq;
    setState(() => _loadingMore = true);
    try {
      final p = await Api.riderCash(page: _page + 1);
      if (!mounted || seq != _seq) return;
      final have = _history.map((e) => e.id).toSet();
      setState(() {
        _history = [..._history, ...p.history.where((e) => !have.contains(e.id))];
        _page = p.page;
        _hasMore = p.hasMore;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _loadingMore = false);
      if (e.authExpired) {
        await _expired();
        return;
      }
      _snack(e.message);
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> _confirm(CashHandover h) async {
    if (_busy.contains(h.id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cash mil gaya?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rider ${h.rider.name} ne diya:'),
            const SizedBox(height: 6),
            Text(rs(h.amount), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: kTeal)),
            const SizedBox(height: 10),
            const Text(
              'Raqam apne haath mein gin kar hi confirm karein. Confirm ke baad rider ka hisaab kam ho jata hai.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Haan, mil gaya'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _decide(h, 'confirm');
  }

  Future<void> _reject(CashHandover h) async {
    if (_busy.contains(h.id)) return;
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RejectSheet(h: h),
    );
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    await _decide(h, 'reject', reason: reason.trim());
  }

  Future<void> _decide(CashHandover h, String action, {String? reason}) async {
    if (!_busy.add(h.id)) return;
    setState(() {});
    try {
      final r = await Api.riderCashAction(h.id, action, amount: h.amount, reason: reason);
      if (!mounted) return;
      setState(() {
        _pending = _pending.where((e) => e.id != h.id).toList();
        _history = [r.handover, ..._history.where((e) => e.id != h.id)];
        _summary = r.summary;
      });
      AppScope.read(context).cashChanged(); // dashboard ka cash badge
      _snack(r.message.isEmpty ? (action == 'confirm' ? 'Cash confirm ho gaya.' : 'Handover reject ho gaya.') : r.message);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await _expired();
        return;
      }
      _snack(e.message);
      // raqam badal gayi / pehle hi confirm-reject ho chuka / handover nahi mila: list purani thi
      if (e.code == 'changed' || e.code == 'handover' || e.code == 'not_found') _load();
    } catch (_) {
      if (mounted) _snack('Kuch masla aa gaya. Dobara koshish karein.');
    } finally {
      _busy.remove(h.id);
      if (mounted) setState(() {});
    }
  }

  // ------------------------------------------------------------------ build

  List<Widget> _content() {
    final out = <Widget>[];
    if (_error != null) {
      out
        ..add(NoticeCard(
          level: NoticeLevel.warn,
          icon: Icons.cloud_off_outlined,
          text: 'Taza data nahi aaya. Purana data dikh raha hai.',
          actionLabel: 'Dobara',
          onAction: _load,
        ))
        ..add(const SizedBox(height: 10));
    }
    out
      ..add(Row(
        children: [
          Expanded(
            child: _SumCard(
              label: 'Confirm baqi',
              value: rs(_summary.pendingAmount),
              sub: '${_summary.pendingCount} handover',
              color: Colors.amber.shade900,
              bg: Colors.amber.shade50,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _SumCard(
              label: 'Ab tak mila',
              value: rs(_summary.confirmedTotal),
              sub: '${_summary.confirmedCount} handover',
              color: kTeal,
              bg: kTeal.withValues(alpha: 0.08),
            ),
          ),
        ],
      ))
      ..add(const SectionTitle('Confirm karna baqi'));

    if (_pending.isEmpty) {
      out.add(const NoticeCard(
        icon: Icons.check_circle_outline,
        text: 'Koi cash confirm karna baqi nahi.',
      ));
    } else {
      for (final h in _pending) {
        out.add(_PendingCard(
          h: h,
          busy: _busy.contains(h.id),
          onConfirm: () => _confirm(h),
          onReject: () => _reject(h),
        ));
      }
    }

    out.add(const SectionTitle('Purani history'));
    if (_history.isEmpty) {
      out.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('Abhi koi confirm / reject hua handover nahi.', style: TextStyle(color: Colors.black54)),
      ));
    } else {
      for (final h in _history) {
        out.add(_HistoryTile(h: h));
      }
    }
    if (_loadingMore) {
      out.add(const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
      ));
    }
    out.add(const SizedBox(height: 24));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_loaded && _loading) {
      body = const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 4));
    } else if (!_loaded) {
      body = EmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'Load nahi ho saka',
        message: _error ?? 'Internet check karein.',
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Dobara koshish karein'),
        ),
      );
    } else if (_pending.isEmpty && _history.isEmpty && _error == null) {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 80),
            EmptyState(
              icon: Icons.payments_outlined,
              title: 'Abhi koi cash handover nahi',
              message: 'Rider COD ka cash dega to yahan confirm karne ke liye dikhega.',
            ),
          ],
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: _content(),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Rider se cash')),
      body: body,
    );
  }
}

class _SumCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color color;
  final Color bg;
  const _SumCard({required this.label, required this.value, required this.sub, required this.color, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 22)),
          ),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(color: Colors.black54, fontSize: 12)),
        ],
      ),
    );
  }
}

String _initial(String name) => name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();

class _PendingCard extends StatelessWidget {
  final CashHandover h;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onReject;
  const _PendingCard({required this.h, required this.busy, required this.onConfirm, required this.onReject});

  static const int _maxOrderChips = 6;

  @override
  Widget build(BuildContext context) {
    final shown = h.orders.take(_maxOrderChips).toList();
    final extra = h.orders.length - shown.length;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: kTeal.withValues(alpha: 0.12),
                  child: Text(_initial(h.rider.name),
                      style: const TextStyle(fontWeight: FontWeight.w900, color: kTeal)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Rider ${h.rider.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                      Text(agoText(h.createdAt), style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
                    ],
                  ),
                ),
                if (h.rider.phone.isNotEmpty)
                  IconButton(
                    tooltip: 'Rider ko call',
                    onPressed: () => openUrl('tel:${h.rider.phone}'),
                    icon: const Icon(Icons.call_outlined, color: kTeal),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(rs(h.amount), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: kTeal)),
            if (h.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Note: ${h.note}', style: const TextStyle(color: Colors.black54)),
            ],
            if (shown.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Kin orders ka cash:', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final o in shown)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(10)),
                      child: Text('${o.orderNo.isEmpty ? '#${o.id}' : o.orderNo}  •  ${rs(o.cash)}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  if (extra > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(10)),
                      child: Text('+$extra aur', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onReject,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: Colors.red.shade700,
                    ),
                    child: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : onConfirm,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                    child: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : const Text('Confirm'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final CashHandover h;
  const _HistoryTile({required this.h});

  @override
  Widget build(BuildContext context) {
    final ok = h.isConfirmed;
    final color = ok ? kTeal : Colors.red.shade700;
    final when = dateTimeText(h.decidedAt.isEmpty ? h.createdAt : h.decidedAt);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(ok ? Icons.check_rounded : Icons.close_rounded, color: color),
        ),
        title: Text('Rider ${h.rider.name}', style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          [
            ok ? 'Confirm' : 'Reject',
            if (when.isNotEmpty) when,
            if (!ok && h.rejectReason.isNotEmpty) 'Wajah: ${h.rejectReason}',
          ].join('  •  '),
          style: const TextStyle(fontSize: 12.5),
        ),
        trailing: Text(rs(h.amount),
            style: TextStyle(fontWeight: FontWeight.w800, color: ok ? Colors.black87 : Colors.black45,
                decoration: ok ? null : TextDecoration.lineThrough)),
      ),
    );
  }
}

/// Reject ki wajah (zaroori): chips ya apna text. Wapas wajah ka text deta hai.
class _RejectSheet extends StatefulWidget {
  final CashHandover h;
  const _RejectSheet({required this.h});

  @override
  State<_RejectSheet> createState() => _RejectSheetState();
}

class _RejectSheetState extends State<_RejectSheet> {
  final TextEditingController _c = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _pick(String r) {
    setState(() {
      _c.text = r;
      _c.selection = TextSelection.collapsed(offset: r.length);
      _err = null;
    });
  }

  void _submit() {
    final t = _c.text.trim();
    if (t.isEmpty) {
      setState(() => _err = 'Reject karne ki wajah likhein.');
      return;
    }
    Navigator.pop(context, t);
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reject: Rider ${h.rider.name} - ${rs(h.amount)}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Raqam rider ke paas hi rahegi. Wajah rider ko bheji jayegi.',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final r in kCashRejectReasons) ActionChip(label: Text(r), onPressed: () => _pick(r)),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _c,
              maxLength: 200,
              maxLines: 2,
              textInputAction: TextInputAction.done,
              onChanged: (_) {
                if (_err != null) setState(() => _err = null);
              },
              decoration: InputDecoration(
                labelText: 'Wajah',
                errorText: _err,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Colors.red.shade700,
              ),
              child: const Text('Reject karein'),
            ),
          ],
        ),
      ),
    );
  }
}
