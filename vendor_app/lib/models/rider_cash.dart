import '../utils.dart';

/// Reject ki wajah ke chips (server sirf text leta hai; vendor apna text bhi likh sakta hai).
const List<String> kCashRejectReasons = [
  'Raqam kam mili',
  'Raqam nahi mili',
  'Rider abhi aaya nahi',
  'Ghalat raqam likhi',
];

class CashRider {
  final int id;
  final String name;
  final String phone;
  const CashRider(this.id, this.name, this.phone);

  factory CashRider.fromJson(dynamic j) {
    final m = asMap(j);
    return CashRider(toI(m['id']), s(m['name']), s(m['phone']));
  }
}

/// Handover mein shamil ek order (optional - rider order chune baghair bhi bhej sakta hai).
class CashOrder {
  final int id;
  final String orderNo;
  final double cash;
  const CashOrder(this.id, this.orderNo, this.cash);

  factory CashOrder.fromJson(Map<String, dynamic> m) => CashOrder(toI(m['id']), s(m['order_no']), toD(m['cash']));
}

/// Rider ka bheja hua cash handover. status: pending | confirmed | rejected.
class CashHandover {
  final int id;
  final String status;
  final double amount;
  final String note;
  final String rejectReason;
  final CashRider rider;
  final List<CashOrder> orders;
  final String createdAt;
  final String decidedAt;

  const CashHandover({
    required this.id,
    required this.status,
    required this.amount,
    required this.note,
    required this.rejectReason,
    required this.rider,
    required this.orders,
    required this.createdAt,
    required this.decidedAt,
  });

  factory CashHandover.fromJson(Map<String, dynamic> m) => CashHandover(
        id: toI(m['id']),
        status: s(m['status']),
        amount: toD(m['amount']),
        note: s(m['note']),
        rejectReason: s(m['reject_reason']),
        rider: CashRider.fromJson(m['rider']),
        orders: listOfMaps(m['orders']).map(CashOrder.fromJson).toList(),
        createdAt: s(m['created_at']),
        decidedAt: s(m['decided_at']),
      );

  bool get isPending => status == 'pending';
  bool get isConfirmed => status == 'confirmed';
  bool get isRejected => status == 'rejected';
}

/// Upar ki ginti / jod.
class CashSummary {
  final int pendingCount;
  final double pendingAmount;
  final int confirmedCount;
  final double confirmedTotal;
  final int rejectedCount;

  const CashSummary({
    this.pendingCount = 0,
    this.pendingAmount = 0,
    this.confirmedCount = 0,
    this.confirmedTotal = 0,
    this.rejectedCount = 0,
  });

  factory CashSummary.fromJson(dynamic j) {
    final m = asMap(j);
    return CashSummary(
      pendingCount: toI(m['pending_count']),
      pendingAmount: toD(m['pending_amount']),
      confirmedCount: toI(m['confirmed_count']),
      confirmedTotal: toD(m['confirmed_total']),
      rejectedCount: toI(m['rejected_count']),
    );
  }
}

class CashPage {
  final int page;
  final bool hasMore;
  final CashSummary summary;
  final List<CashHandover> pending; // sirf page 1 par
  final List<CashHandover> history;

  const CashPage(this.page, this.hasMore, this.summary, this.pending, this.history);

  factory CashPage.fromJson(Map<String, dynamic> m) => CashPage(
        toI(m['page'], 1),
        m['has_more'] == true,
        CashSummary.fromJson(m['summary']),
        listOfMaps(m['pending']).map(CashHandover.fromJson).toList(),
        listOfMaps(m['history']).map(CashHandover.fromJson).toList(),
      );
}

/// Confirm / reject ka natija: server ka message + taza handover + taza jod.
class CashActionResult {
  final String message;
  final CashHandover handover;
  final CashSummary summary;
  const CashActionResult(this.message, this.handover, this.summary);

  factory CashActionResult.fromJson(Map<String, dynamic> m) => CashActionResult(
        s(m['message']),
        CashHandover.fromJson(asMap(m['handover'])),
        CashSummary.fromJson(m['summary']),
      );
}
