import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/orders.dart';
import '../models/sales.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/sales_charts.dart';
import '../widgets/section_title.dart';
import '../widgets/skeleton.dart';
import '../widgets/stat_card.dart';
import 'order_detail.dart';
import 'orders.dart' show PayBadge, statusColor, statusText;

/// Negative paison ke liye: -50 -> "-Rs 50".
String rsSigned(double v) => v < 0 ? '-Rs ${numText(-v)}' : rs(v);

/// Phase V11: Sales tab. Muddat (Aaj / 7 din / 30 din / tareekh chunein), summary cards, chart, Cash vs Online,
/// profit (kharid rate wale products par), commission ka tafseeli hisaab, top / kam chalne wale products,
/// statement aur export (share). Numbers par tap karke un ke orders khulte hain.
/// Pull-to-refresh, skeleton, error + retry, net na ho to purana data + "offline" message.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  SalesRange _range = const SalesRange('week');
  SalesData? _data;
  bool _loading = false;
  bool _stale = false;
  String? _error;
  int _seq = 0;

  int _lastTab = -1;
  DateTime? _loadedAt;
  static const int _tabIndex = 3;

  @override
  void initState() {
    super.initState();
    _load(useCache: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Sales tab par wapas aayein aur data 1 minute se purana ho to chupke se taza kar lo
    final tab = AppScope.of(context).tab;
    final old = _loadedAt;
    if (tab == _tabIndex && _lastTab != _tabIndex && old != null && !_loading &&
        DateTime.now().difference(old) > const Duration(seconds: 60)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    _lastTab = tab;
  }

  Future<void> _load({bool useCache = false}) async {
    final seq = ++_seq;
    final range = _range;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (useCache) {
      final c = await Api.cachedSales(range);
      if (!mounted || seq != _seq) return;
      if (c != null && _data == null) {
        setState(() {
          _data = c;
          _stale = true;
        });
      }
    }
    try {
      final d = await Api.sales(range);
      if (!mounted || seq != _seq) return;
      _loadedAt = DateTime.now();
      setState(() {
        _data = d;
        _stale = false;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      if (await AppScope.read(context).handleApiError(e)) return;
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        if (e.code == 'network') {
          _stale = _data != null;
          _error = _data == null ? e.message : null;
        } else {
          _error = e.message; // jaise ghalat tareekh
        }
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  void _pick(String period) {
    if (period == 'custom') {
      _pickCustom();
      return;
    }
    if (_range.period == period) return;
    HapticFeedback.selectionClick();
    setState(() {
      _range = SalesRange(period);
      _data = null; // purani muddat ka data naye label ke neeche na dikhe
      _stale = false;
    });
    _load(useCache: true);
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTimeRange? initial;
    if (_range.isCustom && _range.from != null && _range.to != null) {
      final a = DateTime.tryParse(_range.from!);
      final b = DateTime.tryParse(_range.to!);
      if (a != null && b != null) initial = DateTimeRange(start: a, end: b);
    }
    initial ??= DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
    final r = await showDateRangePicker(
      context: context,
      firstDate: today.subtract(const Duration(days: 365 * 3)),
      lastDate: today,
      initialDateRange: initial,
      helpText: 'Muddat chunein',
      saveText: 'Theek hai',
      cancelText: 'Wapas',
    );
    if (r == null || !mounted) return;
    if (r.end.difference(r.start).inDays + 1 > 366) {
      _snack('Zyada se zyada 1 saal ka hisaab ek baar mein dekh sakte hain.');
      return;
    }
    setState(() {
      _range = SalesRange('custom', from: ymdOf(r.start), to: ymdOf(r.end));
      _data = null;
      _stale = false;
    });
    _load();
  }

  Future<void> _export() async {
    final fmt = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Report share karein', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(_data?.period.rangeText ?? '', style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.table_chart_outlined, color: kTeal),
                title: const Text('CSV (Excel mein khulti hai)'),
                subtitle: const Text('Har order ki line'),
                onTap: () => Navigator.pop(ctx, 'csv'),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined, color: kTeal),
                title: const Text('PDF'),
                subtitle: const Text('Summary + orders ki list'),
                onTap: () => Navigator.pop(ctx, 'pdf'),
              ),
            ],
          ),
        ),
      ),
    );
    if (fmt == null || !mounted) return;
    await shareSalesReport(context, _range, fmt);
  }

  Widget _chips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final k in kSalesPeriods)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(k == 'custom' && _range.isCustom ? 'Chuni hui muddat' : kSalesPeriodLabels[k]!),
                avatar: k == 'custom' ? const Icon(Icons.date_range, size: 18) : null,
                selected: _range.period == k,
                onSelected: (_) => _pick(k),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          _chips(),
          if (d != null && d.period.rangeText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(d.period.rangeText, style: const TextStyle(color: Colors.black54, fontSize: 12)),
            ),
          if (_stale && d != null) ...[
            const SizedBox(height: 10),
            NoticeCard(
              level: NoticeLevel.warn,
              icon: Icons.wifi_off,
              text: 'Offline - purana data dikh raha hai${clockText(d.generatedAt).isEmpty ? '' : ' (aakhri update ${clockText(d.generatedAt)})'}.',
              actionLabel: 'Dobara',
              onAction: _load,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            NoticeCard(
              level: NoticeLevel.error,
              icon: Icons.cloud_off,
              text: _error!,
              actionLabel: 'Dobara',
              onAction: _load,
            ),
          ],
          if (d == null && _loading) ...const [SizedBox(height: 12), SkeletonList(count: 4)],
          if (d != null) ..._content(d),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  List<Widget> _content(SalesData d) {
    final sm = d.summary;
    final out = <Widget>[];
    void drill(String title, {String group = 'sales', String? payment}) =>
        openSalesOrders(context, _range, title: title, group: group, payment: payment);

    out.add(const SizedBox(height: 10));
    out.add(Row(children: [
      Expanded(
        child: StatCard(
          icon: Icons.payments_outlined,
          label: 'Kul bikri',
          value: rs(sm.sales),
          hint: 'Orders dekhein',
          color: kTeal,
          onTap: () => drill('Bikri ke orders'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: StatCard(
          icon: Icons.account_balance_wallet_outlined,
          label: 'Aap ki kamayi',
          value: rs(sm.net),
          hint: 'Commission ke baad',
          color: Colors.green.shade700,
        ),
      ),
    ]));
    out.add(const SizedBox(height: 10));
    out.add(Row(children: [
      Expanded(
        child: StatCard(
          icon: Icons.receipt_long_outlined,
          label: 'Orders',
          value: numText(sm.orders),
          hint: '${sm.done} mukammal${sm.cancelled > 0 ? ', ${sm.cancelled} reject' : ''}',
          color: Colors.indigo,
          onTap: () => drill('Saare orders', group: 'all'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: StatCard(
          icon: Icons.shopping_basket_outlined,
          label: 'Aosat order',
          value: rs(sm.avgOrder),
          hint: '${numText(sm.units)} cheezein bikin',
          color: Colors.orange.shade800,
        ),
      ),
    ]));

    // ---- chart
    out.add(const SectionTitle('Din ba din bikri'));
    out.add(Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
        child: SalesLineChart(days: d.chart),
      ),
    ));

    if (d.isEmpty) {
      out.add(const SizedBox(height: 12));
      out.add(const SizedBox(
        height: 220,
        child: EmptyState(
          icon: Icons.insights_outlined,
          title: 'Is muddat mein koi order nahi',
          message: 'Doosri muddat chunein ya naye orders ka intezar karein.',
        ),
      ));
      out.addAll(_bottomActions(d));
      return out;
    }

    // ---- cash vs online
    out.add(const SectionTitle('Cash aur Online'));
    out.add(_PayCard(data: d, onTap: (p) => drill(p == 'cod' ? 'COD ke orders' : 'Online ke orders', payment: p)));

    // ---- profit
    out.add(const SectionTitle('Munafa (profit)'));
    out.add(_ProfitCard(profit: d.profit, commissionPercent: d.commissionPercent));

    // ---- commission breakdown
    out.add(const SectionTitle('Commission ka hisaab'));
    out.add(_CommissionCard(data: d));

    // ---- top / slow products
    out.add(const SectionTitle('Sab se zyada bikne wale'));
    out.add(_TopCard(items: d.top));
    if (d.slow.isNotEmpty) {
      out.add(const SectionTitle('Kam chalne wale'));
      out.add(_SlowCard(items: d.slow));
    }

    out.addAll(_bottomActions(d));
    return out;
  }

  List<Widget> _bottomActions(SalesData d) {
    return [
      const SectionTitle('Statement aur report'),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => openSalesStatement(context, _range),
            icon: const Icon(Icons.list_alt_outlined),
            label: const Text('Statement'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.ios_share),
            label: const Text('Share'),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ab tak ka poora hisaab', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              _Row('Kul bikri', rs(d.lifetime.sales)),
              _Row('Shop ka commission', rs(d.lifetime.commission)),
              _Row('Aap ka hissa', rs(d.lifetime.payable), bold: true),
            ],
          ),
        ),
      ),
    ];
  }
}

