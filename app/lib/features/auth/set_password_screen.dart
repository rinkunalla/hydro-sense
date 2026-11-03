import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';

/// Shown after signing in with a temporary password; nothing else is reachable
/// until it is saved (docs/UI_UX_SPEC.md section 4.1).
class SetPasswordScreen extends ConsumerStatefulWidget {
  const SetPasswordScreen({super.key});

  @override
  ConsumerState<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

String? validateNewPassword(String a, String b) {
  if (a.length < AppConfig.minPasswordLength) {
    return 'Use at least ${AppConfig.minPasswordLength} characters.';
  }
  if (a != b) return Messages.passwordsDontMatch;
  return null;
}

class _SetPasswordScreenState extends ConsumerState<SetPasswordScreen> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
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
      await ref.read(authProvider).currentUser!.updatePassword(_a.text);
      await ref.read(repositoryProvider).confirmPasswordChanged();
      // The profile stream updates mustChangePassword; the router then opens Devices.
    } catch (e) {
      if (mounted) setState(() => _error = authMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set a new password'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => ref.read(authProvider).signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'You signed in with a temporary password. Choose your own to continue.',
              ),
              const SizedBox(height: AppSpace.l),
              TextField(
                controller: _a,
                enabled: !_busy,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New password'),
              ),
              const SizedBox(height: AppSpace.m),
              TextField(
                controller: _b,
                enabled: !_busy,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Repeat new password',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpace.m),
                Text(_error!, style: const TextStyle(color: Color(0xFF8A2A20))),
              ],
              const SizedBox(height: AppSpace.l),
              FilledButton(
                onPressed: _busy ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Save password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
