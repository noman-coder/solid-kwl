import 'dart:typed_data';

import '../utils.dart';

/// Sales tab ki muddat: today / week / month / custom.
const List<String> kSalesPeriods = ['today', 'week', 'month', 'custom'];
const Map<String, String> kSalesPeriodLabels = {
  'today': 'Aaj',
  'week': '7 din',
  'month': '30 din',
  'custom': 'Tareekh chunein',
};

/// Server ko bheji jane wali muddat (custom mein from / to bhi).
class SalesRange {
  final String period;
  final String? from; // YYYY-MM-DD (sirf custom)
  final String? to;
  const SalesRange(this.period, {this.from, this.to});

  Map<String, String> get params => {
        'period': period,
        if (period == 'custom' && from != null) 'from': from!,
        if (period == 'custom' && to != null) 'to': to!,
      };

  bool get isCustom => period == 'custom';
}

class SalesPeriodInfo {
  final String key;
  final String label;
  final String from;
  final String to;
  final int days;
  const SalesPeriodInfo(this.key, this.label, this.from, this.to, this.days);

  factory SalesPeriodInfo.fromJson(dynamic j) {
    final m = asMap(j);
    return SalesPeriodInfo(s(m['key']), s(m['label']), s(m['from']), s(m['to']), toI(m['days'], 1));
  }

  /// "05 Nov - 11 Nov" (ek din ho to sirf ek tareekh)
  String get rangeText {
    final a = dateText(from);
    final b = dateText(to);
    if (a.isEmpty) return '';
    return from == to || b.isEmpty ? a : '$a - $b';
  }
}

class SalesSummary {
  final int orders;
  final int done;
  final int open;
  final int cancelled;
  final double cancelRate;
  final double sales;
  final double units;
  final double avgOrder;
  final double commission;
  final double net;
  const SalesSummary({
    this.orders = 0,
    this.done = 0,
    this.open = 0,
    this.cancelled = 0,
    this.cancelRate = 0,
    this.sales = 0,
    this.units = 0,
    this.avgOrder = 0,
    this.commission = 0,
    this.net = 0,
  });

  factory SalesSummary.fromJson(dynamic j) {
    final m = asMap(j);
    return SalesSummary(
      orders: toI(m['orders']),
      done: toI(m['done']),
      open: toI(m['open']),
      cancelled: toI(m['cancelled']),
      cancelRate: toD(m['cancel_rate']),
      sales: toD(m['sales']),
      units: toD(m['units']),
      avgOrder: toD(m['avg_order']),
      commission: toD(m['commission']),
      net: toD(m['net']),
    );
  }
}

/// COD ya Online ka hissa.
class PayShare {
  final int orders;
  final double sales;
  final double commission;
  final double net;
  const PayShare({this.orders = 0, this.sales = 0, this.commission = 0, this.net = 0});

  factory PayShare.fromJson(dynamic j) {
    final m = asMap(j);
    return PayShare(
      orders: toI(m['orders']),
      sales: toD(m['sales']),
      commission: toD(m['commission']),
      net: toD(m['net']),
    );
  }
}

/// Profit: purchase rate wale products par. [available] false ho to app 'N/A' dikhaye (galat number nahi).
class ProfitInfo {
  final bool available;
  final double? coveredSales;
  final double? cost;
  final double? gross;
  final double? commission;
  final double? net;
  final double? marginPercent;
  final int productsTotal;
  final int productsWithRate;
  const ProfitInfo({
    this.available = false,
    this.coveredSales,
    this.cost,
    this.gross,
    this.commission,
    this.net,
    this.marginPercent,
    this.productsTotal = 0,
    this.productsWithRate = 0,
  });

  factory ProfitInfo.fromJson(dynamic j) {
    final m = asMap(j);
    double? n(dynamic v) => v == null ? null : toD(v);
    return ProfitInfo(
      available: m['available'] == true,
      coveredSales: n(m['covered_sales']),
      cost: n(m['cost']),
      gross: n(m['gross']),
      commission: n(m['commission']),
      net: n(m['net']),
      marginPercent: n(m['margin_percent']),
      productsTotal: toI(m['products_total']),
      productsWithRate: toI(m['products_with_rate']),
    );
  }
}

class SalesDay {
  final String date;
  final String label;
  final double sales;
  final int orders;
  const SalesDay(this.date, this.label, this.sales, this.orders);

