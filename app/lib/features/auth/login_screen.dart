import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';

/// Sign in with email + password; no sign-up (docs/UI_UX_SPEC.md 5.1 and 5.3).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.refused, this.admin = false});

  /// "admin", "notadmin" or "other" when a signed-in account was refused here.
  final String? refused;

  /// The admin website's wording (5.3) instead of the phone app's (5.1).
  final bool admin;

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
      WidgetsBinding.instance.addPostFrameCallback((_) => signOut(ref));
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
    return AppBackground(
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
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              AppSpace.tileRadius + 4,
                            ),
                            gradient: const LinearGradient(
                              colors: AppColors.buttonStops,
                            ),
                          ),
                          child: const Icon(
                            Icons.water_drop_rounded,
                            size: 34,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: AppSpace.m),
                        Semantics(
                          header: true,
                          child: Text(
                            widget.admin ? 'Hydro Sense admin' : 'Hydro Sense',
                            textAlign: TextAlign.center,
                            style: AppText.title(28),
                          ),
                        ),
                        if (!widget.admin)
                          Text(
                            'Know your water is flowing',
                            textAlign: TextAlign.center,
                            style: AppText.body.copyWith(
                              color: AppColors.steel,
                            ),
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
                          decoration: const InputDecoration(
                            labelText: 'Password',
                          ),
                          onSubmitted: (_) => _busy ? null : _signIn(),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: AppSpace.m),
                          Text(
                            _error!,
                            style: AppText.body.copyWith(
                              color: AppColors.errorText,
                              fontSize: 14,
                            ),
                            semanticsLabel: 'Error: $_error',
                          ),
                        ],
                        const SizedBox(height: AppSpace.l),
                        PrimaryButton(
                          label: 'Sign in',
                          busy: _busy,
                          onPressed: _signIn,
                        ),
                        const SizedBox(height: AppSpace.s),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => context.push('/reset'),
                          child: Text(
                            widget.admin
                                ? 'Forgot password?'
                                : 'Forgot password or first time?',
                          ),
                        ),
                        if (!widget.admin)
                          Text(
                            'No account yet? Ask your installer to create one.',
                            textAlign: TextAlign.center,
                            style: AppText.note,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
