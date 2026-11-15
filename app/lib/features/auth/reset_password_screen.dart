import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/glass.dart';
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
  Widget build(BuildContext context) => AppBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.l),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: GlassPanel(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text('Reset password', style: AppText.title(24)),
                    ),
                    const SizedBox(height: AppSpace.m),
                    Text(
                      'Enter your email. If it has an admin account, we send a '
                      'link to choose a new password.',
                      style: AppText.body.copyWith(color: AppColors.steel),
                    ),
                    const SizedBox(height: AppSpace.l),
                    TextField(
                      controller: _email,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                      onSubmitted: (_) => _busy ? null : _send(),
                    ),
                    const SizedBox(height: AppSpace.l),
                    PrimaryButton(
                      label: 'Send reset link',
                      busy: _busy,
                      onPressed: _send,
                    ),
                    if (_message != null) ...[
                      const SizedBox(height: AppSpace.l),
                      Text(_message!, style: AppText.body),
                    ],
                    const SizedBox(height: AppSpace.s),
                    TextButton(
                      onPressed: () => context.go('/login'),
                      child: const Text('Back to sign in'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
