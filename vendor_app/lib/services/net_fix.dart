import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'api.dart' show kDefaultServer;

/// ISP ka DNS kharab / block ho (site not found) to bhi app chale.
/// 1) Normal DNS try hota hai. Fail ho to Cloudflare / Google ka DoH (HTTPS DNS) se IP nikalta hai.
/// 2) Apne server ke liye DoH pehle try hota hai (ISP ka ghalat jawab bhi bypass ho jata hai).
/// Sab http / Image.network / CachedNetworkImage requests is se guzarti hain (HttpOverrides).
///
/// HTTPS ke liye ek chhota local CONNECT tunnel (127.0.0.1) chalta hai: wo DoH se IP nikal kar
/// TCP connect karta hai aur bytes seedhe aage pipe kar deta hai. TLS handshake / SNI / certificate check
/// HttpClient khud domain ke naam par karta hai, isliye safety kam nahi hoti.
/// (Dart ka ConnectionTask ab final class hai, is liye custom task banana mumkin nahi; tunnel us se bachata hai.)
///
/// main() mein:  HttpOverrides.global = DnsFallbackOverrides();  await DnsFallbackOverrides.start();
class DnsFallbackOverrides extends HttpOverrides {
  /// In hosts ke liye DoH pehle (apna server). Default: app ka apna server (api.dart se).
  DnsFallbackOverrides({Set<String>? dohFirstHosts}) {
    _dohFirst = dohFirstHosts ?? {Uri.parse(kDefaultServer).host};
  }

  static Set<String> _dohFirst = {};
  static final Map<String, _Cached> _cache = {};
  static ServerSocket? _server;
  static Future<void>? _starting;

  /// Local tunnel chalu karta hai (dobara bulane par kuch nahi karta). Fail ho to khamoshi se band;
  /// us surat mein HTTPS normal DNS se chalta hai.
  static Future<void> start() => _starting ??= _bind();

  static Future<void> _bind() async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = s;
      s.listen(_onClient, onError: (_) {}, cancelOnError: false);
    } catch (_) {
      _server = null;
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (Uri url) {
      final s = _server;
      if (s != null && url.scheme == 'https' && InternetAddress.tryParse(url.host) == null) {
        return 'PROXY 127.0.0.1:${s.port}';
      }
      return 'DIRECT';
    };
    client.connectionFactory = (Uri url, String? proxyHost, int? proxyPort) async {
      if (proxyHost != null) {
        // Hamara local tunnel (ya koi aur proxy): seedha TCP.
        final addrs = await _resolve(proxyHost);
        return Socket.startConnect(addrs.first, proxyPort ?? 80);
      }
      if (url.scheme == 'https') {
        // Tunnel chalu na ho (ya IP host): normal secure connect.
        final ConnectionTask<Socket> t = await SecureSocket.startConnect(
          url.host,
          url.port,
          context: context,
        );
        return t;
      }
      final addrs = await _resolve(url.host);
      return Socket.startConnect(addrs.first, url.port);
    };
    return client;
  }

  // ------------------------------------------------------------------ CONNECT tunnel

  static void _onClient(Socket client) {
    final buf = BytesBuilder(copy: false);
    Socket? remote;
    var connecting = false;
    late StreamSubscription<Uint8List> sub;

    void closeAll() {
      try {
        client.destroy();
      } catch (_) {}
      try {
        remote?.destroy();
      } catch (_) {}
    }

    sub = client.listen(
      (data) async {
        final r = remote;
        if (r != null) {
          r.add(data);
          return;
        }
        if (connecting) {
          buf.add(data);
          return;
        }
        buf.add(data);
        final bytes = buf.toBytes();
        final end = _headerEnd(bytes);
        if (end < 0) {
          if (bytes.length > 8192) closeAll();
          return;
        }
        connecting = true;
        final head = latin1.decode(bytes.sublist(0, end));
        final m = RegExp(r'^CONNECT\s+(\S+):(\d+)\s', caseSensitive: false).firstMatch(head);
        if (m == null) {
          client.add(latin1.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
          closeAll();
          return;
        }
        final host = m.group(1)!;
        final port = int.parse(m.group(2)!);
        sub.pause();
        try {
          final s = await _connectTo(host, port);
          remote = s;
          client.add(latin1.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
          // CONNECT ke baad ka koi extra byte (aam taur par nahi hota) aage bhejo.
          if (bytes.length > end) s.add(bytes.sublist(end));
          s.listen(
            client.add,
            onDone: closeAll,
            onError: (_) => closeAll(),
            cancelOnError: true,
          );
          sub.resume();
        } catch (_) {
          try {
            client.add(latin1.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
          } catch (_) {}
          closeAll();
        }
      },
      onDone: closeAll,
      onError: (_) => closeAll(),
      cancelOnError: true,
    );
  }

  static int _headerEnd(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i + 4;
    }
    return -1;
  }

  static Future<Socket> _connectTo(String host, int port) async {
    final addrs = await _resolve(host);
    Object? last;
    for (final a in addrs) {
      try {
        return await Socket.connect(a, port, timeout: const Duration(seconds: 10));
      } catch (e) {
        last = e;
      }
    }
    throw last ?? SocketException('connect nahi hua: $host');
  }

  // ------------------------------------------------------------------ DNS

  static Future<List<InternetAddress>> _resolve(String host) async {
    // Seedha IP ho (jaise 1.1.1.1) to DNS ki zaroorat nahi.
    final direct = InternetAddress.tryParse(host);
    if (direct != null) return [direct];

    final fresh = _cache[host];
    if (fresh != null && fresh.valid) return fresh.addrs;

    final dohFirst = _dohFirst.contains(host);
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

  static List<InternetAddress> _store(String host, List<InternetAddress> a) {
    _cache[host] = _Cached(a);
    return a;
  }

  /// DoH: pehle Cloudflare (1.1.1.1), phir Google (8.8.8.8). Dono seedhe IP par, DNS ke baghair.
  static Future<List<InternetAddress>> _doh(String host) async {
    final servers = <Uri>[
      Uri(scheme: 'https', host: '1.1.1.1', path: '/dns-query', queryParameters: {'name': host, 'type': 'A'}),
      Uri(scheme: 'https', host: '8.8.8.8', path: '/resolve', queryParameters: {'name': host, 'type': 'A'}),
    ];
    for (final uri in servers) {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      try {
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
