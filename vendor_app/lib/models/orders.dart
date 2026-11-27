import '../utils.dart';

/// Order ka ek item (naam, miqdar, rate).
class OrderItem {
  final String name;
  final double qty;
  final double price;
  final double total;
  const OrderItem(this.name, this.qty, this.price, this.total);

  factory OrderItem.fromJson(Map<String, dynamic> m) =>
      OrderItem(s(m['name']), toD(m['qty']), toD(m['price']), toD(m['total']));

  /// "2 x Atta"
  String get line => '${numText(qty)} x $name';
}

class OrderCustomer {
  final String name;
  final String phone;
  final String address;
  const OrderCustomer(this.name, this.phone, this.address);

  factory OrderCustomer.fromJson(dynamic j) {
    final m = asMap(j);
    return OrderCustomer(s(m['name']), s(m['phone']), s(m['address']));
  }
}

class OrderPayment {
  final String method;
  final bool isCod;
  final String label; // COD / Online
  const OrderPayment(this.method, this.isCod, this.label);

  factory OrderPayment.fromJson(dynamic j) {
    final m = asMap(j);
    final cod = m['is_cod'] != false; // na ho to COD maano (web jaisa)
    final label = s(m['label']);
    return OrderPayment(s(m['method']), cod, label.isEmpty ? (cod ? 'COD' : 'Online') : label);
  }
}

/// Rider / delivery ki chhoti info (rider assign ho tab).
class OrderDelivery {
  final String type;
  final String status;
  final String riderName;
  final String riderPhone;
  const OrderDelivery(this.type, this.status, this.riderName, this.riderPhone);

  factory OrderDelivery.fromJson(Map<String, dynamic> m) =>
      OrderDelivery(s(m['type']), s(m['status']), s(m['rider_name']), s(m['rider_phone']));
}

/// Orders tab ke teen hisse (server ke `ORDER_TABS` jaise).
const List<String> kOrderTabs = ['new', 'active', 'done'];
const Map<String, String> kOrderTabLabels = {
  'new': 'Naye',
  'active': 'Chal rahe',
  'done': 'Mukammal',
};

/// Vendor ka ek order (list card ke liye).
class VendorOrder {
  final int id;
  final String orderNo;
  final String status;
  final String statusLabel;
  final String tab;
  final String createdAt;
  final OrderCustomer customer;
  final int itemsCount;
  final double itemsQty;
  final List<OrderItem> items;
  final int itemsMore;
  final double subtotal;
  final double deliveryFee;
  final double discount;
  final double total;
  final OrderPayment payment;
  final String notes;
  final int? prepMinutes;
  final String rejectReason;
  final OrderDelivery? delivery;
  final List<String> actions;

  const VendorOrder({
    required this.id,
    required this.orderNo,
    required this.status,
    required this.statusLabel,
    required this.tab,
    required this.createdAt,
    required this.customer,
    required this.itemsCount,
    required this.itemsQty,
    required this.items,
    required this.itemsMore,
    required this.subtotal,
    required this.deliveryFee,
    required this.discount,
    required this.total,
    required this.payment,
    required this.notes,
    required this.prepMinutes,
    required this.rejectReason,
    required this.delivery,
    required this.actions,
  });

  factory VendorOrder.fromJson(Map<String, dynamic> m) {
    final prep = m['prep_minutes'];
    return VendorOrder(
      id: toI(m['id']),
      orderNo: s(m['order_no']),
      status: s(m['status']),
      statusLabel: s(m['status_label']),
      tab: s(m['tab']),
      createdAt: s(m['created_at']),
      customer: OrderCustomer.fromJson(m['customer']),
      itemsCount: toI(m['items_count']),
      itemsQty: toD(m['items_qty']),
      items: listOfMaps(m['items_preview']).map(OrderItem.fromJson).toList(),
      itemsMore: toI(m['items_more']),
      subtotal: toD(m['subtotal']),
      deliveryFee: toD(m['delivery_fee']),
      discount: toD(m['discount']),
      total: toD(m['total']),
      payment: OrderPayment.fromJson(m['payment']),
      notes: s(m['notes']),
      prepMinutes: prep == null ? null : toI(prep),
      rejectReason: s(m['reject_reason']),
      delivery: m['delivery'] is Map ? OrderDelivery.fromJson(asMap(m['delivery'])) : null,
      actions: (m['actions'] is List) ? (m['actions'] as List).map((e) => s(e)).toList() : <String>[],
    );
  }

  bool can(String action) => actions.contains(action);

  bool get isNew => status == 'pending';
}

class RejectReason {
  final String code;
  final String label;
  const RejectReason(this.code, this.label);

  factory RejectReason.fromJson(Map<String, dynamic> m) => RejectReason(s(m['code']), s(m['label']));
}

/// `GET /api/vendor/orders/` ka jawab (ek page).
class OrdersPage {
  final String tab;
  final int page;
  final bool hasMore;
  final Map<String, int> counts;
  final List<VendorOrder> orders;
  final List<RejectReason> rejectReasons;
  final List<int> prepOptions;

  const OrdersPage({
    required this.tab,
    required this.page,
    required this.hasMore,
    required this.counts,
    required this.orders,
    required this.rejectReasons,
    required this.prepOptions,
  });

  factory OrdersPage.fromJson(Map<String, dynamic> j) => OrdersPage(
        tab: s(j['tab']),
        page: toI(j['page'], 1),
        hasMore: j['has_more'] == true,
        counts: parseCounts(j['counts']),
        orders: listOfMaps(j['orders']).map(VendorOrder.fromJson).toList(),
        rejectReasons: listOfMaps(j['reject_reasons']).map(RejectReason.fromJson).toList(),
        prepOptions: (j['prep_options'] is List)
            ? (j['prep_options'] as List).map((e) => toI(e)).where((e) => e > 0).toList()
            : <int>[],
      );
}

/// `{new: 2, active: 3, done: 9}` -> Map.
Map<String, int> parseCounts(dynamic j) {
  final m = asMap(j);
  return {for (final k in kOrderTabs) k: toI(m[k])};
}

/// Accept / reject / ready / delivered ka natija.
class OrderActionResult {
  final String message;
  final VendorOrder? order;
  final String nextTab;
  final Map<String, int> counts;
  const OrderActionResult(this.message, this.order, this.nextTab, this.counts);

  factory OrderActionResult.fromJson(Map<String, dynamic> j) => OrderActionResult(
        s(j['message']),
        j['order'] is Map ? VendorOrder.fromJson(asMap(j['order'])) : null,
        s(j['next_tab']),
        parseCounts(j['counts']),
      );
}

/// Halka poll: naye orders ki ginti + sab se naya order id.
class OrdersPoll {
  final int newCount;
  final int latestId;
  const OrdersPoll(this.newCount, this.latestId);

  factory OrdersPoll.fromJson(Map<String, dynamic> j) => OrdersPoll(toI(j['new']), toI(j['latest_id']));
}
