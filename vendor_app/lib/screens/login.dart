import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';
import '../utils.dart' show kAppName;
import '../widgets/notice_card.dart';

class LoginScreen extends StatefulWidget {
  final void Function(LoginResult) onDone;
  const LoginScreen({super.key, required this.onDone});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return; // double tap se do dafa login nahi
    if (_phone.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Phone aur password dono likhein');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await Api.login(_phone.text.trim(), _pass.text);
      widget.onDone(r);
      return; // screen badal chuki hai
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset('assets/icon/app_icon.png', width: 110, height: 110),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(kAppName,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: kTeal)),
                const SizedBox(height: 4),
                const Text('Vendor Login',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.black54, fontWeight: FontWeight.w600)),
                const SizedBox(height: 26),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                      labelText: 'Phone (03xx...)', prefixIcon: Icon(Icons.phone_outlined)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: _hide,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_hide ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  NoticeCard(text: _error!, level: NoticeLevel.error),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Login'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
