import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/busy_button.dart';
import '../widgets/notice_card.dart';
import 'otp.dart';

/// Naya account (server `api/customer/register/` ke qaide). Kamyab hone par login ho jata hai,
/// phir (chahein to) phone verify ka screen, aur `Navigator.pop(true)`.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _city = TextEditingController();
  final _address = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _hide = true;
  bool _accept = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _city.dispose();
    _address.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return; // double tap se do account nahi
    FocusScope.of(context).unfocus();
    if (!(_form.currentState?.validate() ?? false)) return;
    if (!_accept) {
      setState(() => _error = 'Account banane ke liye Privacy Policy qabool karein.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await Api.register(
        fullName: _name.text.trim(),
        phone: _phone.text.trim(),
        email: _email.text.trim(),
        city: _city.text.trim(),
        address: _address.text.trim(),
        password: _pass.text,
        confirmPassword: _confirm.text,
      );
      if (!mounted) return;
      AppScope.read(context).onAuthenticated(r.customer, message: r.message);
      // Phone verify (OTP): "Baad mein" se chhod sakte hain, order se pehle zaroori ho to checkout phir poochega
      await Navigator.of(context)
          .push<bool>(MaterialPageRoute<bool>(builder: (_) => const OtpScreen(skippable: true)));
      if (mounted) Navigator.of(context).pop(true);
      return;
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      appBarTitle: 'Naya account',
      showLogo: false,
      title: 'Account banayein',
      subtitle: 'Thori si maloomat, phir order shuru',
      children: [
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(
                      labelText: 'Poora naam', prefixIcon: Icon(Icons.person_outline)),
                  validator: (v) => (v ?? '').trim().length < 3 ? 'Poora naam likhein' : null,
                ),
                const SizedBox(height: 12),
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
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                      labelText: 'Email (OTP isi par aayega)', prefixIcon: Icon(Icons.mail_outline)),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Email zaroori hai (OTP ke liye)';
                    if (!isValidEmail(t)) return 'Sahi email likhein';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _city,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.addressCity],
                  decoration: const InputDecoration(
                      labelText: 'Shehar', prefixIcon: Icon(Icons.location_city_outlined)),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Shehar likhein' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _address,
                  minLines: 2,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.fullStreetAddress],
                  decoration: const InputDecoration(
                      labelText: 'Poora address (ghar / gali / mohalla)',
                      prefixIcon: Icon(Icons.home_outlined)),
                  validator: (v) => (v ?? '').trim().length < 10 ? 'Poora address likhein' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _pass,
                  obscureText: _hide,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    helperText: 'Kam az kam $kMinPassword characters, harf aur number',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _hide ? 'Password dikhayein' : 'Password chhupayein',
                      icon: Icon(_hide ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                  ),
                  validator: (v) => passwordProblem(v ?? '', [_name.text, _phone.text, _email.text]),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  obscureText: _hide,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(
                      labelText: 'Password dobara likhein', prefixIcon: Icon(Icons.lock_outline)),
                  validator: (v) => v != _pass.text ? 'Dono password aik jaise likhein' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _accept,
          onChanged: _busy ? null : (v) => setState(() => _accept = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeColor: kOrange,
          title: const Text('Main Privacy Policy se ittefaq karta hoon', style: TextStyle(fontSize: 14)),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => openUrl(Api.absUrl('/privacy-policy/')),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Privacy Policy padhein'),
          ),
        ),
        if (_error != null) ...[
          NoticeCard(text: _error!, level: NoticeLevel.error),
          const SizedBox(height: 12),
        ],
        BusyButton(label: 'Account banayein', busy: _busy, onPressed: _submit),
      ],
    );
  }
}
