import 'package:flutter/material.dart';

import '../models/order.dart';
import '../models/order_detail.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/deliver_dialog.dart';
import '../widgets/loading.dart';
import '../widgets/notice_card.dart';
import '../widgets/section_title.dart';
import '../widgets/status_stepper.dart';

/// Order detail kholo. offer = true ho to ye abhi accept nahi hua (server se detail nahi aati,
/// list ka data hi dikhta hai).
Future<void> openOrderDetail(BuildContext context, AppState st,
    {required int id, RiderOrder? initial, bool offer = false}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(
      state: st,
      child: OrderDetailScreen(id: id, initial: initial, offer: offer),
    ),
  ));
}

class OrderDetailScreen extends StatefulWidget {
  final int id;
  final RiderOrder? initial;
  final bool offer;
  const OrderDetailScreen({super.key, required this.id, this.initial, this.offer = false});

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  OrderDetail? _detail;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.offer) Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await Api.orderDetail(widget.id);
      final o = asMap(d['order']);
      if (!mounted) return;
      setState(() => _detail = OrderDetail.fromJson(o));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        final st = AppScope.of(context);
        Navigator.of(context).popUntil((r) => r.isFirst);
        await st.onLogout();
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  RiderOrder? get _order => _detail?.order ?? widget.initial;

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final o = _order;
    return Scaffold(
      appBar: AppBar(title: Text(o == null ? 'Order' : 'Order #${o.orderNo}')),
      body: o == null
          ? (_error != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: NoticeCard(
                      level: NoticeLevel.error,
                      text: _error!,
                      actionLabel: 'Dobara',
                      onAction: _load))
              : const Loading())
          : RefreshIndicator(
              onRefresh: widget.offer ? () async {} : _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: _body(st, o),
              ),
            ),
      bottomNavigationBar: o == null ? null : _bottomBar(st, o),
    );
  }

  List<Widget> _body(AppState st, RiderOrder o) {
    final d = _detail;
    return [
      if (_error != null) ...[
        NoticeCard(level: NoticeLevel.error, icon: Icons.wifi_off, text: _error!),
        const SizedBox(height: 10),
      ],
      if (_loading && d == null && !widget.offer) const LinearProgressIndicator(),
      _PaymentBanner(order: o, detail: d),
      if (d != null) ...[
        const SizedBox(height: 12),
        if (d.isCancelled)
          const NoticeCard(level: NoticeLevel.error, icon: Icons.cancel_outlined, text: 'Ye order cancel ho gaya.')
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
              child: StatusStepper(steps: d.steps),
            ),
          ),
      ],
      const SectionTitle('Store (maal yahan se uthana hai)'),
      _PlaceCard(icon: Icons.store, place: o.store),
      const SectionTitle('Customer'),
      _PlaceCard(icon: Icons.home, place: o.customer),
      const SectionTitle('Items'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              for (final i in o.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(i.name)),
                      Text('× ${numText(i.qty)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              if (o.items.isEmpty) const Text('—'),
              const Divider(height: 22),
              _Row('Order total', rs(o.total)),
              _Row(d != null && d.isDelivered ? 'Aap ki kamai' : 'Delivery fee (aap ki)', rs(o.fee)),
            ],
          ),
        ),
      ),
      if (d != null && d.timeline.isNotEmpty) ...[
        const SectionTitle('Order ki history'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                for (final t in d.timeline)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Icon(Icons.circle, size: 10, color: kGreen),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                              if (t.description.isNotEmpty)
                                Text(t.description, style: const TextStyle(fontSize: 12.5)),
                              Text(fmtDateTime(t.at),
                                  style: const TextStyle(fontSize: 11, color: Colors.black54)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: 24),
    ];
  }

  Widget? _bottomBar(AppState st, RiderOrder o) {
    final d = _detail;
    String? status = widget.offer ? 'offer' : (d?.deliveryStatus ?? widget.initial?.status);
    if (status == null || status == 'delivered' || status == 'cancelled') return null;

    Place target = o.store;
    Widget action;
    if (status == 'offer') {
      final blocked = st.cashLimitReached;
      action = FilledButton(
        onPressed: (st.busy || blocked) ? null : _accept,
        child: Text('Accept (${rs(o.fee)})'),
      );
    } else if (status == 'assigned') {
      action = FilledButton(
        onPressed: st.busy ? null : _pickup,
        child: const Text('📦 Maal le liya'),
      );
    } else {
      target = o.customer;
      action = FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
        onPressed: st.busy ? null : _deliver,
        child: const Text('🎉 Deliver kar diya'),
      );
    }

    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: kBorder)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status == 'offer' && st.cashLimitReached)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Cash hadd poori hai - naya order lene se pehle handover karein.',
                    style: TextStyle(color: Colors.red, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    if (!await openUrl(target.mapUrl)) st.toast('Map khul nahi saka');
                  },
                  icon: const Icon(Icons.navigation),
                  label: const Text('Navigate'),
                ),
                const SizedBox(width: 10),
                Expanded(child: action),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _accept() async {
    final st = AppScope.of(context);
    final ok = await st.accept(_order!);
    if (!mounted) return;
    if (ok) {
      st.goTab(1, ordersSub: 1); // Active tab
      Navigator.of(context).pop();
    }
  }

  Future<void> _pickup() async {
    final st = AppScope.of(context);
    final ok = await st.pickup(_order!);
    if (ok && mounted) await _load();
  }

  Future<void> _deliver() async {
    final st = AppScope.of(context);
    if (!await confirmDeliver(context, _order!)) return;
    final ok = await st.deliver(_order!);
    if (ok && mounted) await _load();
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.black54))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      );
}

/// COD ho to "cash lein" ka bara banner, Paid ho to "cash na lein".
class _PaymentBanner extends StatelessWidget {
  final RiderOrder order;
  final OrderDetail? detail;
  const _PaymentBanner({required this.order, required this.detail});

  @override
  Widget build(BuildContext context) {
    final delivered = detail?.isDelivered == true;
    late final Color bg;
    late final Color fg;
    late final IconData icon;
    late final String text;
    if (order.isCod) {
      bg = Colors.amber.shade100;
      fg = Colors.amber.shade900;
      icon = Icons.payments;
      text = delivered
          ? 'COD: Customer se ${rs(detail!.cashCollected)} cash liya gaya'
          : 'COD: Customer se ${rs(order.total)} cash lein';
    } else {
      bg = Colors.green.shade100;
      fg = Colors.green.shade900;
      icon = Icons.verified;
      text = 'Online paid - customer se cash nahi lena';
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 28),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text, style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w800))),
        ],
      ),
    );
  }
}

/// Store / customer ka card: naam, pata, aur Call / WhatsApp / Map buttons.
class _PlaceCard extends StatelessWidget {
  final IconData icon;
  final Place place;
  const _PlaceCard({required this.icon, required this.place});

  Future<void> _open(AppState st, String url) async {
    if (!await openUrl(url)) st.toast('Ye link khul nahi saka');
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: Colors.black54),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (place.name.isNotEmpty)
                        Text(place.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      Text(place.address.isEmpty ? 'Pata nahi likha' : place.address),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _open(st, place.mapUrl),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: const Text('Map'),
                ),
                if (place.phone.isNotEmpty) ...[
                  OutlinedButton.icon(
                    onPressed: () => _open(st, 'tel:${place.phone}'),
                    icon: const Icon(Icons.call, size: 18),
                    label: const Text('Call'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _open(st, waUrl(place.phone)),
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('WhatsApp'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
