import '../utils.dart';
import 'vendor.dart';

/// Ek muddat (aaj / hafta / mahina) ki bikri aur orders.
class Period {
  final double sales;
  final int orders;
  const Period(this.sales, this.orders);

  factory Period.fromJson(dynamic j) {
    final m = asMap(j);
    return Period(toD(m['sales']), toI(m['orders']));
  }
}

/// 7 din ke chart ka ek din.
class ChartDay {
  final String date;
  final String label;
  final double sales;
  final int orders;
  const ChartDay(this.date, this.label, this.sales, this.orders);

  factory ChartDay.fromJson(Map<String, dynamic> m) =>
      ChartDay(s(m['date']), s(m['label']), toD(m['sales']), toI(m['orders']));
}

class DashWarning {
  final String code;
  final String level; // info / warn / error
  final String text;
  const DashWarning(this.code, this.level, this.text);

  factory DashWarning.fromJson(Map<String, dynamic> m) =>
      DashWarning(s(m['code']), s(m['level']), s(m['text']));
}

/// Store Open / Closed ki tasveer.
class StoreInfo {
  /// open / busy / closed (vendor ka apna switch).
  final String status;

  /// Vendor ne store khula rakha hai (closed nahi).
  final bool switchOn;

  /// Customer abhi order de sakta hai (switch + timing + approval).
  final bool isOpen;
  final bool withinHours;
  final String opensAt;
  final String closesAt;
  final bool locationVerified;

  const StoreInfo({
    required this.status,
    required this.switchOn,
    required this.isOpen,
    required this.withinHours,
    required this.opensAt,
    required this.closesAt,
    required this.locationVerified,
  });

  factory StoreInfo.fromJson(Map<String, dynamic> m) => StoreInfo(
        status: s(m['status']),
        switchOn: m['switch_on'] == true,
        isOpen: m['is_open'] == true,
        withinHours: m['within_hours'] != false,
        opensAt: s(m['opens_at']),
        closesAt: s(m['closes_at']),
        locationVerified: m['location_verified'] == true,
      );

  bool get hasHours => opensAt.isNotEmpty && closesAt.isNotEmpty;
}

class OrdersInfo {
  final int newCount; // naye (pending)
  final int active; // chal rahe
  final int done; // mukammal
  const OrdersInfo(this.newCount, this.active, this.done);

  factory OrdersInfo.fromJson(dynamic j) {
    final m = asMap(j);
    return OrdersInfo(toI(m['new']), toI(m['active']), toI(m['done']));
  }
}

class Earnings {
  final double sales;
  final double commission;
  final double payable;
  final double units;
  const Earnings(this.sales, this.commission, this.payable, this.units);

  factory Earnings.fromJson(dynamic j) {
    final m = asMap(j);
    return Earnings(toD(m['sales']), toD(m['commission']), toD(m['payable']), toD(m['units']));
  }
}

class ProductsInfo {
  final int approved;
  final int pending;
  final int rejected;
  final int total;
  const ProductsInfo(this.approved, this.pending, this.rejected, this.total);

  factory ProductsInfo.fromJson(dynamic j) {
    final m = asMap(j);
    return ProductsInfo(toI(m['approved']), toI(m['pending']), toI(m['rejected']), toI(m['total']));
  }
}

class LowItem {
  final int id;
  final String name;
  final double stock;
  final bool out;
  const LowItem(this.id, this.name, this.stock, this.out);

  factory LowItem.fromJson(Map<String, dynamic> m) =>
      LowItem(toI(m['id']), s(m['name']), toD(m['stock']), m['out'] == true);
}

class StockInfo {
  final int low; // kam
  final int out; // khatam
  final List<LowItem> items;
  const StockInfo(this.low, this.out, this.items);

  factory StockInfo.fromJson(dynamic j) {
    final m = asMap(j);
    return StockInfo(
      toI(m['low']),
      toI(m['out']),
      listOfMaps(m['items']).map(LowItem.fromJson).toList(),
    );
  }
}

class CashInfo {
  final int count;
  final double amount;
  const CashInfo(this.count, this.amount);

  factory CashInfo.fromJson(dynamic j) {
    final m = asMap(j);
    return CashInfo(toI(m['count']), toD(m['amount']));
  }
}

/// GET /api/vendor/dashboard/ ka jawab.
class DashboardData {
  final Vendor? vendor;
  final StoreInfo store;
  final Period today;
  final Period week;
  final Period month;
  final OrdersInfo orders;
  final int newOrders;
  final Earnings earnings;
  final double commissionPercent;
  final double? ratingAvg;
  final int ratingCount;
  final ProductsInfo products;
  final StockInfo stock;
  final CashInfo riderCash;
  final List<ChartDay> chart;
  final List<DashWarning> warnings;

  /// Server ne yeh data kab banaya (ISO waqt) - "aakhri update" dikhane ke liye.
  final String generatedAt;

  const DashboardData({
    required this.vendor,
    required this.store,
    required this.today,
    required this.week,
    required this.month,
    required this.orders,
    required this.newOrders,
    required this.earnings,
    required this.commissionPercent,
    required this.ratingAvg,
    required this.ratingCount,
    required this.products,
    required this.stock,
    required this.riderCash,
    required this.chart,
    required this.warnings,
    required this.generatedAt,
  });

  factory DashboardData.fromJson(Map<String, dynamic> m) {
    final rating = asMap(m['rating']);
    return DashboardData(
      vendor: m['vendor'] is Map ? Vendor.fromJson(asMap(m['vendor'])) : null,
      store: StoreInfo.fromJson(asMap(m['store'])),
      today: Period.fromJson(m['today']),
      week: Period.fromJson(m['week']),
      month: Period.fromJson(m['month']),
      orders: OrdersInfo.fromJson(m['orders']),
      newOrders: toI(m['new_orders']),
      earnings: Earnings.fromJson(m['earnings']),
      commissionPercent: toD(m['commission_percent']),
      ratingAvg: rating['avg'] == null ? null : toD(rating['avg']),
      ratingCount: toI(rating['count']),
      products: ProductsInfo.fromJson(m['products']),
      stock: StockInfo.fromJson(m['stock']),
      riderCash: CashInfo.fromJson(m['rider_cash']),
      chart: listOfMaps(m['chart']).map(ChartDay.fromJson).toList(),
      warnings: listOfMaps(m['warnings']).map(DashWarning.fromJson).toList(),
      generatedAt: s(m['generated_at']),
    );
  }

  /// Store switch badalne ke baad naya store / vendor (baqi data jyon ka tyon).
  DashboardData withStore(StoreInfo newStore, Vendor? newVendor) => DashboardData(
        vendor: newVendor ?? vendor,
        store: newStore,
        today: today,
        week: week,
        month: month,
        orders: orders,
        newOrders: newOrders,
        earnings: earnings,
        commissionPercent: commissionPercent,
        ratingAvg: ratingAvg,
        ratingCount: ratingCount,
        products: products,
        stock: stock,
        riderCash: riderCash,
        chart: chart,
        warnings: warnings,
        generatedAt: generatedAt,
      );
}

/// POST /api/vendor/store/open/ ka jawab.
class StoreSwitchResult {
  final StoreInfo store;
  final Vendor? vendor;
  final String message;
  const StoreSwitchResult(this.store, this.vendor, this.message);
}