// ---------------------------------------------------------------- cards

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? color;
  const _Row(this.label, this.value, {this.bold = false, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.black87))),
          Text(value,
              style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

class _PayCard extends StatelessWidget {
  final SalesData data;
  final void Function(String payment) onTap;
  const _PayCard({required this.data, required this.onTap});

  Widget _legend(String payment, String label, Color c, PayShare p, double total) {
    final pct = total <= 0 ? 0 : (p.sales * 100 / total).round();
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onTap(payment),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$label  ($pct%)', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${p.orders} orders', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
              ),
            ),
            Text(rs(p.sales), style: const TextStyle(fontWeight: FontWeight.w800)),
            const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = data.cod.sales + data.online.sales;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            PayDonut(cod: data.cod.sales, online: data.online.sales),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                children: [
                  _legend('cod', 'Cash (COD)', PayDonut.codColor, data.cod, total),
                  _legend('online', 'Online', PayDonut.onlineColor, data.online, total),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfitCard extends StatelessWidget {
  final ProfitInfo profit;
  final double commissionPercent;
  const _ProfitCard({required this.profit, required this.commissionPercent});

  @override
  Widget build(BuildContext context) {
    if (!profit.available) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('N/A', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.black45)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Profit abhi nahi nikal sakta',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                'Profit tab nikalta hai jab products par "Kharid rate" bhara ho. '
                'Product edit karke kharid rate likhein.'
                '${profit.productsTotal > 0 ? '\n\nAbhi ${profit.productsWithRate} / ${profit.productsTotal} products par kharid rate hai.' : ''}',
                style: const TextStyle(color: Colors.black54, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }
    final net = profit.net ?? 0;
    final good = net >= 0;
    final c = good ? Colors.green.shade700 : Colors.red.shade700;
    final partial = profit.productsWithRate < profit.productsTotal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Khaalis munafa', style: TextStyle(color: Colors.black54, fontSize: 12)),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(rsSigned(net),
                            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: c)),
                      ),
                    ],
                  ),
                ),
                if (profit.marginPercent != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                    child: Text('${numText(profit.marginPercent)}% margin',
                        style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12)),
                  ),
              ],
            ),
            const Divider(height: 22),
            _Row('Bikri (kharid rate wale products)', rs(profit.coveredSales ?? 0)),
            _Row('Kharid ki laagat', '- ${rs(profit.cost ?? 0)}'),
            _Row('Munafa (commission se pehle)', rsSigned(profit.gross ?? 0)),
            _Row('Commission (${numText(commissionPercent)}%)', '- ${rs(profit.commission ?? 0)}'),
            _Row('Khaalis munafa', rsSigned(net), bold: true, color: c),
            if (partial) ...[
              const SizedBox(height: 8),
              Text(
                'Sirf ${profit.productsWithRate} / ${profit.productsTotal} products par kharid rate hai, '
                'baqi ki bikri is hisaab mein shamil nahi.',
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CommissionCard extends StatelessWidget {
  final SalesData data;
  const _CommissionCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final sm = data.summary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row('Kul bikri', rs(sm.sales)),
            _Row('Shop ka commission (${numText(data.commissionPercent)}%)', '- ${rs(sm.commission)}'),
            const Divider(height: 18),
            _Row('Aap ko milega', rs(sm.net), bold: true, color: Colors.green.shade700),
            const SizedBox(height: 10),
            const Text('Cash aur Online ke hisaab se',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black54)),
            const SizedBox(height: 4),
            _Row('Cash (COD): commission', '- ${rs(data.cod.commission)}'),
            _Row('Cash (COD): aap ka hissa', rs(data.cod.net)),
            _Row('Online: commission', '- ${rs(data.online.commission)}'),
            _Row('Online: aap ka hissa', rs(data.online.net)),
            if (sm.cancelled > 0) ...[
              const SizedBox(height: 8),
              Text('${sm.cancelled} reject / cancel orders (${numText(sm.cancelRate)}%) is hisaab mein shamil nahi.',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ],
        ),
      ),
    );
  }
}

