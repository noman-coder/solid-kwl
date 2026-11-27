import '../utils.dart';
import 'orders.dart';

/// Order ka ek poora item (detail screen): naam, miqdar, rate, total, photo.
class DetailItem {
  final String name;
  final double qty;
  final double price;
  final double total;
  final String? image;
  const DetailItem(this.name, this.qty, this.price, this.total, this.image);

  factory DetailItem.fromJson(Map<String, dynamic> m) {
    final img = s(m['image']);
    return DetailItem(s(m['name']), toD(m['qty']), toD(m['price']), toD(m['total']), img.isEmpty ? null : img);
  }
}

/// Status stepper ka ek qadam (Naya > Qubool > Tayyar > Raste mein > Deliver).
class StepInfo {
  final String key;
  final String label;
  final bool done;
  final bool failed;
  final String at;
  const StepInfo(this.key, this.label, this.done, this.failed, this.at);

  factory StepInfo.fromJson(Map<String, dynamic> m) =>
      StepInfo(s(m['key']), s(m['label']), m['done'] == true, m['failed'] == true, s(m['at']));
}

/// Order ki history ki ek line (rider mila, maal utha...).
class TimelineEntry {
  final String title;
  final String description;
  final String at;
  const TimelineEntry(this.title, this.description, this.at);

  factory TimelineEntry.fromJson(Map<String, dynamic> m) =>
      TimelineEntry(s(m['title']), s(m['description']), s(m['at']));
}

class RiderInfo {
  final String name;
  final String phone;
  final String vehicle;
  final String status;
  const RiderInfo(this.name, this.phone, this.vehicle, this.status);

  factory RiderInfo.fromJson(Map<String, dynamic> m) =>
      RiderInfo(s(m['name']), s(m['phone']), s(m['vehicle']), s(m['status']));
}

/// Is order par commission ka andaza (asli hisaab bill banne par).
class CommissionInfo {
  final double percent;
  final double base;
  final double amount;
  final double vendorGets;
  const CommissionInfo(this.percent, this.base, this.amount, this.vendorGets);

  factory CommissionInfo.fromJson(dynamic j) {
    final m = asMap(j);
    return CommissionInfo(toD(m['percent']), toD(m['base']), toD(m['amount']), toD(m['vendor_gets']));
  }
}

/// (latitude, longitude) - na ho to null.
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  static GeoPoint? from(dynamic j) {
    if (j is List && j.length >= 2 && j[0] is num && j[1] is num) {
      final la = (j[0] as num).toDouble();
      final ln = (j[1] as num).toDouble();
      if (la >= -90 && la <= 90 && ln >= -180 && ln <= 180) return GeoPoint(la, ln);
    }
    return null;
  }
}

/// `GET /api/vendor/orders/<id>/` ka jawab.
class OrderDetail {
  /// List wale card jaisi sab info (status, actions, payment, total ...). Actions isi se chalte hain.
  final VendorOrder order;
  final List<DetailItem> items;
  final List<StepInfo> steps;
  final List<TimelineEntry> timeline;
  final RiderInfo? rider;
  final CommissionInfo commission;
  final String couponCode;
  final double couponDiscount;
  final bool canTrack;
  final bool canAssignRider;
  final GeoPoint? customerPoint;
  final GeoPoint? storePoint;
  final String whatsappUrl;

  const OrderDetail({
    required this.order,
    required this.items,
    required this.steps,
    required this.timeline,
    required this.rider,
    required this.commission,
    required this.couponCode,
    required this.couponDiscount,
    required this.canTrack,
    required this.canAssignRider,
    required this.customerPoint,
    required this.storePoint,
    required this.whatsappUrl,
  });

  factory OrderDetail.fromJson(Map<String, dynamic> m) {
    final cust = asMap(m['customer']);
    final coupon = asMap(m['coupon']);
    final la = cust['lat'];
    final ln = cust['lng'];
    return OrderDetail(
      order: VendorOrder.fromJson(m),
      items: listOfMaps(m['items']).map(DetailItem.fromJson).toList(),
      steps: listOfMaps(m['steps']).map(StepInfo.fromJson).toList(),
      timeline: listOfMaps(m['timeline']).map(TimelineEntry.fromJson).toList(),
      rider: m['rider'] is Map ? RiderInfo.fromJson(asMap(m['rider'])) : null,
      commission: CommissionInfo.fromJson(m['commission']),
      couponCode: s(coupon['code']),
      couponDiscount: toD(coupon['discount']),
      canTrack: m['can_track'] == true,
      canAssignRider: m['can_assign_rider'] == true,
      customerPoint: GeoPoint.from([la, ln]),
      storePoint: GeoPoint.from(m['store_point']),
      whatsappUrl: s(m['whatsapp_url']),
    );
  }
}

/// `GET /api/vendor/orders/<id>/track/` ka jawab. `active == false` ho to map chhupa do.
class TrackData {
  final bool active;
  final String reason; // finished | no_rider | not_started
  final String message;
  final String riderName;
  final String riderPhone;
  final String status;
  final GeoPoint? pos;
  final GeoPoint? store;
  final GeoPoint? dest;
  final int? ageSec;
  final bool stale;
  final double? heading;

  const TrackData({
    required this.active,
    required this.reason,
    required this.message,
    required this.riderName,
    required this.riderPhone,
    required this.status,
    required this.pos,
    required this.store,
    required this.dest,
    required this.ageSec,
    required this.stale,
    required this.heading,
  });

  factory TrackData.fromJson(Map<String, dynamic> m) {
    final r = asMap(m['rider']);
    return TrackData(
      active: m['active'] == true,
      reason: s(m['reason']),
      message: s(m['message']),
      riderName: s(r['name']),
      riderPhone: s(r['phone']),
      status: s(m['status']),
      pos: GeoPoint.from(m['pos']),
      store: GeoPoint.from(m['store']),
      dest: GeoPoint.from(m['dest']),
      ageSec: m['age_sec'] is num ? (m['age_sec'] as num).toInt() : null,
      stale: m['stale'] != false,
      heading: m['heading'] is num ? (m['heading'] as num).toDouble() : null,
    );
  }
}

/// Rider dene ki list mein ek rider.
class RiderOption {
  final int id;
  final String name;
  final String phone;
  final String vehicle;
  final bool online;
  final int activeOrders;
  const RiderOption(this.id, this.name, this.phone, this.vehicle, this.online, this.activeOrders);

  factory RiderOption.fromJson(Map<String, dynamic> m) => RiderOption(
      toI(m['id']), s(m['name']), s(m['phone']), s(m['vehicle']), m['online'] == true, toI(m['active_orders']));
}

class RiderList {
  final bool canAssign;
  final int? currentRiderId;
  final List<RiderOption> riders;
  const RiderList(this.canAssign, this.currentRiderId, this.riders);

  factory RiderList.fromJson(Map<String, dynamic> m) => RiderList(
        m['can_assign'] == true,
        m['current_rider_id'] == null ? null : toI(m['current_rider_id']),
        listOfMaps(m['riders']).map(RiderOption.fromJson).toList(),
      );
}
