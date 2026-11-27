import '../utils.dart';
import 'products.dart';

/// Stock screen ke chips. key: need (kam + khatam) | low | out | all  (server `filter` ke barabar).
const List<String> kStockFilters = ['need', 'low', 'out', 'all'];
const Map<String, String> kStockFilterLabels = {
  'need': 'Kam + Khatam',
  'low': 'Kam',
  'out': 'Khatam',
  'all': 'Sab',
};

/// Stock add / minus ki wajah (server se aati hai, app mein hard-code nahi).
class StockReason {
  final String code;
  final String label;
  const StockReason(this.code, this.label);

  factory StockReason.fromJson(Map<String, dynamic> m) => StockReason(s(m['code']), s(m['label']));
}

/// Ek product ka stock (card + sheet): product + reserved (pending orders ke liye roka hua) + bechne layak.
class StockItem {
  final VendorProduct product;
  final double reserved;
  final double available;

  const StockItem(this.product, this.reserved, this.available);

  factory StockItem.fromJson(Map<String, dynamic> m) {
    final p = VendorProduct.fromJson(m);
    final hasAvail = m.containsKey('available');
    return StockItem(p, toD(m['reserved']), hasAvail ? toD(m['available']) : p.stock);
  }

  int get id => product.id;
}

/// Upar ki ginti: kam / khatam / theek.
class StockSummary {
  final int low;
  final int out;
  final int ok;
  final int approved;
  final double defaultThreshold;

  const StockSummary({this.low = 0, this.out = 0, this.ok = 0, this.approved = 0, this.defaultThreshold = 10});

  factory StockSummary.fromJson(dynamic j) {
    final m = asMap(j);
    return StockSummary(
      low: toI(m['low']),
      out: toI(m['out']),
      ok: toI(m['ok']),
      approved: toI(m['approved']),
      defaultThreshold: toD(m['default_threshold'], 10),
    );
  }

  int get need => low + out;
}

class StockReasons {
  final List<StockReason> add;
  final List<StockReason> minus;
  const StockReasons(this.add, this.minus);

  static const fallback = StockReasons(
    [StockReason('purchase', 'Naya maal aaya'), StockReason('other', 'Doosri wajah')],
    [StockReason('damaged', 'Kharab / toota'), StockReason('other', 'Doosri wajah')],
  );

  factory StockReasons.fromJson(dynamic j) {
    final m = asMap(j);
    final a = listOfMaps(m['add']).map(StockReason.fromJson).toList();
    final b = listOfMaps(m['minus']).map(StockReason.fromJson).toList();
    if (a.isEmpty || b.isEmpty) return fallback;
    return StockReasons(a, b);
  }
}

/// Stock API ka ek page.
class StockPage {
  final int page;
  final bool hasMore;
  final StockSummary summary;
  final StockReasons reasons;
  final List<StockItem> items;

  const StockPage(this.page, this.hasMore, this.summary, this.reasons, this.items);

  factory StockPage.fromJson(Map<String, dynamic> m) => StockPage(
        toI(m['page'], 1),
        m['has_more'] == true,
        StockSummary.fromJson(m['summary']),
        StockReasons.fromJson(m['reasons']),
        listOfMaps(m['products']).map(StockItem.fromJson).toList(),
      );
}

/// Stock adjust ek product ka nateeja.
class StockAdjustRow {
  final int id;
  final String status; // ok | same | error
  final String error;
  final String code;
  final double before;
  final double after;
  final StockItem? item;

  const StockAdjustRow(this.id, this.status, this.error, this.code, this.before, this.after, this.item);

  factory StockAdjustRow.fromJson(Map<String, dynamic> m) => StockAdjustRow(
        toI(m['id']),
        s(m['status']),
        s(m['error']),
        s(m['code']),
        toD(m['before']),
        toD(m['after']),
        m['product'] is Map ? StockItem.fromJson(asMap(m['product'])) : null,
      );

  bool get ok => status == 'ok' || status == 'same';
}

/// Stock adjust ka jawab (ek ya kai products).
class StockAdjustResult {
  final String message;
  final StockSummary summary;
  final List<StockAdjustRow> rows;

  const StockAdjustResult(this.message, this.summary, this.rows);

  factory StockAdjustResult.fromJson(Map<String, dynamic> m) => StockAdjustResult(
        s(m['message']),
        StockSummary.fromJson(m['summary']),
        listOfMaps(m['results']).map(StockAdjustRow.fromJson).toList(),
      );

  int get doneCount => rows.where((r) => r.ok).length;
  List<StockAdjustRow> get failed => rows.where((r) => !r.ok).toList();
}

/// Ek product ki stock history ka record.
class StockLog {
  final int id;
  final String product;
  final String kind; // add | minus
  final double qty;
  final double before;
  final double after;
  final String reasonLabel;
  final String note;
  final String source;
  final String at;

  const StockLog({
    required this.id,
    required this.product,
    required this.kind,
    required this.qty,
    required this.before,
    required this.after,
    required this.reasonLabel,
    required this.note,
    required this.source,
    required this.at,
  });

  factory StockLog.fromJson(Map<String, dynamic> m) => StockLog(
        id: toI(m['id']),
        product: s(m['product']),
        kind: s(m['kind']),
        qty: toD(m['qty']),
        before: toD(m['before']),
        after: toD(m['after']),
        reasonLabel: s(m['reason_label']),
        note: s(m['note']),
        source: s(m['source']),
        at: s(m['at']),
      );

  bool get isAdd => kind == 'add';
}

class StockHistoryPage {
  final int page;
  final bool hasMore;
  final List<StockLog> logs;
  const StockHistoryPage(this.page, this.hasMore, this.logs);

  factory StockHistoryPage.fromJson(Map<String, dynamic> m) => StockHistoryPage(
        toI(m['page'], 1),
        m['has_more'] == true,
        listOfMaps(m['logs']).map(StockLog.fromJson).toList(),
      );
}
