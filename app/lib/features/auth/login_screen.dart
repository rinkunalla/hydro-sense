import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/password_field.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import 'staff_login.dart';

/// Sign in: staff with username + password on the phone app (5.1, D64),
/// the admin with email + password on the website (5.3). No sign-up.
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
  // The admin's email on the website, the staff username on the app.
  final _login = TextEditingController();
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
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_login.text.trim().isEmpty || _password.text.isEmpty) {
      setState(
        () => _error = widget.admin
            ? Messages.enterBoth
            : Messages.staffEnterBoth,
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authProvider)
          .signInWithEmailAndPassword(
            email: widget.admin
                ? _login.text.trim()
                : staffSignInAddress(_login.text),
            password: _password.text,
          );
      // Lets the password manager offer to save what worked.
      TextInput.finishAutofillContext();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = widget.admin ? authMessage(e) : staffAuthMessage(e),
        );
      }
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
                          controller: _login,
                          enabled: !_busy,
                          keyboardType: widget.admin
                              ? TextInputType.emailAddress
                              : TextInputType.text,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.next,
                          autofillHints: [
                            widget.admin
                                ? AutofillHints.email
                                : AutofillHints.username,
                          ],
                          decoration: InputDecoration(
                            labelText: widget.admin ? 'Email' : 'Username',
                          ),
                        ),
                        const SizedBox(height: AppSpace.m),
                        // Password managers may fill it (NIST SP 800-63B
                        // SHALL); they ask for the phone's lock before filling.
                        PasswordField(
                          controller: _password,
                          label: 'Password',
                          autofillHints: const [AutofillHints.password],
                          enabled: !_busy,
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
                        // Admins reset by Firebase's emailed link. Invited
                        // admins open the setup link from their invite email.
                        if (widget.admin)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => context.push('/reset'),
                            child: const Text('Forgot password?'),
                          )
                        else ...[
                          // Staff have no reset: the admin sets a new
                          // password and creates accounts (D64).
                          const SizedBox(height: AppSpace.s),
                          Text(
                            'Forgot your password? Ask your admin to set a new one.',
                            textAlign: TextAlign.center,
                            style: AppText.note,
                          ),
                          const SizedBox(height: AppSpace.xs),
                          Text(
                            'No account yet? Ask your admin to create one.',
                            textAlign: TextAlign.center,
                            style: AppText.note,
                          ),
                        ],
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