class _TopCard extends StatelessWidget {
  final List<TopProduct> items;
  const _TopCard({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Card(
        child: Padding(padding: EdgeInsets.all(16), child: Text('Abhi koi bikri nahi.', style: TextStyle(color: Colors.black54))),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.black45)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(items[i].name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: (items[i].pct.clamp(2, 100)) / 100,
                            minHeight: 7,
                            backgroundColor: kTeal.withValues(alpha: 0.1),
                            color: kTeal,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(rs(items[i].sales), style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text('${numText(items[i].qty)} bika', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                    ],
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SlowCard extends StatelessWidget {
  final List<SlowProduct> items;
  const _SlowCard({required this.items});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            for (final p in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Icon(p.qty <= 0 ? Icons.hourglass_empty : Icons.trending_down,
                        size: 18, color: Colors.orange.shade800),
                    const SizedBox(width: 8),
                    Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Text(p.qty <= 0 ? 'Koi bikri nahi' : '${numText(p.qty)} bika',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.orange.shade800)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- share (export)

/// Report banwao aur share sheet kholo (WhatsApp / email...). Loading dialog; net / server masla ho to saaf message.
Future<void> shareSalesReport(BuildContext context, SalesRange range, String format) async {
  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  final state = AppScope.read(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator()),
    ),
  );
  ExportFile? file;
  String? err;
  try {
    file = await Api.salesExport(range, format: format);
  } on ApiException catch (e) {
    if (e.authExpired) {
      nav.pop();
      await state.handleApiError(e);
      return;
    }
    err = e.message;
  } catch (_) {
    err = 'Report nahi ban saki. Dobara koshish karein.';
  }
  nav.pop(); // loading dialog band
  if (file == null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(err ?? 'Report nahi ban saki.')));
    return;
  }
  try {
    await Share.shareXFiles(
      [XFile.fromData(file.bytes, mimeType: file.mime, name: file.name)],
      fileNameOverrides: [file.name],
      text: 'Sales report',
    );
  } catch (_) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Share nahi ho saka. Dobara koshish karein.')));
  }
}

// ---------------------------------------------------------------- drill-down: orders

Future<void> openSalesOrders(BuildContext context, SalesRange range,
    {required String title, String group = 'sales', String? payment, String? day}) {
  final st = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(
      state: st,
      child: SalesOrdersScreen(range: range, title: title, group: group, payment: payment, day: day),
    ),
  ));
}

