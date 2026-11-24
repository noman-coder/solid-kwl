import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/orders.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';

/// Orders tab: search + 3 tabs (Naye / Chal rahe / Mukammal). Har order ka card, Qubool / Reject / Tayyar /
/// Deliver buttons. Pull-to-refresh, neeche scroll par agla page, skeleton, empty, error + retry.
/// Naya order aaye to list khud taza hoti hai (AppState ka poll) aur halki awaaz + vibration aati hai.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: kOrderTabs.length, vsync: this);
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final st = AppScope.read(context);
      st.activeOrderTab = kOrderTabs[_tabs.index];
      st.ensureOrders(st.activeOrderTab);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabs.removeListener(_onTab);
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onTab() {
    if (!mounted) return;
    final st = AppScope.read(context);
    final t = kOrderTabs[_tabs.index];
    st.activeOrderTab = t;
    st.ensureOrders(t);
  }

  void _goTab(String tab) {
    if (!mounted) return;
    final i = kOrderTabs.indexOf(tab);
    if (i >= 0 && i != _tabs.index) _tabs.animateTo(i);
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      AppScope.read(context).setOrdersQuery(v);
    });
    setState(() {}); // clear (X) button dikhane ke liye
  }

  void _clearSearch() {
    _search.clear();
    _debounce?.cancel();
    AppScope.read(context).setOrdersQuery('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final counts = st.orderCounts;
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: TextField(
            controller: _search,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Order no, customer ka naam ya phone',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.close), onPressed: _clearSearch),
              isDense: true,
              filled: true,
              fillColor: kBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Material(
          color: Colors.white,
          child: TabBar(
            controller: _tabs,
            labelColor: kTeal,
            unselectedLabelColor: Colors.black54,
            indicatorColor: kTeal,
            labelStyle: const TextStyle(fontWeight: FontWeight.w800),
            tabs: [
              for (final t in kOrderTabs)
                Tab(child: _TabLabel(label: kOrderTabLabels[t] ?? t, count: counts?[t], highlight: t == 'new')),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              for (final t in kOrderTabs) _OrdersList(tab: t, onMoved: _goTab),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabLabel extends StatelessWidget {
  final String label;
  final int? count;
  final bool highlight;
  const _TabLabel({required this.label, required this.count, required this.highlight});

  @override
  Widget build(BuildContext context) {
    final c = count ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (c > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: highlight ? Colors.orange.shade700 : Colors.black12,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              c > 999 ? '999+' : '$c',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: highlight ? Colors.white : Colors.black87,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Ek tab ki list (scroll position tab badalne par bhi bani rehti hai).
class _OrdersList extends StatefulWidget {
  final String tab;
  final void Function(String tab) onMoved;
  const _OrdersList({required this.tab, required this.onMoved});

  @override
  State<_OrdersList> createState() => _OrdersListState();
}

class _OrdersListState extends State<_OrdersList> with AutomaticKeepAliveClientMixin {
  final ScrollController _sc = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_sc.hasClients || !mounted) return;
    if (_sc.position.pixels > _sc.position.maxScrollExtent - 300) {
      AppScope.read(context).loadMoreOrders(widget.tab);
    }
  }

  ({String title, String message}) _emptyText(bool searching) {
    if (searching) {
      return (title: 'Koi order nahi mila', message: 'Doosra order no, naam ya phone try karein.');
    }
    switch (widget.tab) {
      case 'new':
        return (title: 'Koi naya order nahi', message: 'Naya order aate hi yahan nazar aayega.');
      case 'active':
        return (title: 'Koi order chal nahi raha', message: 'Qubool kiye hue orders yahan dikhenge.');
      default:
        return (title: 'Abhi koi mukammal order nahi', message: 'Deliver ya reject hue orders yahan dikhenge.');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final st = AppScope.of(context);
    final l = st.orderList(widget.tab);
    const physics = AlwaysScrollableScrollPhysics();

    Widget content;
    if (!l.loaded && l.error != null) {
      content = ListView(
        controller: _sc,
        physics: physics,
        padding: const EdgeInsets.all(12),
        children: [
          NoticeCard(
            level: NoticeLevel.error,
            icon: Icons.cloud_off,
            text: l.error!,
            actionLabel: 'Dobara',
            onAction: () => st.loadOrders(widget.tab),
          ),
        ],
      );
    } else if (!l.loaded) {
      content = ListView(
        controller: _sc,
        physics: physics,
        padding: const EdgeInsets.all(12),
        children: const [SkeletonList(count: 4, height: 150)],
      );
    } else if (l.orders.isEmpty) {
      final e = _emptyText(st.ordersQuery.isNotEmpty);
      content = ListView(
        controller: _sc,
        physics: physics,
        children: [
          SizedBox(
            height: 380,
            child: EmptyState(icon: Icons.receipt_long_outlined, title: e.title, message: e.message),
          ),
        ],
      );
    } else {
      final hasNotice = l.error != null;
      final count = l.orders.length + (hasNotice ? 1 : 0) + 1; // +1: neeche ka hissa
      content = ListView.builder(
        controller: _sc,
        physics: physics,
        padding: const EdgeInsets.all(12),
        itemCount: count,
        itemBuilder: (ctx, index) {
          var i = index;
          if (hasNotice) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: NoticeCard(
                  level: NoticeLevel.warn,
                  icon: Icons.wifi_off,
                  text: 'Offline - purana data dikh raha hai.',
                  actionLabel: 'Dobara',
                  onAction: () => st.loadOrders(widget.tab),
                ),
              );
            }
            i -= 1;
          }
          if (i < l.orders.length) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _OrderCard(order: l.orders[i], onMoved: widget.onMoved),
            );
          }
          if (l.loadingMore) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
            );
          }
          if (l.hasMore) {
            return TextButton(
              onPressed: () => st.loadMoreOrders(widget.tab),
              child: const Text('Aur orders dikhayein'),
            );
          }
          return const SizedBox(height: 40);
        },
      );
    }

    return RefreshIndicator(onRefresh: () => st.loadOrders(widget.tab), child: content);
  }
}

// ---------------------------------------------------------------- order card

Color _statusColor(String status) {
  switch (status) {
    case 'pending':
      return Colors.orange.shade800;
    case 'confirmed':
    case 'processing':
      return Colors.blue.shade700;
    case 'ready':
      return Colors.indigo.shade600;
    case 'partially_delivered':
      return Colors.teal.shade700;
    case 'delivered':
    case 'invoiced':
      return kTeal;
    case 'cancelled':
      return Colors.red.shade700;
    default:
      return Colors.black54;
  }
}

String _statusText(VendorOrder o) {
  switch (o.status) {
    case 'pending':
      return 'Naya';
    case 'confirmed':
      return 'Qubool';
    case 'processing':
      return 'Tayyari mein';
    case 'ready':
      return 'Tayyar';
    case 'partially_delivered':
      return 'Aadha deliver';
    case 'delivered':
    case 'invoiced':
      return 'Deliver';
    case 'cancelled':
      return 'Reject';
    default:
      return o.statusLabel;
  }
}

class _OrderCard extends StatelessWidget {
  final VendorOrder order;
  final void Function(String tab) onMoved;
  const _OrderCard({required this.order, required this.onMoved});

  Future<void> _accept(BuildContext context) async {
    final st = AppScope.read(context);
    final res = await showModalBottomSheet<_AcceptResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AcceptSheet(order: order, options: st.prepOptions),
    );
    if (res == null) return;
    final next = await st.orderAction(order, 'accept', prepMinutes: res.minutes);
    if (next != null) onMoved(next);
  }

  Future<void> _reject(BuildContext context) async {
    final st = AppScope.read(context);
    final res = await showModalBottomSheet<_RejectResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RejectSheet(order: order, reasons: st.rejectReasons),
    );
    if (res == null) return;
    final next = await st.orderAction(order, 'reject', reasonCode: res.code, reasonNote: res.note);
    if (next != null) onMoved(next);
  }

  Future<void> _ready(BuildContext context) async {
    final st = AppScope.read(context);
    final next = await st.orderAction(order, 'ready');
    if (next != null) onMoved(next);
  }

  Future<void> _delivered(BuildContext context) async {
    final st = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Order deliver ho gaya?'),
        content: Text(
          '#${order.orderNo} - ${rs(order.total)}'
          '${order.payment.isCod ? '\nCOD: customer se ${rs(order.total)} cash mil gaya?' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Haan, deliver'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final next = await st.orderAction(order, 'delivered');
    if (next != null) onMoved(next);
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final busy = st.orderBusy.contains(order.id);
    final o = order;
    final when = o.tab == 'done'
        ? dateTimeText(o.createdAt)
        : '${agoText(o.createdAt)} (${clockText(o.createdAt)})';
    final sc = _statusColor(o.status);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: o.isNew ? Colors.orange.shade400 : kBorder, width: o.isNew ? 1.5 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('#${o.orderNo}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: sc.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(_statusText(o),
                      style: TextStyle(color: sc, fontWeight: FontWeight.w800, fontSize: 12)),
                ),
              ],
            ),
            if (when.trim().isNotEmpty && when != ' ()')
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(when, style: const TextStyle(color: Colors.black54, fontSize: 12)),
              ),
            const Divider(height: 20),
            // ---- customer
            Row(
              children: [
                const Icon(Icons.person_outline, size: 18, color: Colors.black54),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    o.customer.name.isEmpty ? 'Customer' : o.customer.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (o.customer.phone.isNotEmpty)
                  IconButton(
                    tooltip: 'Call karein',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.call, color: kTeal),
                    onPressed: () => openUrl('tel:${o.customer.phone}'),
                  ),
              ],
            ),
            if (o.customer.address.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.location_on_outlined, size: 18, color: Colors.black54),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(o.customer.address,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black87)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            // ---- items
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final it in o.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Text(it.line, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  if (o.itemsMore > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('+${o.itemsMore} aur items',
                          style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w600)),
                    ),
                  if (o.items.isEmpty) const Text('Items nahi', style: TextStyle(color: Colors.black54)),
                ],
              ),
            ),
            if (o.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: NoticeCard(level: NoticeLevel.info, icon: Icons.sticky_note_2_outlined, text: 'Note: ${o.notes}'),
              ),
            const SizedBox(height: 10),
            // ---- payment + total
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _PayBadge(payment: o.payment),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Items ${rs(o.subtotal)}'
                    '${o.deliveryFee > 0 ? ' + delivery ${rs(o.deliveryFee)}' : ''}'
                    '${o.discount > 0 ? ' (discount ${rs(o.discount)} ke baad)' : ''}',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ),
                Text(rs(o.total), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: kTeal)),
              ],
            ),
            // ---- haalat ki tafseel
            if (o.prepMinutes != null && o.status != 'cancelled' && o.tab == 'active')
              _InfoLine(icon: Icons.timer_outlined, text: 'Tayyari ka time: ${o.prepMinutes} min'),
            if (o.status == 'cancelled' && o.rejectReason.isNotEmpty)
              _InfoLine(icon: Icons.block, text: 'Wajah: ${o.rejectReason}', color: Colors.red.shade700),
            if (o.delivery != null && o.delivery!.riderName.isNotEmpty)
              _InfoLine(
                icon: Icons.delivery_dining,
                text: 'Rider: ${o.delivery!.riderName}',
                trailing: o.delivery!.riderPhone.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Rider ko call',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.call, color: kTeal, size: 20),
                        onPressed: () => openUrl('tel:${o.delivery!.riderPhone}'),
                      ),
              ),
            // ---- buttons
            if (o.actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buttons(context, busy),
            ],
          ],
        ),
      ),
    );
  }

  Widget _spinner() => const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
      );

  Widget _buttons(BuildContext context, bool busy) {
    final o = order;
    if (o.can('accept') || o.can('reject')) {
      return Row(
        children: [
          if (o.can('reject'))
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade700,
                  side: BorderSide(color: Colors.red.shade200),
                ),
                onPressed: busy ? null : () => _reject(context),
                child: const Text('Reject'),
              ),
            ),
          if (o.can('reject') && o.can('accept')) const SizedBox(width: 10),
          if (o.can('accept'))
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: busy ? null : () => _accept(context),
                child: busy ? _spinner() : const Text('Qubool karein'),
              ),
            ),
        ],
      );
    }
    if (o.can('ready')) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: busy ? null : () => _ready(context),
          icon: busy ? _spinner() : const Icon(Icons.inventory_2_outlined),
          label: const Text('Order tayyar hai'),
        ),
      );
    }
    if (o.can('delivered')) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: busy ? null : () => _delivered(context),
          icon: busy ? _spinner() : const Icon(Icons.check_circle_outline),
          label: const Text('Deliver ho gaya'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _PayBadge extends StatelessWidget {
  final OrderPayment payment;
  const _PayBadge({required this.payment});

  @override
  Widget build(BuildContext context) {
    final c = payment.isCod ? Colors.orange.shade800 : Colors.green.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(payment.label, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  final Widget? trailing;
  const _InfoLine({required this.icon, required this.text, this.color, this.trailing});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.black87;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(color: c, fontWeight: FontWeight.w600))),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- accept sheet

class _AcceptResult {
  final int? minutes; // null = bina time ke qubool
  const _AcceptResult(this.minutes);
}

/// Qubool karte waqt tayyari ka time: chips (10/20/30/45) ya apna time (1-600 minute).
class _AcceptSheet extends StatefulWidget {
  final VendorOrder order;
  final List<int> options;
  const _AcceptSheet({required this.order, required this.options});

  @override
  State<_AcceptSheet> createState() => _AcceptSheetState();
}

class _AcceptSheetState extends State<_AcceptSheet> {
  final TextEditingController _custom = TextEditingController();
  int? _selected;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.options.contains(20)) _selected = 20;
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _submit() {
    int? minutes = _selected;
    final c = _custom.text.trim();
    if (c.isNotEmpty) {
      final v = int.tryParse(c);
      if (v == null || v < 1 || v > 600) {
        setState(() => _error = '1 se 600 minute ke beech likhein');
        return;
      }
      minutes = v;
    }
    Navigator.pop(context, _AcceptResult(minutes));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Order #${widget.order.orderNo} qubool karein',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Tayyari mein kitna time lagega? Customer ko bata diya jayega.',
              style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in widget.options)
                ChoiceChip(
                  label: Text('$m min'),
                  selected: _selected == m && _custom.text.trim().isEmpty,
                  onSelected: (_) => setState(() {
                    _selected = _selected == m ? null : m;
                    _custom.clear();
                    _error = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _custom,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 3,
            onChanged: (_) => setState(() {
              _selected = null;
              _error = null;
            }),
            decoration: InputDecoration(
              labelText: 'Ya apna time (minute)',
              errorText: _error,
              counterText: '',
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.check),
              label: const Text('Qubool karein'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- reject sheet

class _RejectResult {
  final String code;
  final String note;
  const _RejectResult(this.code, this.note);
}

/// Reject karne ki wajah (zaroori). "Doosri wajah" par note likhna zaroori.
class _RejectSheet extends StatefulWidget {
  final VendorOrder order;
  final List<RejectReason> reasons;
  const _RejectSheet({required this.order, required this.reasons});

  @override
  State<_RejectSheet> createState() => _RejectSheetState();
}

class _RejectSheetState extends State<_RejectSheet> {
  final TextEditingController _note = TextEditingController();
  String? _code;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code;
    if (code == null) {
      setState(() => _error = 'Reject karne ki wajah chunein');
      return;
    }
    final note = _note.text.trim();
    if (code == 'other' && note.isEmpty) {
      setState(() => _error = '"Doosri wajah" par wajah likhna zaroori hai');
      return;
    }
    Navigator.pop(context, _RejectResult(code, note));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final isOther = _code == 'other';
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Order #${widget.order.orderNo} reject karein',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Customer ko wajah bata di jayegi.', style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 8),
          for (final r in widget.reasons)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                _code == r.code ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: _code == r.code ? Colors.red.shade700 : Colors.black45,
              ),
              title: Text(r.label),
              onTap: () => setState(() {
                _code = r.code;
                _error = null;
              }),
            ),
          const SizedBox(height: 6),
          TextField(
            controller: _note,
            maxLength: 120,
            minLines: 1,
            maxLines: 3,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: isOther ? 'Wajah likhein (zaroori)' : 'Note (optional)',
              isDense: true,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              onPressed: _submit,
              icon: const Icon(Icons.block),
              label: const Text('Reject karein'),
            ),
          ),
        ],
      ),
    );
  }
}
