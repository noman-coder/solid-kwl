import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'tracker.dart';

String _s(dynamic v) => v == null ? '' : v.toString();

List<Map<String, dynamic>> _list(dynamic v) {
  if (v is! List) return <Map<String, dynamic>>[];
  return v.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

String _num(dynamic v) {
  if (v is num) return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return _s(v);
}

class HomeScreen extends StatefulWidget {
  final Future<void> Function() onLogout;
  const HomeScreen({super.key, required this.onLogout});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  Timer? _timer;
  Map<String, dynamic> _profile = {};
  List<Map<String, dynamic>> _offers = [];
  List<Map<String, dynamic>> _mine = [];
  bool _online = false;
  bool _loading = true;
  bool _busy = false;
  bool _permAsked = false;
  int _lastOffers = -1;
  String? _error;
  String? _gpsWarn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final d = await Api.orders();
      if (!mounted) return;
      final offers = _list(d['offers']);
      final mine = _list(d['mine']);
      if (_lastOffers >= 0 && offers.length > _lastOffers) _alert();
      _lastOffers = offers.length;
      setState(() {
        _online = d['online'] == true;
        _offers = offers;
        _mine = mine;
        _profile = _map(d['profile']);
        _error = null;
        _loading = false;
      });
      await _syncTracking(d['tracking'] == true);
    } on ApiException catch (e) {
      if (e.status == 401) {
        await widget.onLogout();
        return;
      }
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  void _alert() {
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    _toast('🆕 Naya order available!');
  }

  Future<void> _syncTracking(bool need) async {
    if (need) {
      if (Tracker.running) return;
      if (_permAsked) return;
      _permAsked = true;
      final err = await Tracker.ensurePermissions();
      if (err != null) {
        if (mounted) setState(() => _gpsWarn = err);
        return;
      }
      await Tracker.start();
      if (mounted) setState(() => _gpsWarn = null);
    } else {
      _permAsked = false;
      if (Tracker.running) await Tracker.stop();
      if (_gpsWarn != null && mounted) setState(() => _gpsWarn = null);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _run(Future<String> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _toast(await job());
    } on ApiException catch (e) {
      if (e.status == 401) {
        await widget.onLogout();
        return;
      }
      _toast('❌ ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  Future<void> _toggleOnline(bool v) async {
    setState(() => _online = v);
    try {
      await Api.setOnline(v);
    } on ApiException catch (e) {
      _toast('❌ ${e.message}');
    }
    await _refresh();
  }

  Future<void> _confirmDeliver(Map<String, dynamic> o) async {
    final cod = o['is_cod'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Order #${_s(o['order_no'])} deliver?'),
        content: Text(cod
            ? 'Customer se COD Rs. ${_num(o['total'])} cash lena na bhulein.'
            : 'Online payment ho chuki hai - cash nahi lena.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Nahi')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Haan, deliver')),
        ],
      ),
    );
    if (ok == true) {
      await _run(() => Api.action(o['id'] as int, 'deliver'));
    }
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      _toast('Ye link khul nahi saka');
    }
  }

  String _mapUrl(String addr, dynamic lat, dynamic lng) {
    if (lat is num && lng is num) {
      return 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng';
    }
    return 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(addr)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_s(_profile['name']).isEmpty ? 'Rider' : _s(_profile['name'])),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Logout?'),
                  content: const Text('Logout par aap offline ho jayenge.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Nahi')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Logout')),
                  ],
                ),
              );
              if (ok == true) await widget.onLogout();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? ListView(children: const [SizedBox(height: 200), Center(child: CircularProgressIndicator())])
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _statusCard(),
                  if (_error != null)
                    Card(
                      color: Colors.red.shade50,
                      child: ListTile(
                        leading: const Icon(Icons.wifi_off, color: Colors.red),
                        title: Text(_error!),
                      ),
                    ),
                  if (_gpsWarn != null)
                    Card(
                      color: Colors.amber.shade100,
                      child: ListTile(
                        leading: const Icon(Icons.location_off),
                        title: Text(_gpsWarn!),
                        trailing: TextButton(
                          onPressed: () {
                            _permAsked = false;
                            _refresh();
                          },
                          child: const Text('Dobara'),
                        ),
                      ),
                    ),
                  _sectionTitle('Mere orders (${_mine.length})'),
                  if (_mine.isEmpty) const _Empty('Abhi koi active order nahi.'),
                  ..._mine.map((o) => _orderCard(o, offer: false)),
                  _sectionTitle('Naye orders (${_offers.length})'),
                  if (!_online)
                    const _Empty('Naye orders dekhne ke liye upar se Online hon.')
                  else if (_offers.isEmpty)
                    const _Empty('Abhi koi naya order nahi. Intezar karein...'),
                  ..._offers.map((o) => _orderCard(o, offer: true)),
                  const SizedBox(height: 40),
                ],
              ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
        child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      );

  Widget _statusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 14, color: _online ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_online ? 'Online' : 'Offline',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
                Switch(value: _online, onChanged: _busy ? null : _toggleOnline),
              ],
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat('Aaj deliveries', _num(_profile['today_deliveries'])),
                _stat('Aaj kamai', 'Rs ${_num(_profile['today_earned'])}'),
                _stat('Cash paas', 'Rs ${_num(_profile['cash_in_hand'])}'),
              ],
            ),
            if (Tracker.running)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.my_location, size: 16, color: Colors.green),
                    SizedBox(width: 6),
                    Text('Live location ON', style: TextStyle(color: Colors.green)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      );

  Widget _orderCard(Map<String, dynamic> o, {required bool offer}) {
    final store = _map(o['store']);
    final cust = _map(o['customer']);
    final items = _list(o['items']);
    final status = _s(o['status']);
    final cod = o['is_cod'] == true;
    final id = o['id'] as int;

    Widget action;
    if (offer) {
      action = FilledButton(
        onPressed: _busy ? null : () => _run(() => Api.accept(id)),
        child: Text('Accept  (Rs ${_num(o['fee'])})'),
      );
    } else if (status == 'assigned') {
      action = FilledButton(
        onPressed: _busy ? null : () => _run(() => Api.action(id, 'pickup')),
        child: const Text('📦 Maal le liya'),
      );
    } else {
      action = FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
        onPressed: _busy ? null : () => _confirmDeliver(o),
        child: const Text('🎉 Deliver kar diya'),
      );
    }

    final storeAddr = _s(store['address']);
    final custAddr = _s(cust['address']);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('#${_s(o['order_no'])}',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const Spacer(),
                Chip(
                  label: Text(cod ? 'COD Rs ${_num(o['total'])}' : 'Paid'),
                  backgroundColor: cod ? Colors.amber.shade100 : Colors.green.shade100,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (!offer)
              Text(status == 'assigned' ? 'Maal uthana hai' : 'Customer ko dena hai',
                  style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            _place(Icons.store, _s(store['name']), storeAddr, _s(store['phone']),
                _mapUrl(storeAddr, store['lat'], store['lng'])),
            const SizedBox(height: 6),
            _place(Icons.home, _s(cust['name']), custAddr, _s(cust['phone']),
                _mapUrl(custAddr, cust['lat'], cust['lng'])),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(items.map((i) => '${_num(i['qty'])} × ${_s(i['name'])}').join('\n'),
                  style: const TextStyle(fontSize: 12.5, color: Colors.black87)),
            ],
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: action),
          ],
        ),
      ),
    );
  }

  Widget _place(IconData icon, String title, String addr, String phone, String mapUrl) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.black54),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty) Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(addr.isEmpty ? '—' : addr, style: const TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.navigation, color: Colors.blue),
          tooltip: 'Map',
          onPressed: () => _open(mapUrl),
        ),
        if (phone.isNotEmpty)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.call, color: Colors.green),
            tooltip: 'Call',
            onPressed: () => _open('tel:$phone'),
          ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text(text, style: const TextStyle(color: Colors.black54)),
      );
}
