import '../utils.dart';

/// History list ki aik line (delivered / cancelled order).
class HistoryItem {
  final int id;
  final String orderNo;
  final String status; // delivered / cancelled
  final String storeName;
  final String customerName;
  final double total;
  final bool isCod;
  final double fee;
  final double cashCollected;
  final String when;

  const HistoryItem({
    required this.id,
    required this.orderNo,
    required this.status,
    required this.storeName,
    required this.customerName,
    required this.total,
    required this.isCod,
    required this.fee,
    required this.cashCollected,
    required this.when,
  });

  factory HistoryItem.fromJson(Map<String, dynamic> m) => HistoryItem(
        id: toI(m['id']),
        orderNo: s(m['order_no']),
        status: s(m['status']),
        storeName: s(m['store_name']),
        customerName: s(m['customer_name']),
        total: toD(m['total']) ?? 0,
        isCod: m['is_cod'] == true,
        fee: toD(m['fee']) ?? 0,
        cashCollected: toD(m['cash_collected']) ?? 0,
        when: s(m['when']),
      );

  bool get delivered => status == 'delivered';
}

class HistorySummary {
  final int deliveries;
  final double earned;
  final double cash;
  const HistorySummary({this.deliveries = 0, this.earned = 0, this.cash = 0});

  factory HistorySummary.fromJson(dynamic j) {
    final m = asMap(j);
    return HistorySummary(
        deliveries: toI(m['deliveries']), earned: toD(m['earned']) ?? 0, cash: toD(m['cash']) ?? 0);
  }
}

class HistoryPage {
  final int page;
  final int total;
  final bool hasMore;
  final List<HistoryItem> items;
  final HistorySummary summary;

  const HistoryPage(this.page, this.total, this.hasMore, this.items, this.summary);

  factory HistoryPage.fromJson(Map<String, dynamic> m) => HistoryPage(
        toI(m['page'], 1),
        toI(m['total']),
        m['has_more'] == true,
        listOfMaps(m['items']).map(HistoryItem.fromJson).toList(),
        HistorySummary.fromJson(m['summary']),
      );
}
