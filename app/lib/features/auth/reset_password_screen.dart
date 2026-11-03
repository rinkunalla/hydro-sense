import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';

/// Always shows the same confirmation, so it never reveals whether an account exists.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    String message = Messages.resetSent;
    try {
      await ref
          .read(authProvider)
          .sendPasswordResetEmail(email: _email.text.trim());
    } on FirebaseAuthException catch (e) {
      if (e.code == 'network-request-failed') message = Messages.noInternet;
      if (e.code == 'too-many-requests') message = Messages.tooManyAttempts;
    } catch (_) {
      // Same confirmation for every other outcome (no account enumeration).
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _message = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Enter your email. If it has an account, we will send a reset link.',
              ),
              const SizedBox(height: AppSpace.l),
              TextField(
                controller: _email,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: AppSpace.l),
              FilledButton(
                onPressed: _busy ? null : _send,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Send reset link'),
              ),
              if (_message != null) ...[
                const SizedBox(height: AppSpace.l),
                Text(_message!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