class SalesOrdersScreen extends StatefulWidget {
  final SalesRange range;
  final String title;
  final String group;
  final String? payment;
  final String? day;
  const SalesOrdersScreen(
      {super.key, required this.range, required this.title, this.group = 'sales', this.payment, this.day});

  @override
  State<SalesOrdersScreen> createState() => _SalesOrdersScreenState();
}

class _SalesOrdersScreenState extends State<SalesOrdersScreen> {
  final ScrollController _sc = ScrollController();
  List<VendorOrder> _orders = [];
  bool _loaded = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  int _page = 1;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _sc.addListener(() {
      if (_sc.hasClients && _sc.position.pixels > _sc.position.maxScrollExtent - 300) _more();
    });
    _load();
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await Api.salesOrders(widget.range, group: widget.group, day: widget.day, payment: widget.payment);
      if (!mounted || seq != _seq) return;
      setState(() {
        _orders = p.orders;
        _page = p.page;
        _hasMore = p.hasMore;
        _loaded = true;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      if (await AppScope.read(context).handleApiError(e)) {
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      if (!mounted || seq != _seq) return;
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

  Future<void> _more() async {
    if (_loading || _loadingMore || !_hasMore || !_loaded) return;
    final seq = _seq;
    setState(() => _loadingMore = true);
    try {
      final p = await Api.salesOrders(widget.range,
          group: widget.group, day: widget.day, payment: widget.payment, page: _page + 1);
      if (!mounted || seq != _seq) return;
      final have = _orders.map((e) => e.id).toSet();
      setState(() {
        _orders = [..._orders, ...p.orders.where((e) => !have.contains(e.id))];
        _page = p.page;
        _hasMore = p.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sub = widget.day != null ? dateText(widget.day!) : '';
    Widget body;
    if (!_loaded && _loading) {
      body = ListView(padding: const EdgeInsets.all(12), children: const [SkeletonList(count: 5, height: 84)]);
    } else if (!_loaded && _error != null) {
      body = ListView(padding: const EdgeInsets.all(12), children: [
        NoticeCard(level: NoticeLevel.error, icon: Icons.cloud_off, text: _error!, actionLabel: 'Dobara', onAction: _load),
      ]);
    } else if (_orders.isEmpty) {
      body = ListView(children: const [
        SizedBox(
          height: 360,
          child: EmptyState(icon: Icons.receipt_long_outlined, title: 'Koi order nahi', message: 'Is hisaab mein koi order nahi mila.'),
        ),
      ]);
    } else {
      body = ListView.separated(
        controller: _sc,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: _orders.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          if (i >= _orders.length) {
            return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()));
          }
          return _OrderRow(order: _orders[i]);
        },
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(sub.isEmpty ? widget.title : '${widget.title} - $sub')),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }
}

class _OrderRow extends StatelessWidget {
  final VendorOrder order;
  const _OrderRow({required this.order});

  @override
  Widget build(BuildContext context) {
    final o = order;
    final sc = statusColor(o.status);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openOrderDetail(context, o),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text('#${o.orderNo}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: sc.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                  child: Text(statusText(o), style: TextStyle(color: sc, fontWeight: FontWeight.w800, fontSize: 11)),
                ),
                const Icon(Icons.chevron_right, color: Colors.black38),
              ]),
              const SizedBox(height: 4),
              Text('${o.customer.name} - ${dateTimeText(o.createdAt)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black54, fontSize: 12)),
              const SizedBox(height: 8),
              Row(children: [
                Text('${o.itemsCount} items', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(width: 8),
                PayBadge(payment: o.payment),
                const Spacer(),
                Text(rs(o.total), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- statement

Future<void> openSalesStatement(BuildContext context, SalesRange range) {
  final st = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: st, child: SalesStatementScreen(range: range)),
  ));
}

class SalesStatementScreen extends StatefulWidget {
  final SalesRange range;
  const SalesStatementScreen({super.key, required this.range});

  @override
  State<SalesStatementScreen> createState() => _SalesStatementScreenState();
}

class _SalesStatementScreenState extends State<SalesStatementScreen> {
  StatementData? _data;
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await Api.salesStatement(widget.range);
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      if (await AppScope.read(context).handleApiError(e)) {
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      if (!mounted || seq != _seq) return;
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

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Statement'),
        actions: [
          IconButton(
            tooltip: 'CSV share',
            icon: const Icon(Icons.ios_share),
            onPressed: () => shareSalesReport(context, widget.range, 'csv'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (d == null && _loading) const SkeletonList(count: 5, height: 70),
            if (d == null && !_loading && _error != null)
              NoticeCard(level: NoticeLevel.error, icon: Icons.cloud_off, text: _error!, actionLabel: 'Dobara', onAction: _load),
            if (d != null) ..._content(d),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(StatementData d) {
    final out = <Widget>[];
    out.add(Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(d.period.rangeText, style: const TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 6),
            const Text('Mukammal orders ki kamayi', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            _Row('Orders', numText(d.total.orders)),
            _Row('Bikri', rs(d.total.sales)),
            _Row('Commission (${numText(d.commissionPercent)}%)', '- ${rs(d.total.commission)}'),
            const Divider(height: 18),
            _Row('Aap ko milega', rs(d.total.net), bold: true, color: Colors.green.shade700),
            if (d.note.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(d.note, style: const TextStyle(fontSize: 11, color: Colors.black54)),
            ],
          ],
        ),
      ),
    ));
    out.add(const SectionTitle('Din wise'));
    if (d.days.isEmpty) {
      out.add(const SizedBox(
        height: 240,
        child: EmptyState(
          icon: Icons.list_alt_outlined,
          title: 'Koi mukammal order nahi',
          message: 'Is muddat mein koi order deliver nahi hua.',
        ),
      ));
    }
    for (final day in d.days) {
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openSalesOrders(context, widget.range,
                title: 'Mukammal orders', group: 'done', day: day.date),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(dateText(day.date), style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text('${day.orders} orders - bikri ${rs(day.sales)}',
                            style: const TextStyle(fontSize: 12, color: Colors.black54)),
                        Text('commission - ${rs(day.commission)}',
                            style: const TextStyle(fontSize: 12, color: Colors.black54)),
                      ],
                    ),
                  ),
                  Text(rs(day.net),
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Colors.green.shade700)),
                  const Icon(Icons.chevron_right, color: Colors.black38),
                ],
              ),
            ),
          ),
        ),
      ));
    }
    out.add(const SectionTitle('Ab tak ka poora hisaab'));
    out.add(Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            _Row('Kul bikri', rs(d.lifetime.sales)),
            _Row('Shop ka commission', rs(d.lifetime.commission)),
            _Row('Aap ka hissa', rs(d.lifetime.payable), bold: true),
          ],
        ),
      ),
    ));
    return out;
  }
}
