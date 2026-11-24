import '../utils.dart';

class PeriodStat {
  final int deliveries;
  final double earned;
  const PeriodStat({this.deliveries = 0, this.earned = 0});

  factory PeriodStat.fromJson(dynamic j) {
    final m = asMap(j);
    return PeriodStat(deliveries: toI(m['deliveries']), earned: toD(m['earned']) ?? 0);
  }
}

class ChartDay {
  final String label;
  final int deliveries;
  final double earned;
  const ChartDay(this.label, this.deliveries, this.earned);

  factory ChartDay.fromJson(Map<String, dynamic> m) =>
      ChartDay(s(m['label']), toI(m['deliveries']), toD(m['earned']) ?? 0);
}

class DashWarning {
  final String code;
  final String level; // info / warn / error
  final String text;
  const DashWarning(this.code, this.level, this.text);

  factory DashWarning.fromJson(Map<String, dynamic> m) =>
      DashWarning(s(m['code']), s(m['level']), s(m['text']));
}

/// GET /api/rider/dashboard/ ka jawab.
class DashboardData {
  final bool online;
  final PeriodStat today;
  final PeriodStat week;
  final PeriodStat month;
  final int totalDeliveries;
  final double cashInHand;
  final double pendingHandover;
  final double availableToHandover;
  final double due;
  final double cashLimit;
  final bool limitReached;
  final double? ratingAvg;
  final int ratingCount;
  final int activeCount;
  final int maxActive;
  final int offersCount;
  final List<ChartDay> chart;
  final List<DashWarning> warnings;

  const DashboardData({
    required this.online,
    required this.today,
    required this.week,
    required this.month,
    required this.totalDeliveries,
    required this.cashInHand,
    required this.pendingHandover,
    required this.availableToHandover,
    required this.due,
    required this.cashLimit,
    required this.limitReached,
    required this.ratingAvg,
    required this.ratingCount,
    required this.activeCount,
    required this.maxActive,
    required this.offersCount,
    required this.chart,
    required this.warnings,
  });

  factory DashboardData.fromJson(Map<String, dynamic> m) {
    final rating = asMap(m['rating']);
    return DashboardData(
      online: m['online'] == true,
      today: PeriodStat.fromJson(m['today']),
      week: PeriodStat.fromJson(m['week']),
      month: PeriodStat.fromJson(m['month']),
      totalDeliveries: toI(m['total_deliveries']),
      cashInHand: toD(m['cash_in_hand']) ?? 0,
      pendingHandover: toD(m['pending_handover']) ?? 0,
      availableToHandover: toD(m['available_to_handover']) ?? 0,
      due: toD(m['due']) ?? 0,
      cashLimit: toD(m['cash_limit']) ?? 0,
      limitReached: m['limit_reached'] == true,
      ratingAvg: toD(rating['avg']),
      ratingCount: toI(rating['count']),
      activeCount: toI(m['active_count']),
      maxActive: toI(m['max_active']),
      offersCount: toI(m['offers_count']),
      chart: listOfMaps(m['chart']).map(ChartDay.fromJson).toList(),
      warnings: listOfMaps(m['warnings']).map(DashWarning.fromJson).toList(),
    );
  }
}
