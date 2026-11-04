import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/providers.dart';
import '../client/account_screen.dart' show ChangePasswordDialog;
import 'admin_widgets.dart';

class AdminAccountScreen extends ConsumerWidget {
  const AdminAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider).valueOrNull;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: [
        SectionCard(
          title: 'Account',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user?.email ?? '-'),
              const SizedBox(height: AppSpace.l),
              Wrap(
                spacing: AppSpace.m,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('Change password'),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => const ChangePasswordDialog(),
                    ),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                    onPressed: () => signOut(ref),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
