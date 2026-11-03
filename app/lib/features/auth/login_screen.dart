import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';

/// Email + password; no sign-up (docs/UI_UX_SPEC.md section 4.1).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.refused});

  /// "admin" or "other" when a signed-in account was refused on this app.
  final String? refused;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.refused != null) {
      _error = switch (widget.refused) {
        'admin' => Messages.adminOnPhone,
        'notadmin' => Messages.notAdmin,
        _ => Messages.noAccess,
      };
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(authProvider).signOut(),
      );
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authProvider)
          .signInWithEmailAndPassword(
            email: _email.text.trim(),
            password: _password.text,
          );
    } catch (e) {
      if (mounted) setState(() => _error = authMessage(e));
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
            padding: const EdgeInsets.all(AppSpace.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.water_drop,
                      size: 48,
                      color: AppColors.primary,
                    ),
                    const SizedBox(height: AppSpace.s),
                    Text(
                      'Hydro Sense',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const SizedBox(height: AppSpace.xl),
                    TextField(
                      controller: _email,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: AppSpace.m),
                    TextField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      decoration: const InputDecoration(labelText: 'Password'),
                      onSubmitted: (_) => _busy ? null : _signIn(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpace.m),
                      Text(
                        _error!,
                        style: const TextStyle(color: Color(0xFF8A2A20)),
                        semanticsLabel: 'Error: $_error',
                      ),
                    ],
                    const SizedBox(height: AppSpace.l),
                    FilledButton(
                      onPressed: _busy ? null : _signIn,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => context.push('/reset'),
                      child: const Text('Forgot password?'),
                    ),
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
