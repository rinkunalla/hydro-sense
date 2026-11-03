import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../auth/set_password_screen.dart' show validateNewPassword;

/// Email, phone (read only), Change password, Sign out. No delete-account.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).valueOrNull;
    final user = ref.watch(userProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Email'),
                  subtitle: Text(profile?.email ?? user?.email ?? '-'),
                ),
                ListTile(
                  leading: const Icon(Icons.phone_outlined),
                  title: const Text('Phone'),
                  subtitle: Text(_displayPhone(profile?.phone)),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.l),
          OutlinedButton.icon(
            icon: const Icon(Icons.lock_outline),
            label: const Text('Change password'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const _ChangePassword(),
            ),
          ),
          const SizedBox(height: AppSpace.m),
          FilledButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => ref.read(authProvider).signOut(),
          ),
        ],
      ),
    );
  }
}

/// "639171234567" -> "0917 123 4567".
String _displayPhone(String? p) {
  if (p == null || p.length != 12 || !p.startsWith('63')) return p ?? '-';
  final local = '0${p.substring(2)}';
  return '${local.substring(0, 4)} ${local.substring(4, 7)} ${local.substring(7)}';
}

class _ChangePassword extends ConsumerStatefulWidget {
  const _ChangePassword();

  @override
  ConsumerState<_ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends ConsumerState<_ChangePassword> {
  final _current = TextEditingController();
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = validateNewPassword(_a.text, _b.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = ref.read(authProvider).currentUser!;
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(
          email: user.email!,
          password: _current.text,
        ),
      );
      await user.updatePassword(_a.text);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Password changed.')));
      }
    } catch (e) {
      if (mounted) setState(() => _error = authMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _current,
              obscureText: true,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            const SizedBox(height: AppSpace.m),
            TextField(
              controller: _a,
              obscureText: true,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            const SizedBox(height: AppSpace.m),
            TextField(
              controller: _b,
              obscureText: true,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Repeat new password',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.m),
              Text(_error!, style: const TextStyle(color: Color(0xFF8A2A20))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
