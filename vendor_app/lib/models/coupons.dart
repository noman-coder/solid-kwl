import '../utils.dart';

/// Coupon ki qism (server ke `discount_type` jaisi).
const String kCouponPercent = 'percent';
const String kCouponFixed = 'fixed';
const String kCouponFreeDelivery = 'free_delivery';

/// Server ka `status`: active | paused | scheduled | expired | used_up
String couponStatusText(String status) {
  switch (status) {
    case 'active':
      return 'Chalu';
    case 'paused':
      return 'Band';
    case 'scheduled':
      return 'Jald shuru';
    case 'expired':
      return 'Expire';
    case 'used_up':
      return 'Poora ho gaya';
    default:
      return status;
  }
}

/// "50% off (max Rs 150)" / "Rs 100 off" / "Free delivery" - preview aur form ke liye.
String couponLabel({
  required String type,
  required double value,
  double? maxDiscount,
}) {
  if (type == kCouponPercent) {
    final base = '${numText(value)}% off';
    return (maxDiscount != null && maxDiscount > 0) ? '$base (max ${rs(maxDiscount)})' : base;
  }
  if (type == kCouponFixed) return '${rs(value)} off';
  return 'Free delivery';
}

class Coupon {
  final int id;
  final String code;
  final String title;
  final String label;
  final String discountType;
  final double value;
  final double? maxDiscount;
  final double minOrder;
  final int? usageLimit;
  final int perCustomerLimit;
  final bool firstOrderOnly;

  /// "YYYY-MM-DD" (khali = koi hadd nahi).
  final String validFrom;
  final String validUntil;
  final bool isActive;
  final String status;
  final int used;

  /// null = be-had.
  final int? remaining;

  /// Ab tak diya gaya discount + delivery maaf (Rs).
  final double given;

  /// Istemal ho chuka: code / type / value ab nahi badal sakte.
  final bool coreLocked;
  final String shareText;

  const Coupon({
    required this.id,
    required this.code,
    required this.title,
    required this.label,
    required this.discountType,
    required this.value,
    required this.maxDiscount,
    required this.minOrder,
    required this.usageLimit,
    required this.perCustomerLimit,
    required this.firstOrderOnly,
    required this.validFrom,
    required this.validUntil,
    required this.isActive,
    required this.status,
    required this.used,
    required this.remaining,
    required this.given,
    required this.coreLocked,
    required this.shareText,
  });

  factory Coupon.fromJson(dynamic j) {
    final m = asMap(j);
    final limit = m['usage_limit'];
    final rem = m['remaining'];
    final maxD = m['max_discount'];
    return Coupon(
      id: toI(m['id']),
      code: s(m['code']),
      title: s(m['title']),
      label: s(m['label']),
      discountType: s(m['discount_type']).isEmpty ? kCouponPercent : s(m['discount_type']),
      value: toD(m['value']),
      maxDiscount: maxD == null ? null : toD(maxD),
      minOrder: toD(m['min_order']),
      usageLimit: limit == null ? null : toI(limit),
      perCustomerLimit: toI(m['per_customer_limit'], 1),
      firstOrderOnly: m['first_order_only'] == true,
      validFrom: s(m['valid_from']),
      validUntil: s(m['valid_until']),
      isActive: m['is_active'] != false,
      status: s(m['status']),
      used: toI(m['used']),
      remaining: rem == null ? null : toI(rem),
      given: toD(m['given']),
      coreLocked: m['core_locked'] == true,
      shareText: s(m['share_text']),
    );
  }

  /// Chalne wala (customer is waqt laga sakta hai).
  bool get isLive => status == 'active';

  /// Expire / poora istemal - ab kabhi nahi chalega (jab tak vendor tareekh / limit na badle).
  bool get isFinished => status == 'expired' || status == 'used_up';

  /// 0.0 - 1.0 (limit ho tabhi, warna null).
  double? get usageFraction {
    final l = usageLimit;
    if (l == null || l <= 0) return null;
    return (used / l).clamp(0.0, 1.0).toDouble();
  }
}

class CouponSummary {
  final int total;
  final int max;
  final int active;
  final int scheduled;
  final int expired;
  final int paused;
  final int usedTotal;
  final double givenTotal;

  const CouponSummary({
    this.total = 0,
    this.max = 50,
    this.active = 0,
    this.scheduled = 0,
    this.expired = 0,
    this.paused = 0,
    this.usedTotal = 0,
    this.givenTotal = 0,
  });

  factory CouponSummary.fromJson(dynamic j) {
    final m = asMap(j);
    return CouponSummary(
      total: toI(m['total']),
      max: toI(m['max'], 50),
      active: toI(m['active']),
      scheduled: toI(m['scheduled']),
      expired: toI(m['expired']),
      paused: toI(m['paused']),
      usedTotal: toI(m['used_total']),
      givenTotal: toD(m['given_total']),
    );
  }
}

/// GET /api/vendor/coupons/ ka jawab (aur har badlav ke baad ki taza list).
class CouponsPage {
  final CouponSummary summary;
  final List<Coupon> coupons;
  const CouponsPage(this.summary, this.coupons);

  factory CouponsPage.fromJson(Map<String, dynamic> m) => CouponsPage(
        CouponSummary.fromJson(m['summary']),
        listOfMaps(m['coupons']).map(Coupon.fromJson).toList(),
      );
}

/// Create / edit / toggle / delete ka natija.
class CouponActionResult {
  final String message;
  final Coupon? coupon;
  final bool deleted;
  final bool duplicate;
  final CouponsPage page;
  const CouponActionResult({
    required this.message,
    required this.coupon,
    required this.deleted,
    required this.duplicate,
    required this.page,
  });

  factory CouponActionResult.fromJson(Map<String, dynamic> m) => CouponActionResult(
        message: s(m['message']),
        coupon: m['coupon'] is Map ? Coupon.fromJson(m['coupon']) : null,
        deleted: m['deleted'] == true,
        duplicate: m['duplicate'] == true,
        page: CouponsPage.fromJson(m),
      );
}
