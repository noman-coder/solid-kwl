import 'dart:async';

import 'package:flutter/material.dart';

import '../models/order_detail.dart';
import '../models/orders.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/live_map.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';
import '../widgets/status_stepper.dart';
import 'orders.dart';

/// Orders list se kisi order par tap: poora detail screen kholo.
Future<void> openOrderDetail(BuildContext context, VendorOrder order) {
  final st = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: st, child: OrderDetailScreen(initial: order)),
  ));
}

/// Push notification (ya koi aur jagah jahan sirf order id ho) se seedha detail kholo.
Future<void> openOrderById(BuildContext context, AppState state, int orderId) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: OrderDetailScreen(orderId: orderId)),
  ));
}

/// Order ka poora detail: status stepper, live map (rider chal raha ho tab), rider, customer, items, payment,
/// commission ka andaza, history. Neeche action buttons (Qubool / Reject / Tayyar / Deliver).
class OrderDetailScreen extends StatefulWidget {
  /// Order list se aaye to card ka data (turant dikhta hai). Push se aaye to sirf [orderId].
  final VendorOrder? initial;
  final int? orderId;
  const OrderDetailScreen({super.key, this.initial, this.orderId})
      : assert(initial != null || orderId != null, 'initial ya orderId dena zaroori hai');

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> with WidgetsBindingObserver {
  static const Duration _trackEvery = Duration(seconds: 12);

  OrderDetail? _d;
  TrackData? _track;
  String? _error;
  bool _loading = true;
  bool _notFound = false;
  bool _trackOffline = false;
  bool _assigning = false;
  bool _disposed = false;
  Timer? _timer;
  int _ticks = 0;

  int get _id => widget.initial?.id ?? widget.orderId!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(silent: true);
    } else {
      _timer?.cancel(); // app background mein: battery / data bachao
      _timer = null;
    }
  }

  // ------------------------------------------------------------------ data

  Future<void> _load({bool silent = false}) async {
    final st = AppScope.read(context);
    if (!silent && _d == null && !_loading && mounted) setState(() => _loading = true);
    try {
      final d = await Api.orderDetail(_id);
      if (_disposed) return;
      setState(() {
        _d = d;
        _error = null;
        _notFound = false;
        _loading = false;
      });
      _syncTracking();
    } on ApiException catch (e) {
      if (_disposed) return;
      if (await st.handleApiError(e)) return;
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (e.code == 'not_found') {
          _notFound = true;
        } else {
          _error = e.message;
        }
      });
    }
  }

  /// Map sirf tab: rider assigned ho aur delivery chal rahi ho. Warna timer band, map hide.
  void _syncTracking() {
    final d = _d;
    if (d == null || !d.canTrack) {
      _timer?.cancel();
      _timer = null;
      if (_track != null || _trackOffline) {
        setState(() {
          _track = null;
          _trackOffline = false;
        });
      }
      return;
    }
    if (_timer == null) {
      _fetchTrack();
      _timer = Timer.periodic(_trackEvery, (_) => _tick());
    }
  }

  void _tick() {
    if (_disposed) return;
    _ticks++;
    _fetchTrack();
    if (_ticks % 3 == 0) _load(silent: true); // status bhi badalta rehta hai (rider ne maal utha liya...)
  }

  Future<void> _fetchTrack() async {
    final st = AppScope.read(context);
    try {
      final t = await Api.orderTrack(_id);
      if (_disposed) return;
      setState(() {
        _track = t;
        _trackOffline = false;
      });
      if (!t.active && t.reason == 'finished') _load(silent: true); // order khatam: stepper / map taza
    } on ApiException catch (e) {
      if (_disposed) return;
      if (await st.handleApiError(e)) return;
      if (mounted) setState(() => _trackOffline = true); // purani location dikhti rahe
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> _act(String action) async {
    final d = _d;
    if (d == null) return;
    final next = await runOrderAction(context, d.order, action);
    if (next != null && !_disposed) {
      await _load(silent: true);
    }
  }

  Future<void> _pickRider() async {
    final st = AppScope.read(context);
    final d = _d;
    if (d == null || _assigning) return;
    final riderId = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RiderSheet(orderId: _id, onApiError: st.handleApiError),
    );
    if (riderId == null || _disposed) return;
    setState(() => _assigning = true);
    try {
      final r = await Api.assignRider(_id, riderId);
      if (_disposed) return;
      setState(() {
        _d = r.detail;
        _assigning = false;
      });
      if (r.message.isNotEmpty) st.toast(r.message);
      _syncTracking();
      st.ordersChanged();
    } on ApiException catch (e) {
      if (_disposed) return;
      if (await st.handleApiError(e)) return;
      st.toast(e.message);
      setState(() => _assigning = false);
      _load(silent: true); // kisi aur ne pehle badal diya ho to taza haalat
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final d = _d;
    final o = d?.order ?? widget.initial; // push se khuli ho to load hone tak null
    final busy = st.orderBusy.contains(_id);

    Widget body;
    if (_notFound) {
      body = const EmptyState(
          icon: Icons.search_off, title: 'Order nahi mila', message: 'Ye order ab maujood nahi ya aap ka nahi hai.');
    } else if (d == null && _loading) {
      body = ListView(padding: const EdgeInsets.all(12), children: const [SkeletonList(count: 4, height: 120)]);
    } else if (d == null) {
      body = ListView(padding: const EdgeInsets.all(12), children: [
        NoticeCard(
          level: NoticeLevel.error,
          icon: Icons.cloud_off,
          text: _error ?? 'Order load nahi hua.',
          actionLabel: 'Dobara',
          onAction: _load,
        ),
      ]);
    } else {
      body = RefreshIndicator(
        onRefresh: () async {
          await _load(silent: true);
          if (_d?.canTrack == true) await _fetchTrack();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: NoticeCard(
                  level: NoticeLevel.warn,
                  icon: Icons.wifi_off,
                  text: 'Offline - purana data dikh raha hai.',
                  actionLabel: 'Dobara',
                  onAction: _load,
                ),
              ),
            _header(d),
            ..._mapSection(d),
            const SizedBox(height: 10),
            if (d.order.status != 'cancelled') ...[_riderCard(d), const SizedBox(height: 10)],
            _customerCard(d),
            const SizedBox(height: 10),
            _itemsCard(d),
            const SizedBox(height: 10),
            _paymentCard(d),
            if (d.timeline.isNotEmpty) ...[const SizedBox(height: 10), _timelineCard(d)],
          ],
        ),
      );
    }

    final canAct = d != null && d.order.actions.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(o != null ? '#${o.orderNo}' : 'Order'),
        actions: [
          IconButton(
            tooltip: 'Taza karein',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(silent: _d != null),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: canAct ? _actionBar(d!.order, busy) : null,
    );
  }

  // ------------------------------------------------------------------ sections

  Widget _card(String title, Widget child, {IconData? icon, Widget? trailing}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[Icon(icon, size: 20, color: kTeal), const SizedBox(width: 8)],
                Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _header(OrderDetail d) {
    final o = d.order;
    final sc = statusColor(o.status);
    final when = dateTimeText(o.createdAt);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(when.isEmpty ? 'Order' : '$when  (${agoText(o.createdAt)})',
                      style: const TextStyle(color: Colors.black54, fontSize: 12)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: sc.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                  child: Text(statusText(o), style: TextStyle(color: sc, fontWeight: FontWeight.w800, fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            StatusStepper(steps: d.steps),
            if (o.prepMinutes != null && o.tab == 'active' && o.status != 'cancelled')
              InfoLine(icon: Icons.timer_outlined, text: 'Tayyari ka time: ${o.prepMinutes} min'),
            if (o.status == 'cancelled' && o.rejectReason.isNotEmpty)
              InfoLine(icon: Icons.block, text: 'Wajah: ${o.rejectReason}', color: Colors.red.shade700),
            if (o.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: NoticeCard(level: NoticeLevel.info, icon: Icons.sticky_note_2_outlined, text: 'Note: ${o.notes}'),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _mapSection(OrderDetail d) {
    if (!d.canTrack) return const [];
    final t = _track;
    final gap = const SizedBox(height: 10);
    if (t == null) {
      return [gap, const SkeletonList(count: 1, height: 220)];
    }
    if (!t.active) return const []; // order khatam / rider hata: map khud chhup jata hai
    final store = t.store ?? d.storePoint;
    final dest = t.dest ?? d.customerPoint;
    final hasAny = store != null || dest != null || t.pos != null;
    final age = t.ageSec;
    final ageText = age == null ? '' : (age < 60 ? 'abhi abhi' : '${age ~/ 60} min pehle');
    return [
      gap,
      _card(
        'Live tracking',
        icon: Icons.my_location,
        trailing: ageText.isEmpty
            ? null
            : Text('Rider: $ageText',
                style: TextStyle(fontSize: 12, color: t.stale ? Colors.orange.shade800 : Colors.black54)),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!hasAny)
              const NoticeCard(icon: Icons.map_outlined, text: 'Map ke liye location abhi maujood nahi.')
            else
              LiveMap(store: store, customer: dest, rider: t.pos),
            if (t.pos == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: NoticeCard(icon: Icons.gps_not_fixed, text: 'Rider ki location abhi nahi mili. Thori der mein aayegi.'),
              )
            else if (t.stale)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: NoticeCard(
                    level: NoticeLevel.warn,
                    icon: Icons.signal_cellular_connected_no_internet_0_bar,
                    text: 'Rider ki location ruk gayi hai ($ageText). Call karke pooch lein.'),
              ),
            if (_trackOffline)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: NoticeCard(level: NoticeLevel.warn, icon: Icons.wifi_off, text: 'Net masla - purani location dikh rahi hai.'),
              ),
          ],
        ),
      ),
    ];
  }

  String _riderStatus(String s) {
    switch (s) {
      case 'assigned':
        return 'Store ki taraf aa raha hai';
      case 'picked_up':
        return 'Maal utha liya';
      case 'in_transit':
        return 'Customer ki taraf';
      case 'delivered':
        return 'Deliver kar diya';
      default:
        return '';
    }
  }

  Widget _riderCard(OrderDetail d) {
    final r = d.rider;
    final o = d.order;
    return _card(
      'Rider',
      icon: Icons.delivery_dining,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r == null)
            const Text('Rider abhi assign nahi hua.', style: TextStyle(color: Colors.black54))
          else
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name.isEmpty ? 'Rider' : r.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                      if (r.vehicle.isNotEmpty || _riderStatus(r.status).isNotEmpty)
                        Text(
                          [if (r.vehicle.isNotEmpty) r.vehicle, if (_riderStatus(r.status).isNotEmpty) _riderStatus(r.status)]
                              .join(' - '),
                          style: const TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                if (r.phone.isNotEmpty)
                  IconButton.filledTonal(
                    tooltip: 'Rider ko call',
                    icon: Icon(Icons.call, color: kTeal),
                    onPressed: () => openUrl('tel:${r.phone}'),
                  ),
              ],
            ),
          if (d.canAssignRider) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _assigning ? null : _pickRider,
                icon: _assigning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.two_wheeler),
                label: Text(r == null ? 'Rider dein' : 'Rider badlein'),
              ),
            ),
          ] else if (r == null && (o.status == 'pending' || o.status == 'confirmed' || o.status == 'processing'))
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Order "Tayyar" hone ke baad rider de sakte hain.',
                  style: TextStyle(color: Colors.black45, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Future<void> _openMap(OrderDetail d) async {
    final c = d.order.customer;
    final p = d.customerPoint;
    final q = p != null ? '${p.lat},${p.lng}' : Uri.encodeComponent(c.address);
    if (q.isEmpty) return;
    if (!await openUrl('https://www.google.com/maps/search/?api=1&query=$q')) {
      if (mounted) AppScope.read(context).toast('Map nahi khul saka.');
    }
  }

  Widget _customerCard(OrderDetail d) {
    final c = d.order.customer;
    final hasPlace = c.address.isNotEmpty || d.customerPoint != null;
    return _card(
      'Customer',
      icon: Icons.person_outline,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.name.isEmpty ? 'Customer' : c.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          if (c.phone.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 2), child: Text(c.phone, style: const TextStyle(color: Colors.black87))),
          if (c.address.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_on_outlined, size: 18, color: Colors.black54),
                  const SizedBox(width: 6),
                  Expanded(child: Text(c.address)),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (c.phone.isNotEmpty)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openUrl('tel:${c.phone}'),
                    icon: const Icon(Icons.call, size: 18),
                    label: const Text('Call'),
                  ),
                ),
              if (c.phone.isNotEmpty && d.whatsappUrl.isNotEmpty) const SizedBox(width: 8),
              if (d.whatsappUrl.isNotEmpty)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openUrl(d.whatsappUrl),
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('WhatsApp'),
                  ),
                ),
              if (hasPlace && (c.phone.isNotEmpty || d.whatsappUrl.isNotEmpty)) const SizedBox(width: 8),
              if (hasPlace)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openMap(d),
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text('Map'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _thumb(String? path) {
    final box = BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(10));
    if (path == null) {
      return Container(width: 48, height: 48, decoration: box, child: const Icon(Icons.inventory_2_outlined, color: Colors.black38));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        Api.absUrl(path),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            Container(width: 48, height: 48, decoration: box, child: const Icon(Icons.broken_image_outlined, color: Colors.black38)),
      ),
    );
  }

  Widget _itemsCard(OrderDetail d) {
    return _card(
      'Items (${d.items.length})',
      icon: Icons.shopping_basket_outlined,
      d.items.isEmpty
          ? const Text('Items nahi', style: TextStyle(color: Colors.black54))
          : Column(
              children: [
                for (var i = 0; i < d.items.length; i++) ...[
                  if (i > 0) const Divider(height: 18),
                  Row(
                    children: [
                      _thumb(d.items[i].image),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(d.items[i].name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text('${numText(d.items[i].qty)} x ${rs(d.items[i].price)}',
                                style: const TextStyle(color: Colors.black54, fontSize: 12)),
                          ],
                        ),
                      ),
                      Text(rs(d.items[i].total), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  Widget _kv(String k, String v, {bool bold = false, Color? color}) {
    final st = TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.w600, fontSize: bold ? 18 : 14, color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [Expanded(child: Text(k, style: st.copyWith(fontWeight: bold ? FontWeight.w800 : FontWeight.w500))), Text(v, style: st)]),
    );
  }

  Widget _paymentCard(OrderDetail d) {
    final o = d.order;
    final itemsTotal = d.items.fold<double>(0, (a, b) => a + b.total);
    final c = d.commission;
    return _card(
      'Payment',
      icon: Icons.payments_outlined,
      trailing: PayBadge(payment: o.payment),
      Column(
        children: [
          _kv('Items', rs(itemsTotal)),
          if (o.discount > 0) _kv(d.couponCode.isEmpty ? 'Discount' : 'Coupon (${d.couponCode})', '- ${rs(o.discount)}', color: Colors.green.shade700),
          if (o.deliveryFee > 0) _kv('Delivery fee', rs(o.deliveryFee)),
          const Divider(height: 18),
          _kv('Total', rs(o.total), bold: true, color: kTeal),
          if (o.payment.isCod && o.status != 'cancelled' && o.status != 'delivered')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: NoticeCard(icon: Icons.payments, text: 'COD: customer / rider se ${rs(o.total)} cash milna hai.'),
            ),
          const Divider(height: 22),
          _kv('Commission (${numText(c.percent)}%)', '- ${rs(c.amount)}', color: Colors.black54),
          _kv('Aap ko milega (andaza)', rs(c.vendorGets), bold: false, color: kTeal),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Ye andaza hai - asli hisaab bill banne par hota hai.', style: TextStyle(color: Colors.black45, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _timelineCard(OrderDetail d) {
    return _card(
      'History',
      icon: Icons.history,
      Column(
        children: [
          for (final t in d.timeline.reversed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 5, right: 10), child: Icon(Icons.circle, size: 9, color: kTeal)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (t.description.isNotEmpty) Text(t.description, style: const TextStyle(color: Colors.black54, fontSize: 12)),
                      ],
                    ),
                  ),
                  Text(dateTimeText(t.at), style: const TextStyle(color: Colors.black45, fontSize: 11)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ action bar

  Widget _spinner() => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white));

  Widget _actionBar(VendorOrder o, bool busy) {
    Widget child;
    if (o.can('accept') || o.can('reject')) {
      child = Row(
        children: [
          if (o.can('reject'))
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade700, side: BorderSide(color: Colors.red.shade200)),
                onPressed: busy ? null : () => _act('reject'),
                child: const Text('Reject'),
              ),
            ),
          if (o.can('reject') && o.can('accept')) const SizedBox(width: 10),
          if (o.can('accept'))
            Expanded(
              flex: 2,
              child: FilledButton(onPressed: busy ? null : () => _act('accept'), child: busy ? _spinner() : const Text('Qubool karein')),
            ),
        ],
      );
    } else if (o.can('ready')) {
      child = FilledButton.icon(
        onPressed: busy ? null : () => _act('ready'),
        icon: busy ? _spinner() : const Icon(Icons.inventory_2_outlined),
        label: const Text('Order tayyar hai'),
      );
    } else if (o.can('delivered')) {
      child = FilledButton.icon(
        onPressed: busy ? null : () => _act('delivered'),
        icon: busy ? _spinner() : const Icon(Icons.check_circle_outline),
        label: const Text('Deliver ho gaya'),
      );
    } else {
      return const SizedBox.shrink();
    }
    return Material(
      color: Colors.white,
      elevation: 8,
      child: SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 10), child: child)),
    );
  }
}

