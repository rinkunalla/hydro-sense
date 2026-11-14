import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../data/admin_providers.dart';
import 'admin_widgets.dart';

// Stage 2 stop-gap on the Account page; stage 6 replaces it with the Users page.

const phoneHint = 'Enter a Philippine mobile number, for example 09171234567.';

/// Create user (D20, D22): name, mobile, email. The user sets their own
/// password from the app by SMS code; there is no temporary password.
class CreateUserCard extends ConsumerStatefulWidget {
  const CreateUserCard({super.key});

  @override
  ConsumerState<CreateUserCard> createState() => _CreateUserCardState();
}

class _CreateUserCardState extends ConsumerState<CreateUserCard> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _created;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  String? _validate() {
    if (_name.text.trim().isEmpty) return "Enter the user's name.";
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
      return 'Enter a valid email address.';
    }
    if (!AppConfig.phMobilePattern.hasMatch(
      _phone.text.replaceAll(RegExp(r'[\s-]'), ''),
    )) {
      return phoneHint;
    }
    return null;
  }

  Future<void> _create() async {
    final problem = _validate();
    setState(() => _error = problem);
    if (problem != null) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .createUser(
            name: _name.text.trim(),
            email: _email.text.trim(),
            mobile: _phone.text,
          );
      if (mounted) setState(() => _created = _name.text.trim());
    } catch (e) {
      setState(
        () => _error = switch (callableDetails(e).code) {
          'EMAIL_IN_USE' => 'Another account already uses this email.',
          'PHONE_IN_USE' => 'Another account already uses this mobile number.',
          'PHONE_INVALID' => phoneHint,
          'EMAIL_INVALID' => 'Enter a valid email address.',
          'NAME_INVALID' => "Enter the user's name.",
          _ => callableMessage(e),
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reset() {
    _name.clear();
    _email.clear();
    _phone.clear();
    setState(() => _created = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_created != null) {
      return SectionCard(
        title: 'User created',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$_created can now set a password in the app with '
              '"Forgot password or first time?", using their mobile number.',
            ),
            const SizedBox(height: AppSpace.m),
            TextButton(onPressed: _reset, child: const Text('Done')),
          ],
        ),
      );
    }
    return SectionCard(
      title: 'Create user',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: AppSpace.m),
            TextField(
              controller: _phone,
              enabled: !_busy,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                hintText: '09171234567',
              ),
            ),
            const SizedBox(height: AppSpace.m),
            TextField(
              controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpace.s),
              Text(_error!, style: const TextStyle(color: Color(0xFF8A2A20))),
            ],
            const SizedBox(height: AppSpace.m),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _busy ? null : _create,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create user'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
