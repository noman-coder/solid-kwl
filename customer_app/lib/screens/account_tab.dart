import 'package:flutter/material.dart';

import '../models/customer.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/content_width.dart';
import '../widgets/skeleton.dart';
import 'login.dart';
import 'otp.dart';
import 'register.dart';

/// Account tab: guest ko Login / Register, login ho to profile card + menu + logout.
/// (Profile edit, addresses, wishlist, coupons, settings aglay phases mein: abhi "jald" likha aata hai.)
class AccountTab extends StatelessWidget {
  const AccountTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return RefreshIndicator(
      color: kOrange,
      onRefresh: state.refreshMe,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          ContentWidth(
            child: state.loggedIn
                ? _LoggedIn(customer: state.customer!)
                : state.sessionLoading
                    ? const SkeletonList(count: 3, height: 70)
                    : const _Guest(),
          ),
        ],
      ),
    );
  }
}

void _soon(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('Yeh hissa jald aa raha hai.')));
}

// ---------------------------------------------------------------- guest

class _Guest extends StatelessWidget {
  const _Guest();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [Color(0xFFF46A14), kOrangeDark],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: kSoftShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.account_circle_rounded, color: Colors.white, size: 46),
              const SizedBox(height: 10),
              const Text('Apna account banayein',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              const Text('Order karne, track karne aur apne pate / pasandida save karne ke liye login karein.',
                  style: TextStyle(color: Colors.white70, height: 1.35)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: kOrangeDark),
                      onPressed: () => Navigator.of(context)
                          .push<bool>(MaterialPageRoute<bool>(builder: (_) => const LoginScreen())),
                      child: const Text('Login'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white70),
                          minimumSize: const Size(64, 52)),
                      onPressed: () => Navigator.of(context)
                          .push<bool>(MaterialPageRoute<bool>(builder: (_) => const RegisterScreen())),
                      child: const Text('Register'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const _Menu(children: [_PolicyTile()]),
        const SizedBox(height: 16),
        const _VersionText(),
      ],
    );
  }
}

// ---------------------------------------------------------------- logged in

class _LoggedIn extends StatelessWidget {
  final Customer customer;
  const _LoggedIn({required this.customer});

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout karein?'),
        content: const Text('Aap ko dobara login karna hoga.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Nahi')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await AppScope.read(context).logout();
    }
  }

  Future<void> _verifyPhone(BuildContext context) async {
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute<bool>(builder: (_) => const OtpScreen()));
    if (ok == true && context.mounted) await AppScope.read(context).refreshMe();
  }

  @override
  Widget build(BuildContext context) {
    final since = dateText(customer.memberSince);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: kBorder),
            boxShadow: kSoftShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: kOrange,
                    child: Text(customer.initial,
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(customer.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: kInk)),
                        if (customer.phone.isNotEmpty)
                          Text(customer.phone,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted)),
                        if (customer.email.isNotEmpty)
                          Text(customer.email,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _Chip(
                    text: customer.phoneVerified ? 'Phone verify' : 'Phone verify nahi',
                    good: customer.phoneVerified,
                  ),
                  if (customer.emailVerified) const _Chip(text: 'Email verify', good: true),
                  if (since.isNotEmpty) _Chip(text: 'Member: $since', good: null),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Menu(children: [
          if (!customer.phoneVerified)
            ListTile(
              leading: const Icon(Icons.verified_user_outlined, color: kOrange),
              title: const Text('Phone verify karein'),
              subtitle: const Text('Email par OTP aayega'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _verifyPhone(context),
            ),
          ListTile(
            leading: const Icon(Icons.location_on_outlined, color: kOrange),
            title: const Text('Mere pate'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _soon(context),
          ),
          ListTile(
            leading: const Icon(Icons.favorite_border, color: kOrange),
            title: const Text('Pasandida'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _soon(context),
          ),
          ListTile(
            leading: const Icon(Icons.local_offer_outlined, color: kOrange),
            title: const Text('Mere coupons'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _soon(context),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined, color: kOrange),
            title: const Text('Settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _soon(context),
          ),
          const _PolicyTile(),
        ]),
        const SizedBox(height: 12),
        _Menu(children: [
          ListTile(
            leading: Icon(Icons.logout_rounded, color: Colors.red.shade700),
            title: Text('Logout', style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w700)),
            onTap: () => _logout(context),
          ),
        ]),
        const SizedBox(height: 16),
        const _VersionText(),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final bool? good; // true hara, false narangi, null saada
  const _Chip({required this.text, required this.good});

  @override
  Widget build(BuildContext context) {
    final Color bg = good == null ? const Color(0xFFF3F4F6) : (good! ? kGreenSoft : kOrangeSoft);
    final Color fg = good == null ? kMuted : (good! ? kGreen : kOrangeDark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class _Menu extends StatelessWidget {
  final List<Widget> children;
  const _Menu({required this.children});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const Divider(height: 1, color: kBorder));
      rows.add(children[i]);
    }
    return Card(clipBehavior: Clip.antiAlias, child: Column(children: rows));
  }
}

class _PolicyTile extends StatelessWidget {
  const _PolicyTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.privacy_tip_outlined, color: kOrange),
      title: const Text('Privacy Policy'),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () async {
        final ok = await openUrl(Api.absUrl('/privacy-policy/'));
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('Link nahi khul saka.')));
        }
      },
    );
  }
}

class _VersionText extends StatelessWidget {
  const _VersionText();

  @override
  Widget build(BuildContext context) {
    return Text('$kAppName  -  Version $kAppVersion',
        textAlign: TextAlign.center, style: const TextStyle(color: kMuted, fontSize: 12));
  }
}
