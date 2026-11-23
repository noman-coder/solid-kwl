import 'package:flutter/material.dart';

import 'api.dart';
import 'home.dart';
import 'tracker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RiderApp());
}

class RiderApp extends StatefulWidget {
  const RiderApp({super.key});
  @override
  State<RiderApp> createState() => _RiderAppState();
}

class _RiderAppState extends State<RiderApp> {
  bool _ready = false;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    Api.load().then((_) {
      if (mounted) {
        setState(() {
          _ready = true;
          _loggedIn = Api.token != null;
        });
      }
    });
  }

  Future<void> _logout() async {
    await Tracker.stop();
    await Api.logout();
    if (mounted) setState(() => _loggedIn = false);
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_ready) {
      body = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (_loggedIn) {
      body = HomeScreen(onLogout: _logout);
    } else {
      body = LoginScreen(onDone: () => setState(() => _loggedIn = true));
    }
    return MaterialApp(
      title: 'K-Conn Rider',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF16A34A)),
      ),
      home: body,
    );
  }
}

class LoginScreen extends StatefulWidget {
  final VoidCallback onDone;
  const LoginScreen({super.key, required this.onDone});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController(text: Api.server);
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _showServer = false;
  String? _error;

  Future<void> _submit() async {
    if (_phone.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Phone aur password dono likhein');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.login(_server.text, _phone.text, _pass.text);
      widget.onDone();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.two_wheeler, size: 72, color: Color(0xFF16A34A)),
                const SizedBox(height: 8),
                const Text('Rider Login',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 24),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                      labelText: 'Phone (03xx...)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Password', border: OutlineInputBorder()),
                  onSubmitted: (_) => _submit(),
                ),
                if (_showServer) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                        labelText: 'Server address', border: OutlineInputBorder()),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _busy
                        ? const SizedBox(
                            height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Login', style: TextStyle(fontSize: 16)),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _showServer = !_showServer),
                  child: const Text('Server address badlein'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
