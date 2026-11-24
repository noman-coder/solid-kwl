import '../utils.dart';

class Review {
  final int stars;
  final String comment;
  final String orderNo;
  final String at;
  const Review(this.stars, this.comment, this.orderNo, this.at);

  factory Review.fromJson(Map<String, dynamic> m) =>
      Review(toI(m['stars']), s(m['comment']), s(m['order_no']), s(m['at']));
}

/// GET /api/rider/profile/ ka jawab (profile + rating + reviews).
class ProfileData {
  final int id;
  final String name;
  final String phone;
  final String vehicle;
  final bool online;
  final double fee;
  final String joined;
  final int totalDeliveries;
  final double? ratingAvg;
  final int ratingCount;
  final List<Review> reviews;

  const ProfileData({
    required this.id,
    required this.name,
    required this.phone,
    required this.vehicle,
    required this.online,
    required this.fee,
    required this.joined,
    required this.totalDeliveries,
    required this.ratingAvg,
    required this.ratingCount,
    required this.reviews,
  });

  factory ProfileData.fromJson(dynamic j) {
    final m = asMap(j);
    final rating = asMap(m['rating']);
    return ProfileData(
      id: toI(m['id']),
      name: s(m['name']),
      phone: s(m['phone']),
      vehicle: s(m['vehicle']),
      online: m['online'] == true,
      fee: toD(m['fee']) ?? 0,
      joined: s(m['joined']),
      totalDeliveries: toI(m['total_deliveries']),
      ratingAvg: toD(rating['avg']),
      ratingCount: toI(rating['count']),
      reviews: listOfMaps(m['reviews']).map(Review.fromJson).toList(),
    );
  }
}
