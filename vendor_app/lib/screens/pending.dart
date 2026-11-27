import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../widgets/empty_state.dart';

/// Account ki approval baqi ho to sirf yeh screen: dobara check + logout.
class PendingScreen extends StatelessWidget {
  final AppState state;
  final VoidCallback onLogout;
  const PendingScreen({super.key, required this.state, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Approval baqi')),
      body: RefreshIndicator(
        onRefresh: state.refresh,
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight),
              child: EmptyState(
                icon: Icons.hourglass_top_rounded,
                title: state.vendor?.name.isNotEmpty == true ? state.vendor!.name : 'Aap ka account',
                message: state.pendingMessage ??
                    'Aap ke account ki approval baqi hai. Admin approve kar de to dobara check karein.',
                action: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: state.refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Dobara check karein'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: onLogout, child: const Text('Logout')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
