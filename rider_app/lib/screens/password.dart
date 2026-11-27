import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/app_state.dart';
import '../widgets/notice_card.dart';

/// Password badlein. Server naya token deta hai - Api.changePassword use khud save kar leta hai.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final st = AppScope.of(context);
    if (_old.text.isEmpty || _new.text.isEmpty) {
      setState(() => _error = 'Purana aur naya password dono likhein.');
      return;
    }
    if (_new.text.length < 6) {
      setState(() => _error = 'Naya password kam az kam 6 harf ka ho.');
      return;
    }
    if (_new.text != _again.text) {
      setState(() => _error = 'Naya password dono jagah ek jaisa likhein.');
      return;
    }
    if (_new.text == _old.text) {
      setState(() => _error = 'Naya password purane se alag ho.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await Api.changePassword(_old.text, _new.text);
      st.toast('✅ $msg');
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

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _show = !_show),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Password badlein')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _old, obscureText: !_show, enabled: !_busy, decoration: _dec('Purana password')),
          const SizedBox(height: 12),
          TextField(controller: _new, obscureText: !_show, enabled: !_busy, decoration: _dec('Naya password (kam az kam 6)')),
          const SizedBox(height: 12),
          TextField(controller: _again, obscureText: !_show, enabled: !_busy, decoration: _dec('Naya password dobara')),
          if (_error != null) ...[
            const SizedBox(height: 12),
            NoticeCard(level: NoticeLevel.error, text: _error!),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Save ho raha hai...' : 'Password badlein'),
          ),
        ],
      ),
    );
  }
}
