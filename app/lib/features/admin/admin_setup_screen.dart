import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/password_field.dart';
import '../../core/theme.dart';
import '../../data/admin_providers.dart';
import '../../data/providers.dart';
import '../auth/password_rules.dart';
import 'admin_widgets.dart';

/// The centred glass card the pre-sign-in pages share (no tab bar, 5.3).
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});

  final String title;
  final List<Widget> children;

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
                      child: Text(title, style: AppText.title(24)),
                    ),
                    const SizedBox(height: AppSpace.m),
                    ...children,
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

/// "Set up an admin account": an invited admin asks for a one-time link.
/// The reply is the same for every email.
class AdminSetupRequestScreen extends ConsumerStatefulWidget {
  const AdminSetupRequestScreen({super.key});

  @override
  ConsumerState<AdminSetupRequestScreen> createState() => _RequestState();
}

class _RequestState extends ConsumerState<AdminSetupRequestScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adminRepositoryProvider).requestAdminSetup(email);
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) setState(() => _error = callableMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Card(
    title: 'Set up an admin account',
    children: [
      if (_sent) ...[
        Text(
          'Check your inbox. If that email was invited, the link is on its way. '
          'It works once and expires in 1 hour.',
          style: AppText.body,
        ),
      ] else ...[
        Text(
          'Enter your email. If you were invited, we send a link to set your '
          'password.',
          style: AppText.body.copyWith(color: AppColors.steel),
        ),
        const SizedBox(height: AppSpace.l),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
          onSubmitted: (_) => _send(),
        ),
        ErrorLine(_error),
        const SizedBox(height: AppSpace.l),
        PrimaryButton(label: 'Send the link', busy: _busy, onPressed: _send),
      ],
      const SizedBox(height: AppSpace.s),
      TextButton(
        onPressed: () => context.go('/login'),
        child: const Text('Back to sign in'),
      ),
    ],
  );
}

/// The page the emailed link opens: choose a password, then sign in.
class AdminSetPasswordScreen extends ConsumerStatefulWidget {
  const AdminSetPasswordScreen({super.key, required this.token});

  final String token;

  @override
  ConsumerState<AdminSetPasswordScreen> createState() => _SetPasswordState();
}

class _SetPasswordState extends ConsumerState<AdminSetPasswordScreen> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _busy = false;
  bool _expired = false;
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
      final email = await ref
          .read(adminRepositoryProvider)
          .completeAdminSetup(widget.token, _a.text);
      await ref
          .read(authProvider)
          .signInWithEmailAndPassword(email: email, password: _a.text);
      // The router moves on to the admin pages once the session arrives.
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = authMessage(e));
    } catch (e) {
      if (!mounted) return;
      if (callableDetails(e).code == 'RESET_TOKEN_INVALID') {
        setState(() => _expired = true);
      } else {
        setState(() => _error = callableMessage(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Card(
    title: 'Choose your password',
    children: [
      if (_expired) ...[
        Text(
          'This link has expired or was already used. Ask for a new one.',
          style: AppText.body,
        ),
        const SizedBox(height: AppSpace.l),
        PrimaryButton(
          label: 'Get a new link',
          onPressed: () => context.go('/setup'),
        ),
      ] else ...[
        Text(
          'Welcome to Hydro Sense admin. Choose the password you will sign in '
          'with.',
          style: AppText.body.copyWith(color: AppColors.steel),
        ),
        const SizedBox(height: AppSpace.l),
        PasswordField(
          controller: _a,
          label: 'New password',
          enabled: !_busy,
          autofillHints: const [AutofillHints.newPassword],
          showTips: true,
        ),
        const SizedBox(height: AppSpace.m),
        PasswordField(
          controller: _b,
          label: 'Type it again',
          enabled: !_busy,
          onSubmitted: (_) => _save(),
        ),
        ErrorLine(_error),
        const SizedBox(height: AppSpace.l),
        PrimaryButton(label: 'Save and sign in', busy: _busy, onPressed: _save),
      ],
    ],
  );
}
