import '../utils.dart';
import 'order.dart';

class StepInfo {
  final String key;
  final String label;
  final bool done;
  final String at;
  const StepInfo(this.key, this.label, this.done, this.at);

  factory StepInfo.fromJson(Map<String, dynamic> m) =>
      StepInfo(s(m['key']), s(m['label']), m['done'] == true, s(m['at']));
}

class TimelineEntry {
  final String title;
  final String description;
  final String at;
  const TimelineEntry(this.title, this.description, this.at);

  factory TimelineEntry.fromJson(Map<String, dynamic> m) =>
      TimelineEntry(s(m['title']), s(m['description']), s(m['at']));
}

/// GET /api/rider/orders/<id>/ ka jawab (rider ka apna order).
class OrderDetail {
  final RiderOrder order;
  final String deliveryStatus; // assigned / picked_up / in_transit / delivered / cancelled
  final double cashCollected;
  final String paymentMethod;
  final List<StepInfo> steps;
  final List<TimelineEntry> timeline;

  const OrderDetail({
    required this.order,
    required this.deliveryStatus,
    required this.cashCollected,
    required this.paymentMethod,
    required this.steps,
    required this.timeline,
  });

  factory OrderDetail.fromJson(Map<String, dynamic> m) => OrderDetail(
        order: RiderOrder.fromJson(m),
        deliveryStatus: s(m['delivery_status']),
        cashCollected: toD(m['cash_collected']) ?? 0,
        paymentMethod: s(m['payment_method']),
        steps: listOfMaps(m['steps']).map(StepInfo.fromJson).toList(),
        timeline: listOfMaps(m['timeline']).map(TimelineEntry.fromJson).toList(),
      );

  bool get isCancelled => deliveryStatus == 'cancelled';
  bool get isDelivered => deliveryStatus == 'delivered';
  bool get isAssigned => deliveryStatus == 'assigned';
  bool get isOnTheWay => deliveryStatus == 'picked_up' || deliveryStatus == 'in_transit';
}