  factory SalesDay.fromJson(Map<String, dynamic> m) =>
      SalesDay(s(m['date']), s(m['label']), toD(m['sales']), toI(m['orders']));
}

class TopProduct {
  final int productId;
  final String name;
  final double qty;
  final double sales;
  final int pct; // sab se zyada bikne wale ke muqable (bar ki lambai)
  const TopProduct(this.productId, this.name, this.qty, this.sales, this.pct);

  factory TopProduct.fromJson(Map<String, dynamic> m) =>
      TopProduct(toI(m['product_id']), s(m['name']), toD(m['qty']), toD(m['sales']), toI(m['pct']));
}

class SlowProduct {
  final int productId;
  final String name;
  final double qty;
  const SlowProduct(this.productId, this.name, this.qty);

  factory SlowProduct.fromJson(Map<String, dynamic> m) =>
      SlowProduct(toI(m['product_id']), s(m['name']), toD(m['qty']));
}

/// Ab tak ka poora hisaab (muddat se alag).
class Lifetime {
  final double sales;
  final double commission;
  final double payable;
  const Lifetime({this.sales = 0, this.commission = 0, this.payable = 0});

  factory Lifetime.fromJson(dynamic j) {
    final m = asMap(j);
    return Lifetime(sales: toD(m['sales']), commission: toD(m['commission']), payable: toD(m['payable']));
  }
}

/// GET /api/vendor/sales/ ka jawab.
class SalesData {
  final String generatedAt;
  final SalesPeriodInfo period;
  final double commissionPercent;
  final SalesSummary summary;
  final PayShare cod;
  final PayShare online;
  final ProfitInfo profit;
  final List<SalesDay> chart;
  final List<TopProduct> top;
  final List<SlowProduct> slow;
  final Lifetime lifetime;

  const SalesData({
    required this.generatedAt,
    required this.period,
    required this.commissionPercent,
    required this.summary,
    required this.cod,
    required this.online,
    required this.profit,
    required this.chart,
    required this.top,
    required this.slow,
    required this.lifetime,
  });

  factory SalesData.fromJson(Map<String, dynamic> m) {
    final pay = asMap(m['payments']);
    return SalesData(
      generatedAt: s(m['generated_at']),
      period: SalesPeriodInfo.fromJson(m['period']),
      commissionPercent: toD(m['commission_percent']),
      summary: SalesSummary.fromJson(m['summary']),
      cod: PayShare.fromJson(pay['cod']),
      online: PayShare.fromJson(pay['online']),
      profit: ProfitInfo.fromJson(m['profit']),
      chart: listOfMaps(m['chart']).map(SalesDay.fromJson).toList(),
      top: listOfMaps(m['top']).map(TopProduct.fromJson).toList(),
      slow: listOfMaps(m['slow']).map(SlowProduct.fromJson).toList(),
      lifetime: Lifetime.fromJson(m['lifetime']),
    );
  }

  bool get isEmpty => summary.orders == 0;
}

/// Statement ki ek din ki line.
class StatementDay {
  final String date;
  final int orders;
  final double sales;
  final double commission;
  final double net;
  const StatementDay(this.date, this.orders, this.sales, this.commission, this.net);

  factory StatementDay.fromJson(Map<String, dynamic> m) => StatementDay(
      s(m['date']), toI(m['orders']), toD(m['sales']), toD(m['commission']), toD(m['net']));
}

/// GET /api/vendor/sales/statement/ ka jawab.
class StatementData {
  final SalesPeriodInfo period;
  final double commissionPercent;
  final String note;
  final PayShare total;
  final List<StatementDay> days;
  final Lifetime lifetime;
  const StatementData({
    required this.period,
    required this.commissionPercent,
    required this.note,
    required this.total,
    required this.days,
    required this.lifetime,
  });

  factory StatementData.fromJson(Map<String, dynamic> m) => StatementData(
        period: SalesPeriodInfo.fromJson(m['period']),
        commissionPercent: toD(m['commission_percent']),
        note: s(m['note']),
        total: PayShare.fromJson(m['total']),
        days: listOfMaps(m['days']).map(StatementDay.fromJson).toList(),
        lifetime: Lifetime.fromJson(m['lifetime']),
      );
}

/// Export ki hui file (CSV / PDF) - share ke liye.
class ExportFile {
  final Uint8List bytes;
  final String name;
  final String mime;
  const ExportFile(this.bytes, this.name, this.mime);
}
