import 'package:url_launcher/url_launcher.dart';

/// App ke andar dikhne wala naam (phone ke icon ka naam workflow ke APP_NAME se aata hai).
/// Naam sirf workflow ke `APP_NAME` se aata hai (--dart-define=APP_NAME=...); na mile to yeh placeholder.
const String kAppName = String.fromEnvironment('APP_NAME', defaultValue: 'Customer App');

/// App ka version (pubspec.yaml ke version se milana).
const String kAppVersion = '1.0.0 (1)';

/// Kisi bhi value ko safe text banao (null -> '').
String s(dynamic v) => v == null ? '' : v.toString();

Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// JSON list ko [Map] list banao (ghalat / null par khali list).
List<Map<String, dynamic>> listOfMaps(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <Map<String, dynamic>>[];

double toD(dynamic v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim()) ?? fallback;
  return fallback;
}

int toI(dynamic v, [int fallback = 0]) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

bool toB(dynamic v) => v == true || v == 1 || v == '1' || v == 'true' || v == 'True';

/// 4500 -> "4,500", 12.5 -> "12.5"
String numText(dynamic v) {
  if (v is! num) return s(v);
  final isWhole = v == v.roundToDouble();
  final str = isWhole ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  final parts = str.split('.');
  final neg = parts[0].startsWith('-');
  final digits = neg ? parts[0].substring(1) : parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '${neg ? '-' : ''}$buf${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// "Rs 4,500"
String rs(dynamic v) => 'Rs ${numText(v)}';

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// "2026-11-05" -> "5 Nov 2026" (sirf tareekh). Parse na ho to khali.
String dateText(String ymd) {
  final d = DateTime.tryParse(ymd);
  if (d == null) return '';
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

// ------------------------------------------------------------------ form check (server jaisa hi rule)

/// Pakistani mobile: 03XXXXXXXXX / +923XXXXXXXXX / 923XXXXXXXXX (server `is_valid_phone` jaisa).
final RegExp _phoneRe = RegExp(r'^(\+92|92|0)?3\d{9}$');
bool isValidPhone(String v) => _phoneRe.hasMatch(v.replaceAll(' ', '').replaceAll('-', ''));

final RegExp _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
bool isValidEmail(String v) => _emailRe.hasMatch(v.trim());

const int kMinPassword = 8;

/// Password ki pehli kami (khali = theek). Server mein is se zyada sakht check bhi hai (aam passwords); wahan ka
/// message app mein saaf dikhta hai.
String? passwordProblem(String pw, List<String> hints) {
  if (pw.length < kMinPassword) return 'Password kam az kam $kMinPassword characters ka ho.';
  if (pw.length > 128) return 'Password 128 characters se lamba na ho.';
  if (!RegExp(r'[A-Za-z]').hasMatch(pw) || !RegExp(r'\d').hasMatch(pw)) {
    return 'Password mein kam az kam ek harf aur ek number ho.';
  }
  if (pw.split('').toSet().length <= 2) return 'Password mein sirf ek-do characters dohraye na hon.';
  final low = pw.toLowerCase();
  for (final h in hints) {
    final t = h.trim().toLowerCase();
    if (t.length >= 4 && low.contains(t)) return 'Password mein apna naam, phone ya username na ho.';
  }
  return null;
}

/// Bahar ka link / phone dialer kholo. Na khule to false.
Future<bool> openUrl(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