// ---------------------------------------------------------------- rider chunne ki sheet

class _RiderSheet extends StatefulWidget {
  final int orderId;
  final Future<bool> Function(ApiException e) onApiError;
  const _RiderSheet({required this.orderId, required this.onApiError});

  @override
  State<_RiderSheet> createState() => _RiderSheetState();
}

class _RiderSheetState extends State<_RiderSheet> {
  RiderList? _list;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await Api.riders(widget.orderId);
      if (!mounted) return;
      setState(() {
        _list = l;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (await widget.onApiError(e)) {
        if (mounted) Navigator.pop(context);
        return;
      }
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Rider chunein', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            if (_loading)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: NoticeCard(level: NoticeLevel.error, icon: Icons.cloud_off, text: _error!, actionLabel: 'Dobara', onAction: _load),
              )
            else if (l == null || l.riders.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: EmptyState(icon: Icons.two_wheeler, title: 'Koi rider maujood nahi', message: 'Admin se rider add karwayein.'),
              )
            else ...[
              if (!l.canAssign)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: NoticeCard(level: NoticeLevel.warn, text: 'Abhi rider nahi diya ja sakta (order Tayyar hona chahiye aur maal utha na ho).'),
                ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  itemCount: l.riders.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final r = l.riders[i];
                    final current = r.id == l.currentRiderId;
                    return ListTile(
                      enabled: l.canAssign && !current,
                      leading: CircleAvatar(
                        backgroundColor: (r.online ? Colors.green : Colors.grey).withValues(alpha: 0.15),
                        child: Icon(Icons.two_wheeler, color: r.online ? Colors.green.shade700 : Colors.grey),
                      ),
                      title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text([
                        r.online ? 'Online' : 'Offline',
                        if (r.vehicle.isNotEmpty) r.vehicle,
                        if (r.activeOrders > 0) '${r.activeOrders} order chal rahe',
                      ].join(' - ')),
                      trailing: current ? const Chip(label: Text('Abhi yehi')) : const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(ctx, r.id),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
