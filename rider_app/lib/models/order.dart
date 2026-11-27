import '../utils.dart';

/// Store ya customer ki jagah (naam, pata, phone, map ke lat/lng).
class Place {
  final String name;
  final String address;
  final String phone;
  final double? lat;
  final double? lng;

  const Place({this.name = '', this.address = '', this.phone = '', this.lat, this.lng});

  factory Place.fromJson(dynamic j) {
    final m = asMap(j);
    return Place(
      name: s(m['name']),
      address: s(m['address']),
      phone: s(m['phone']),
      lat: toD(m['lat']),
      lng: toD(m['lng']),
    );
  }

  bool get hasCoords => lat != null && lng != null;

  /// Google Maps link: lat/lng ho to seedha direction, warna address search.
  String get mapUrl {
    if (hasCoords) return 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng';
    return 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}';
  }
}

class OrderItem {
  final String name;
  final num qty;
  const OrderItem(this.name, this.qty);

  factory OrderItem.fromJson(Map<String, dynamic> m) =>
      OrderItem(s(m['name']), m['qty'] is num ? m['qty'] as num : toD(m['qty']) ?? 0);
}

/// Rider ke liye aik order (offer ya mera order). Purani API ki keys hi use hoti hain.
class RiderOrder {
  final int id;
  final String orderNo;
  final String status; // mere orders mein delivery status: assigned / picked_up / in_transit
  final int? vendorId;
  final Place store;
  final Place customer;
  final List<OrderItem> items;
  final double total;
  final bool isCod;
  final double fee;

  const RiderOrder({
    required this.id,
    required this.orderNo,
    required this.status,
    required this.vendorId,
    required this.store,
    required this.customer,
    required this.items,
    required this.total,
    required this.isCod,
    required this.fee,
  });

  factory RiderOrder.fromJson(Map<String, dynamic> m) => RiderOrder(
        id: toI(m['id']),
        orderNo: s(m['order_no']),
        status: s(m['status']),
        vendorId: m['vendor_id'] == null ? null : toI(m['vendor_id']),
        store: Place.fromJson(m['store']),
        customer: Place.fromJson(m['customer']),
        items: listOfMaps(m['items']).map(OrderItem.fromJson).toList(),
        total: toD(m['total']) ?? 0,
        isCod: m['is_cod'] == true,
        fee: toD(m['fee']) ?? 0,
      );

  bool get isAssigned => status == 'assigned';
}
