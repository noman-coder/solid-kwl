import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/busy_button.dart';
import '../widgets/notice_card.dart';

/// Phone / order verify: server email par 6-digit OTP bhejta hai (5 minute valid), yahan likhein.
/// Register ke baad (`skippable: true`, "Baad mein" ka button) aur checkout (Phase C8) mein yahi screen chalegi.
/// Kamyab (ya OTP ki zaroorat hi na ho) to `Navigator.pop(true)`.
class OtpScreen extends StatefulWidget {
  final bool skippable;
  const OtpScreen({super.key, this.skippable = false});
  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _code = TextEditingController();
  Timer? _timer;
  bool _sending = true; // screen khulte hi OTP bheja jata hai
  bool _verifying = false;
  bool _skipOtp = false; // bharosay-mand customer: OTP ki zaroorat nahi
  bool _done = false;
  int _cooldown = 0;
  String? _info;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _send(); // screen khulte hi OTP bhejo
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
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

  Future<void> _send() async {
    if (_cooldown > 0) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final r = await Api.otpSend();
      if (!mounted) return;
      if (r.skip) {
        setState(() {
          _skipOtp = true;
          _info = r.message;
          _sending = false;
        });
        return;
      }
      setState(() {
        _info = r.message;
        _sending = false;
      });
      _startCooldown(r.resendAfter);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _sending = false;
      });
      if (e.code == 'wait') _startCooldown(toI(e.data['resend_after'], 60));
    }
  }

  Future<void> _verify() async {
    if (_verifying) return;
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = '6-digit OTP likhein');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final c = await Api.otpVerify(code);
      if (!mounted) return;
      AppScope.read(context).setCustomer(c);
      setState(() {
        _done = true;
        _verifying = false;
        _info = 'Verify ho gaya. Shukriya!';
      });
      return;
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _verifying = false);
  }

  @override
  Widget build(BuildContext context) {
    final finished = _done || _skipOtp;
    return AuthScaffold(
      appBarTitle: 'Verify karein',
      showLogo: false,
      title: finished ? 'Sab theek hai' : 'OTP likhein',
      subtitle: finished ? null : '6-digit code email par bheja gaya hai (5 minute valid)',
      children: [
        if (_sending && !finished) ...[
          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())),
          const SizedBox(height: 8),
          const Text('OTP bheja ja raha hai...', textAlign: TextAlign.center, style: TextStyle(color: kMuted)),
        ] else if (finished) ...[
          Center(
            child: CircleAvatar(
              radius: 38,
              backgroundColor: kGreenSoft,
              child: const Icon(Icons.check_rounded, size: 44, color: kGreen),
            ),
          ),
          const SizedBox(height: 16),
          if (_info != null) NoticeCard(text: _info!, level: NoticeLevel.success),
          const SizedBox(height: 18),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Aage barhein')),
        ] else ...[
          if (_info != null) ...[
            NoticeCard(text: _info!, level: NoticeLevel.info),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            autofocus: true,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 10),
            decoration: const InputDecoration(counterText: '', hintText: '------'),
            onChanged: (v) {
              if (_error != null) setState(() => _error = null);
              if (v.length == 6) _verify();
            },
            onSubmitted: (_) => _verify(),
          ),
          const SizedBox(height: 12),
          if (_error != null) ...[
            NoticeCard(text: _error!, level: NoticeLevel.error),
            const SizedBox(height: 12),
          ],
          BusyButton(label: 'Verify karein', busy: _verifying, onPressed: _verify),
          const SizedBox(height: 8),
          TextButton(
            onPressed: (_cooldown > 0 || _verifying) ? null : _send,
            child: Text(_cooldown > 0 ? 'Dobara bhejein ($_cooldown sec)' : 'Code dobara bhejein'),
          ),
          if (widget.skippable)
            TextButton(
              onPressed: _verifying ? null : () => Navigator.of(context).pop(false),
              child: const Text('Baad mein'),
            ),
        ],
      ],
    );
  }
}
