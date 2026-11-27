import '../utils.dart';

/// Phase V16: `GET /api/vendor/profile/` ka `profile` hissa.
class VendorProfileData {
  final String storeName;
  final String ownerName;
  final String phone; // login ID - badalta nahi
  final String email;
  final String city;
  final String address;
  final bool approved;
  final double commissionPercent;
  final String joined; // ISO
  final String lastLogin; // ISO
  final int openOrders; // chal rahe orders (account delete inhi ke baad)
  final bool canDelete;

  const VendorProfileData({
    required this.storeName,
    required this.ownerName,
    required this.phone,
    required this.email,
    required this.city,
    required this.address,
    required this.approved,
    required this.commissionPercent,
    required this.joined,
    required this.lastLogin,
    required this.openOrders,
    required this.canDelete,
  });

  factory VendorProfileData.fromJson(Map<String, dynamic> j) => VendorProfileData(
        storeName: s(j['store_name']),
        ownerName: s(j['owner_name']),
        phone: s(j['phone']),
        email: s(j['email']),
        city: s(j['city']),
        address: s(j['address']),
        approved: j['approved'] == true,
        commissionPercent: toD(j['commission_percent']),
        joined: s(j['joined']),
        lastLogin: s(j['last_login']),
        openOrders: toI(j['open_orders']),
        canDelete: j['can_delete'] != false,
      );
}

/// Madad: company ka phone / email, WhatsApp link, privacy policy aur account delete ke public pages.
class SupportInfo {
  final String name;
  final String phone;
  final String email;
  final String whatsappUrl;
  final String privacyUrl;
  final String deleteUrl;

  const SupportInfo({
    this.name = '',
    this.phone = '',
    this.email = '',
    this.whatsappUrl = '',
    this.privacyUrl = '',
    this.deleteUrl = '',
  });

  factory SupportInfo.fromJson(Map<String, dynamic> j) => SupportInfo(
        name: s(j['name']),
        phone: s(j['phone']),
        email: s(j['email']),
        whatsappUrl: s(j['whatsapp_url']),
        privacyUrl: s(j['privacy_url']),
        deleteUrl: s(j['delete_url']),
      );

  bool get hasAny => phone.isNotEmpty || email.isNotEmpty || whatsappUrl.isNotEmpty;
}

/// Profile screen ka poora jawab (profile + support + taza vendor).
class ProfilePage {
  final VendorProfileData profile;
  final SupportInfo support;
  final String message;

  const ProfilePage({required this.profile, required this.support, this.message = ''});

  factory ProfilePage.fromJson(Map<String, dynamic> j) => ProfilePage(
        profile: VendorProfileData.fromJson(asMap(j['profile'])),
        support: SupportInfo.fromJson(asMap(j['support'])),
        message: s(j['message']),
      );
}
