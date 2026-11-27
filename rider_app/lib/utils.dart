import 'package:url_launcher/url_launcher.dart';

/// App ka version (pubspec.yaml ke version se milana).
const String kAppVersion = '1.6.0 (7)';

/// Kisi bhi value ko safe text banao (null -> '').
String s(dynamic v) => v == null ? '' : v.toString();

List<Map<String, dynamic>> listOfMaps(dynamic v) {
  if (v is! List) return <Map<String, dynamic>>[];
  return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
}

Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

double? toD(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

int toI(dynamic v, [int fallback = 0]) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

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

/// Bahar ka link / phone dialer kholo. Na khule to false.
Future<bool> openUrl(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// ISO tareekh (server se) ko local "23 Nov, 4:05 PM" bana do. Ghalat/khali ho to ''.
String fmtDateTime(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day} ${m[d.month - 1]}, $h12:$mm ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// Sirf tareekh: "23 Nov 2026"
String fmtDate(DateTime d) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]} ${d.year}';
}

/// Server ko bhejne wala format: YYYY-MM-DD
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Pakistani number se WhatsApp link: 0300... -> https://wa.me/92300...
String waUrl(String phone) {
  var d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('00')) d = d.substring(2);
  if (d.startsWith('0')) d = '92${d.substring(1)}';
  return 'https://wa.me/$d';
}
