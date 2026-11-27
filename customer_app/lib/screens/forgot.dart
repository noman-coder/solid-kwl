import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/busy_button.dart';
import '../widgets/notice_card.dart';

/// Password bhool gaye: Step 1 phone -> code (WhatsApp / email), Step 2 code + naya password.
/// Kamyab hone par server ka message le kar `Navigator.pop(message)` (login screen dikhati hai).
class ForgotScreen extends StatefulWidget {
  final String phone; // login screen se (likha hua ho to)
  const ForgotScreen({super.key, this.phone = ''});
  @override
  State<ForgotScreen> createState() => _ForgotScreenState();
}

class _ForgotScreenState extends State<ForgotScreen> {
  final _form1 = GlobalKey<FormState>();
  final _form2 = GlobalKey<FormState>();
  late final TextEditingController _phone = TextEditingController(text: widget.phone);
  final _code = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  Timer? _timer;
  bool _step2 = false;
  bool _busy = false;
  bool _hide = true;
  int _cooldown = 0;
  String? _info;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    setState(() => _cooldown = seconds);
    if (seconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_cooldown <= 1) {
        t.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown--);
      }
    });
  }

  Future<void> _sendCode() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (!(_form1.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await Api.forgotPassword(_phone.text.trim());
      if (!mounted) return;
      setState(() {
        _step2 = true;
        _info = msg;
        _busy = false;
      });
      _startCooldown(60);
      return;
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _resend() async {
    if (_busy || _cooldown > 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await Api.forgotPassword(_phone.text.trim());
      if (!mounted) return;
      setState(() => _info = msg);
      _startCooldown(60);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reset() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (!(_form2.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final msg = await Api.resetPassword(
        phone: _phone.text.trim(),
        code: _code.text.trim(),
        password: _pass.text,
        confirmPassword: _confirm.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(msg.isEmpty ? 'Password badal gaya. Ab login karein.' : msg);
      return;
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      appBarTitle: 'Password bhool gaye',
      showLogo: false,
      title: _step2 ? 'Naya password' : 'Password wapis layein',
      subtitle: _step2 ? 'Code aur naya password likhein' : 'Apna phone number likhein, hum code bhejenge',
      children: [
        if (!_step2) ...[
          Form(
            key: _form1,
            child: TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                  labelText: 'Phone (03xx...)', prefixIcon: Icon(Icons.phone_outlined)),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return 'Phone number likhein';
                if (!isValidPhone(t)) return 'Sahi phone number likhein (03XXXXXXXXX)';
                return null;
              },
              onFieldSubmitted: (_) => _sendCode(),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            NoticeCard(text: _error!, level: NoticeLevel.error),
            const SizedBox(height: 12),
          ],
          BusyButton(label: 'Code bhejein', busy: _busy, onPressed: _sendCode),
        ] else ...[
          if (_info != null) ...[
            NoticeCard(text: _info!, level: NoticeLevel.info),
            const SizedBox(height: 16),
          ],
          Form(
            key: _form2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                      labelText: '6-digit code', counterText: '', prefixIcon: Icon(Icons.pin_outlined)),
                  validator: (v) => (v ?? '').trim().length != 6 ? '6-digit code likhein' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _pass,
                  obscureText: _hide,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Naya password',
                    helperText: 'Kam az kam $kMinPassword characters, harf aur number',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _hide ? 'Password dikhayein' : 'Password chhupayein',
                      icon: Icon(_hide ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                  ),
                  validator: (v) => passwordProblem(v ?? '', [_phone.text]),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  obscureText: _hide,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                      labelText: 'Password dobara likhein', prefixIcon: Icon(Icons.lock_outline)),
                  validator: (v) => v != _pass.text ? 'Dono password aik jaise likhein' : null,
                  onFieldSubmitted: (_) => _reset(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            NoticeCard(text: _error!, level: NoticeLevel.error),
            const SizedBox(height: 12),
          ],
          BusyButton(label: 'Password badlein', busy: _busy, onPressed: _reset),
          const SizedBox(height: 8),
          TextButton(
            onPressed: (_busy || _cooldown > 0) ? null : _resend,
            child: Text(_cooldown > 0 ? 'Code dobara bhejein ($_cooldown sec)' : 'Code dobara bhejein'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _step2 = false;
                      _error = null;
                      _info = null;
                    }),
            style: TextButton.styleFrom(foregroundColor: kMuted),
            child: const Text('Phone number badlein'),
          ),
        ],
      ],
    );
  }
}
