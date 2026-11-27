import '../utils.dart';

/// Rider ka cash handover (pending / confirmed / rejected).
class Handover {
  final int id;
  final String receiver; // admin / vendor
  final int? vendorId;
  final String vendorName;
  final double amount;
  final String note;
  final String status; // pending / confirmed / rejected
  final String rejectReason;
  final String createdAt;
  final String decidedAt;

  const Handover({
    required this.id,
    required this.receiver,
    required this.vendorId,
    required this.vendorName,
    required this.amount,
    required this.note,
    required this.status,
    required this.rejectReason,
    required this.createdAt,
    required this.decidedAt,
  });

  factory Handover.fromJson(Map<String, dynamic> m) => Handover(
        id: toI(m['id']),
        receiver: s(m['receiver']),
        vendorId: m['vendor_id'] == null ? null : toI(m['vendor_id']),
        vendorName: s(m['vendor_name']),
        amount: toD(m['amount']) ?? 0,
        note: s(m['note']),
        status: s(m['status']),
        rejectReason: s(m['reject_reason']),
        createdAt: s(m['created_at']),
        decidedAt: s(m['decided_at']),
      );

  bool get isPending => status == 'pending';
  bool get isConfirmed => status == 'confirmed';
  bool get isRejected => status == 'rejected';

  String get toWhom => receiver == 'vendor'
      ? (vendorName.isEmpty ? 'Vendor' : vendorName)
      : 'Admin';
}

/// Rider ke hisab ki entry: cash_in (cash jama hua) ya payout (kamai ada hui).
class SettlementRow {
  final int id;
  final String kind;
  final double amount;
  final String note;
  final String createdAt;
  const SettlementRow(this.id, this.kind, this.amount, this.note, this.createdAt);

  factory SettlementRow.fromJson(Map<String, dynamic> m) => SettlementRow(
        toI(m['id']),
        s(m['kind']),
        toD(m['amount']) ?? 0,
        s(m['note']),
        s(m['created_at']),
      );

  bool get isPayout => kind == 'payout';
}

/// Vendor-wise cash: kitna collect hua, kitna de diya, kitna baqi.
class VendorCash {
  final int? vendorId; // null = shop ke apne orders
  final String name;
  final int orders;
  final double collected;
  final double handedToVendor;
  final double pendingToVendor;
  final double balance;

  const VendorCash({
    required this.vendorId,
    required this.name,
    required this.orders,
    required this.collected,
    required this.handedToVendor,
    required this.pendingToVendor,
    required this.balance,
  });

  factory VendorCash.fromJson(Map<String, dynamic> m) => VendorCash(
        vendorId: m['vendor_id'] == null ? null : toI(m['vendor_id']),
        name: s(m['name']),
        orders: toI(m['orders']),
        collected: toD(m['collected']) ?? 0,
        handedToVendor: toD(m['handed_to_vendor']) ?? 0,
        pendingToVendor: toD(m['pending_to_vendor']) ?? 0,
        balance: toD(m['balance']) ?? 0,
      );

  String get title => name.isNotEmpty ? name : (vendorId == null ? 'Shop ke apne orders' : 'Vendor #$vendorId');
}

/// Handover mein chunne wala vendor.
class VendorOption {
  final int id;
  final String name;
  const VendorOption(this.id, this.name);
}

/// GET /api/rider/wallet/ ka jawab.
class WalletData {
  final double cashInHand;
  final double pendingHandover;
  final double availableToHandover;
  final double cashCollected;
  final double cashDeposited;
  final double earned;
  final double paidOut;
  final double due;
  final double cashLimit;
  final bool limitReached;
  final List<VendorOption> vendors;
  final List<VendorCash> vendorWise;
  final List<SettlementRow> settlements;
  final List<Handover> handovers;

  const WalletData({
    required this.cashInHand,
    required this.pendingHandover,
    required this.availableToHandover,
    required this.cashCollected,
    required this.cashDeposited,
    required this.earned,
    required this.paidOut,
    required this.due,
    required this.cashLimit,
    required this.limitReached,
    required this.vendors,
    required this.vendorWise,
    required this.settlements,
    required this.handovers,
  });

  factory WalletData.fromJson(Map<String, dynamic> m) => WalletData(
        cashInHand: toD(m['cash_in_hand']) ?? 0,
        pendingHandover: toD(m['pending_handover']) ?? 0,
        availableToHandover: toD(m['available_to_handover']) ?? 0,
        cashCollected: toD(m['cash_collected']) ?? 0,
        cashDeposited: toD(m['cash_deposited']) ?? 0,
        earned: toD(m['earned']) ?? 0,
        paidOut: toD(m['paid_out']) ?? 0,
        due: toD(m['due']) ?? 0,
        cashLimit: toD(m['cash_limit']) ?? 0,
        limitReached: m['limit_reached'] == true,
        vendors: listOfMaps(m['vendors'])
            .map((v) => VendorOption(toI(v['vendor_id']), s(v['name'])))
            .toList(),
        vendorWise: listOfMaps(m['vendor_wise']).map(VendorCash.fromJson).toList(),
        settlements: listOfMaps(m['settlements']).map(SettlementRow.fromJson).toList(),
        handovers: listOfMaps(m['handovers']).map(Handover.fromJson).toList(),
      );

  bool get hasPending => handovers.any((h) => h.isPending);
  bool get canHandover => availableToHandover > 0;

  /// Vendor ka baqi balance (handover screen ke hint ke liye).
  double balanceOf(int vendorId) {
    for (final v in vendorWise) {
      if (v.vendorId == vendorId) return v.balance;
    }
    return 0;
  }
}
