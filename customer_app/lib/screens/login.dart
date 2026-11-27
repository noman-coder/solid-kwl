import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/busy_button.dart';
import '../widgets/notice_card.dart';
import 'forgot.dart';
import 'register.dart';

/// Login zaroori ho (checkout, orders...) to yeh chalayein: login screen kholta hai, kamyab hone par true.
/// Pehle se login ho to seedha true.
Future<bool> ensureLoggedIn(BuildContext context) async {
  if (AppScope.read(context).loggedIn) return true;
  final ok = await Navigator.of(context)
      .push<bool>(MaterialPageRoute<bool>(builder: (_) => const LoginScreen()));
  return ok == true;
}

/// Phone + password se login. Kamyab hone par `Navigator.pop(true)`.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;
  String? _info; // password reset kamyab hone ka message

  @override
  void dispose() {
    _phone.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return; // double tap se do dafa login nahi
    FocusScope.of(context).unfocus();
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final r = await Api.login(_phone.text.trim(), _pass.text);
      if (!mounted) return;
      AppScope.read(context)
          .onAuthenticated(r.customer, message: 'Khush aamdeed ${r.customer.firstName}!');
      Navigator.of(context).pop(true);
      return; // screen band ho chuki hai
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _forgot() async {
    final msg = await Navigator.of(context)
        .push<String>(MaterialPageRoute<String>(builder: (_) => ForgotScreen(phone: _phone.text.trim())));
    if (msg != null && msg.isNotEmpty && mounted) {
      setState(() {
        _info = msg;
        _error = null;
        _pass.clear();
      });
    }
  }

  Future<void> _register() async {
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute<bool>(builder: (_) => const RegisterScreen()));
    if (ok == true && mounted) Navigator.of(context).pop(true); // register ke saath login ho gaya
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      appBarTitle: 'Login',
      title: kAppName,
      subtitle: 'Apne account mein login karein',
      children: [
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: const InputDecoration(
                      labelText: 'Phone (03xx...)', prefixIcon: Icon(Icons.phone_outlined)),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Phone number likhein';
                    if (!isValidPhone(t)) return 'Sahi phone number likhein (03XXXXXXXXX)';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _pass,
                  obscureText: _hide,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _hide ? 'Password dikhayein' : 'Password chhupayein',
                      icon: Icon(_hide ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                  ),
                  validator: (v) => (v ?? '').isEmpty ? 'Password likhein' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: _busy ? null : _forgot, child: const Text('Password bhool gaye?')),
        ),
        if (_info != null) ...[
          NoticeCard(text: _info!, level: NoticeLevel.success),
          const SizedBox(height: 12),
        ],
        if (_error != null) ...[
          NoticeCard(text: _error!, level: NoticeLevel.error),
          const SizedBox(height: 12),
        ],
        BusyButton(label: 'Login', busy: _busy, onPressed: _submit),
        const SizedBox(height: 22),
        Row(
          children: const [
            Expanded(child: Divider(color: kBorder)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('ya', style: TextStyle(color: kMuted)),
            ),
            Expanded(child: Divider(color: kBorder)),
          ],
        ),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: _busy ? null : _register, child: const Text('Naya account banayein')),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Abhi nahi, pehle dekhna hai'),
        ),
      ],
    );
  }
}
