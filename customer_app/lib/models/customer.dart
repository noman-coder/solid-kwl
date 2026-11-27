import '../utils.dart';

/// Server ke `customer` object (api/customer/me/, login, register) ka app wala roop.
class Customer {
  final int id;
  final String code;
  final String name;
  final String phone;
  final String email;
  final bool phoneVerified;
  final bool emailVerified;

  /// Bharosay-mand customer: order par OTP nahi maangta (server rule).
  final bool trusted;
  final String language;
  final String photo;
  final String city;
  final String address;
  final String memberSince;

  /// Phone mein save karne ke liye asli JSON.
  final Map<String, dynamic> raw;

  const Customer({
    required this.id,
    required this.code,
    required this.name,
    required this.phone,
    required this.email,
    required this.phoneVerified,
    required this.emailVerified,
    required this.trusted,
    required this.language,
    required this.photo,
    required this.city,
    required this.address,
    required this.memberSince,
    required this.raw,
  });

  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: toI(j['id']),
        code: s(j['code']),
        name: s(j['name']),
        phone: s(j['phone']),
        email: s(j['email']),
        phoneVerified: toB(j['phone_verified']),
        emailVerified: toB(j['email_verified']),
        trusted: toB(j['trusted']),
        language: s(j['language']),
        photo: s(j['photo']),
        city: s(j['city']),
        address: s(j['address']),
        memberSince: s(j['member_since']),
        raw: j,
      );

  /// Pehla naam ("Ali Raza" -> "Ali"); naam khali ho to "Dost".
  String get firstName {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.isEmpty || parts.first.isEmpty ? 'Dost' : parts.first;
  }

  /// Avatar ka pehla harf.
  String get initial {
    final t = name.trim();
    if (t.isEmpty) return '?';
    return String.fromCharCode(t.runes.first).toUpperCase();
  }
}

/// `api/customer/me/` ka poora jawab.
class MeResult {
  final Customer customer;
  final bool orderOtpRequired;
  final bool orderVerified;
  const MeResult(this.customer, this.orderOtpRequired, this.orderVerified);
}

/// Login / register ka natija: customer + server ka khush-aamdeed message (ho to).
class AuthResult {
  final Customer customer;
  final String message;
  const AuthResult(this.customer, this.message);
}

/// `api/customer/otp/send/` ka jawab.
class OtpSendResult {
  /// true = customer bharosay-mand hai, OTP ki zaroorat nahi.
  final bool skip;
  final String email;
  final String message;
  final int resendAfter;
  final bool emailSent;
  const OtpSendResult({
    required this.skip,
    required this.email,
    required this.message,
    required this.resendAfter,
    required this.emailSent,
  });
}
