import '../utils.dart';

/// Server ke `vendor` JSON (login / me) ka model.
class Vendor {
  final int id;
  final String name;
  final String phone;
  final String city;
  final bool approved;
  final double commissionPercent;
  final double rating;
  final int ratingCount;
  final String storeStatus;
  final bool isOpen;
  final bool locationVerified;
  final String? logo;

  const Vendor({
    required this.id,
    required this.name,
    required this.phone,
    required this.city,
    required this.approved,
    required this.commissionPercent,
    required this.rating,
    required this.ratingCount,
    required this.storeStatus,
    required this.isOpen,
    required this.locationVerified,
    this.logo,
  });

  factory Vendor.fromJson(Map<String, dynamic> j) => Vendor(
        id: toI(j['id']),
        name: s(j['name']),
        phone: s(j['phone']),
        city: s(j['city']),
        approved: j['approved'] == true,
        commissionPercent: toD(j['commission_percent']),
        rating: toD(j['rating']),
        ratingCount: toI(j['rating_count']),
        storeStatus: s(j['store_status']),
        isOpen: j['is_open'] == true,
        locationVerified: j['location_verified'] == true,
        logo: j['logo'] == null ? null : s(j['logo']),
      );

  String get initial => name.trim().isEmpty ? 'S' : name.trim().substring(0, 1).toUpperCase();
}
