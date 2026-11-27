import '../utils.dart';

/// Rider ka chhota khulasa (orders API ke "profile" se) - aaj ke numbers aur cash.
class RiderMini {
  final int id;
  final String name;
  final String phone;
  final String vehicle;
  final bool online;
  final int todayDeliveries;
  final double todayEarned;
  final double cashInHand;
  final double due;

  const RiderMini({
    this.id = 0,
    this.name = '',
    this.phone = '',
    this.vehicle = '',
    this.online = false,
    this.todayDeliveries = 0,
    this.todayEarned = 0,
    this.cashInHand = 0,
    this.due = 0,
  });

  static const RiderMini empty = RiderMini();

  factory RiderMini.fromJson(dynamic j) {
    final m = asMap(j);
    return RiderMini(
      id: toI(m['id']),
      name: s(m['name']),
      phone: s(m['phone']),
      vehicle: s(m['vehicle']),
      online: m['online'] == true,
      todayDeliveries: toI(m['today_deliveries']),
      todayEarned: toD(m['today_earned']) ?? 0,
      cashInHand: toD(m['cash_in_hand']) ?? 0,
      due: toD(m['due']) ?? 0,
    );
  }
}
