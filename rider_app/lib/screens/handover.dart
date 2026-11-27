import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/wallet.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/notice_card.dart';

/// Wallet se kholein. true wapas aaye to handover ban gaya (wallet dobara load karo).
Future<bool?> openHandover(BuildContext context, AppState st, WalletData wallet) {
  return Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
    builder: (_) => AppScope(state: st, child: HandoverScreen(wallet: wallet)),
  ));
}

/// Cash handover: receiver (Admin / Vendor), raqam (partial ho sakti hai), note.
/// Receiver apne portal se Confirm / Reject karta hai - tab tak status "pending" rehta hai.
class HandoverScreen extends StatefulWidget {
  final WalletData wallet;
  const HandoverScreen({super.key, required this.wallet});

  @override
  State<HandoverScreen> createState() => _HandoverScreenState();
}

class _HandoverScreenState extends State<HandoverScreen> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  String _receiver = 'admin';
  int? _vendorId;
  bool _busy = false;
  String? _error;

  WalletData get _w => widget.wallet;

  @override
  void initState() {
    super.initState();
    _amount.text = _plain(_w.availableToHandover);
    if (_w.vendors.isNotEmpty) _vendorId = _w.vendors.first.id;
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  String _plain(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  double? get _entered {
    final t = _amount.text.trim().replaceAll(',', '');
    final v = double.tryParse(t);
    return (v == null || v.isNaN || v.isInfinite) ? null : v;
  }

  String get _toWhom {
    if (_receiver == 'admin') return 'Admin';
    for (final v in _w.vendors) {
      if (v.id == _vendorId) return v.name.isEmpty ? 'Vendor' : v.name;
    }
    return 'Vendor';
  }

  Future<void> _submit() async {
    if (_busy) return; // double tap se bachao
    final st = AppScope.of(context);
    final amt = _entered;
    if (amt == null || amt <= 0) {
      setState(() => _error = 'Raqam sahi likhein (0 se zyada).');
      return;
    }
    if (amt > _w.availableToHandover + 0.001) {
      setState(() => _error =
          'Aap sirf ${rs(_w.availableToHandover)} handover kar sakte hain.');
      return;
    }
    if (_receiver == 'vendor' && _vendorId == null) {
      setState(() => _error = 'Vendor chunein.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cash handover bhejein?'),
        content: Text('${rs(amt)} cash $_toWhom ko diya hai?\n\n'
            'Jab tak wo Confirm na karein, ye "pending" rahega.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Nahi')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Haan, bhejein')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = await Api.submitHandover(
        receiver: _receiver,
        vendorId: _receiver == 'vendor' ? _vendorId : null,
        amount: amt,
        note: _note.text.trim(),
      );
      st.toast((d['message'] ?? 'Handover bhej diya').toString());
      st.refresh(withDashboard: true);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (e.authExpired) {
        await st.onLogout();
        return;
      }
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vendorBal = (_receiver == 'vendor' && _vendorId != null) ? _w.balanceOf(_vendorId!) : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Cash handover')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Aap ke paas cash',
                      style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(rs(_w.cashInHand),
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
                  if (_w.pendingHandover > 0) ...[
                    const SizedBox(height: 6),
                    Text('Pending handover: ${rs(_w.pendingHandover)}',
                        style: TextStyle(color: Colors.amber.shade900, fontWeight: FontWeight.w700)),
                  ],
                  const SizedBox(height: 6),
                  Text('Abhi de sakte hain: ${rs(_w.availableToHandover)}',
                      style: const TextStyle(fontWeight: FontWeight.w700, color: kGreen)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Cash kis ko diya?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: 'admin', label: Text('Admin'), icon: Icon(Icons.admin_panel_settings_outlined)),
                ButtonSegment(
                  value: 'vendor',
                  label: const Text('Vendor'),
                  icon: const Icon(Icons.storefront_outlined),
                  enabled: _w.vendors.isNotEmpty,
                ),
              ],
              selected: {_receiver},
              onSelectionChanged: (v) => setState(() {
                _receiver = v.first;
                _error = null;
              }),
            ),
          ),
          if (_w.vendors.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Vendor ko tab de sakte hain jab us ke COD orders aap ne deliver kiye hon.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          if (_receiver == 'vendor') ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final v in _w.vendors)
                  ChoiceChip(
                    label: Text(v.name.isEmpty ? 'Vendor #${v.id}' : v.name),
                    selected: v.id == _vendorId,
                    onSelected: (_) => setState(() {
                      _vendorId = v.id;
                      _error = null;
                    }),
                  ),
              ],
            ),
            if (vendorBal != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Is vendor ka baqi cash: ${rs(vendorBal)}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ),
          ],
          const SizedBox(height: 18),
          TextField(
            controller: _amount,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              labelText: 'Raqam (Rs)',
              helperText: 'Thora cash bhi de sakte hain (partial); baqi aap ke paas rahega.',
              helperMaxLines: 2,
              suffixIcon: TextButton(
                onPressed: _busy ? null : () => setState(() => _amount.text = _plain(_w.availableToHandover)),
                child: const Text('Poora'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            enabled: !_busy,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            NoticeCard(level: NoticeLevel.error, text: _error!),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || !_w.canHandover) ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded),
              label: Text(_busy ? 'Bhej raha hai...' : 'Handover bhejein'),
            ),
          ),
        ],
      ),
    );
  }
}
