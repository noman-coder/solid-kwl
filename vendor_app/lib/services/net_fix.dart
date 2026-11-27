import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// ISP ka DNS kharab / block ho (site not found) to bhi app chale.
/// 1) Normal DNS try hota hai. Fail ho to Cloudflare / Google ka DoH (HTTPS DNS) se IP nikalta hai.
/// 2) Apne server ke liye DoH pehle try hota hai (ISP ka ghalat jawab bhi bypass ho jata hai).
/// Sab http / Image.network / CachedNetworkImage requests is se guzarti hain (HttpOverrides).
/// TLS certificate check waisa hi rehta hai (domain ke naam par), isliye safety kam nahi hoti.
class DnsFallbackOverrides extends HttpOverrides {
  /// In hosts ke liye DoH pehle (apna server).
  final Set<String> dohFirstHosts;
  DnsFallbackOverrides({this.dohFirstHosts = const {'khanewalconnect.store'}});

  static final Map<String, _Cached> _cache = {};

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (Uri url, String? proxyHost, int? proxyPort) async {
      final host = proxyHost ?? url.host;
      final port = proxyPort ?? url.port;
      final addrs = await _resolve(host);
      return Socket.startConnect(addrs.first, port);
    };
    return client;
  }

  Future<List<InternetAddress>> _resolve(String host) async {
    // Seedha IP ho (jaise 1.1.1.1) to DNS ki zaroorat nahi.
    final direct = InternetAddress.tryParse(host);
    if (direct != null) return [direct];

    final fresh = _cache[host];
    if (fresh != null && fresh.valid) return fresh.addrs;

    final dohFirst = dohFirstHosts.contains(host);
    if (dohFirst) {
      final d = await _doh(host);
      if (d.isNotEmpty) return _store(host, d);
    }
    try {
      final l = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
      if (l.isNotEmpty) return _store(host, l);
    } catch (_) {}
    if (!dohFirst) {
      final d = await _doh(host);
      if (d.isNotEmpty) return _store(host, d);
    }
    // Aakhri umeed: purana cache (expire ho chuka ho tab bhi).
    if (fresh != null) return fresh.addrs;
    throw SocketException('DNS resolve nahi hua: $host');
  }

  List<InternetAddress> _store(String host, List<InternetAddress> a) {
    _cache[host] = _Cached(a);
    return a;
  }

  /// DoH: pehle Cloudflare (1.1.1.1), phir Google (8.8.8.8). Dono seedhe IP par, DNS ke baghair.
  Future<List<InternetAddress>> _doh(String host) async {
    const servers = [
      'https://1.1.1.1/dns-query',
      'https://8.8.8.8/resolve',
    ];
    for (final base in servers) {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      try {
        final uri = Uri.parse('$base?name=${Uri.encodeQueryComponent(host)}&type=A');
        final req = await c.getUrl(uri).timeout(const Duration(seconds: 5));
        req.headers.set('accept', 'application/dns-json');
        final res = await req.close().timeout(const Duration(seconds: 5));
        if (res.statusCode != 200) continue;
        final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
        final json = jsonDecode(body);
        final answers = (json is Map ? json['Answer'] : null);
        if (answers is! List) continue;
        final out = <InternetAddress>[];
        for (final a in answers) {
          if (a is Map && a['type'] == 1) {
            final ip = InternetAddress.tryParse('${a['data']}');
            if (ip != null) out.add(ip);
          }
        }
        if (out.isNotEmpty) return out;
      } catch (_) {
        // agla DoH server try karo
      } finally {
        c.close(force: true);
      }
    }
    return const [];
  }
}

class _Cached {
  final List<InternetAddress> addrs;
  final DateTime at = DateTime.now();
  _Cached(this.addrs);
  bool get valid => DateTime.now().difference(at) < const Duration(minutes: 10);
}
