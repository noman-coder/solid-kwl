import 'package:url_launcher/url_launcher.dart';

/// App ke andar dikhne wala naam (phone ke icon ka naam workflow ke APP_NAME se aata hai).
const String kAppName = 'Vendor App';

/// App ka version (pubspec.yaml ke version se milana).
const String kAppVersion = '0.11.0 (12)';

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

/// "14:05" (phone ke local waqt mein). Parse na ho to khali.
String clockText(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final h = d.hour.toString().padLeft(2, '0');
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// "24 Nov, 14:05" (phone ke local waqt mein). Parse na ho to khali.
String dateTimeText(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  return '${d.day} ${_months[d.month - 1]}, ${clockText(iso)}';
}

/// "2026-11-05" -> "5 Nov 2026" (sirf tareekh, time zone ka koi asar nahi). Parse na ho to khali.
String dateText(String ymd) {
  final d = DateTime.tryParse(ymd);
  if (d == null) return '';
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// DateTime -> "2026-11-05" (server ko tareekh bhejne ke liye).
String ymdOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "5 min pehle", "2 ghante pehle", "3 din pehle" (1 din se purana ho to tareekh). Parse na ho to khali.
String agoText(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'abhi abhi';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min pehle';
  if (diff.inHours < 24) return '${diff.inHours} ghante pehle';
  if (diff.inDays < 7) return '${diff.inDays} din pehle';
  return dateTimeText(iso);
}

/// Bahar ka link / phone dialer kholo. Na khule to false.
Future<bool> openUrl(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
