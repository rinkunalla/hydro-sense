import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/password_field.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/account_repository.dart';
import 'code_entry.dart';
import 'password_rules.dart';

/// Set or reset the password with a 6-digit code, 3 steps (D22, D59,
/// docs/UI_UX_SPEC.md 5.2): by email first, or by mobile number. No reset link:
/// the code is typed here and the new password is set here. Step 1 always
/// continues, so it never reveals whether an address has an account.
class SmsResetScreen extends ConsumerStatefulWidget {
  const SmsResetScreen({super.key, this.now});

  final DateTime Function()? now;

  @override
  ConsumerState<SmsResetScreen> createState() => _SmsResetScreenState();
}

class _SmsResetScreenState extends ConsumerState<SmsResetScreen> {
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  // Email first: it works before any SMS sender is approved, and the code
  // never leaves the app as a clickable link (D59).
  bool _byEmail = true;
  final _a = TextEditingController();
  final _b = TextEditingController();
  int _step = 1;
  bool _busy = false;
  String? _error;
  String _code = '';
  String? _token;
  DateTime? _sentAt;
  int _resendAfter = AppConfig.resetResendS;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void dispose() {
    _mobile.dispose();
    _email.dispose();
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  /// 09171234567 / +639171234567 -> 639171234567, else null.
  String? get _phone {
    final raw = _mobile.text.replaceAll(RegExp(r'[\s-]'), '');
    if (!AppConfig.phMobilePattern.hasMatch(raw)) return null;
    final digits = raw.replaceAll('+', '');
    return digits.startsWith('0') ? '63${digits.substring(1)}' : digits;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      final d = callableDetails(e);
      if (mounted) {
        setState(
          () => _error = d.code == 'COOLDOWN'
              ? 'Wait ${mmss(d.retryAfterSeconds ?? 60)} before asking again.'
              : d.code == 'PHONE_INVALID'
              ? Messages.phoneHint
              : d.code == 'PASSWORD_WEAK'
              ? 'Use at least ${AppConfig.minPasswordLength} characters.'
              : d.code == null
              ? authOrCodeMessage(e)
              : codeErrorText(d.code, d.triesLeft),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String authOrCodeMessage(Object e) =>
      authMessage(e) == Messages.generic ? callableMessage(e) : authMessage(e);

  /// The email typed, trimmed and lower-case, or null when it is not one.
  String? get _emailAddress {
    final e = _email.text.trim().toLowerCase();
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(e) ? e : null;
  }

  /// Where the code goes: the email, or the mobile number.
  String? get _address => _byEmail ? _emailAddress : _phone;

  /// "j•••@gmail.com" or "0917 ••• 4567", for "a code is on its way".
  String get _maskedAddress {
    if (!_byEmail) return maskedPhone(_phone);
    final e = _emailAddress ?? '';
    final at = e.indexOf('@');
    return at < 1 ? e : '${e[0]}•••${e.substring(at)}';
  }

  Future<void> _send() async {
    final address = _address;
    if (address == null) {
      setState(
        () => _error = _byEmail
            ? 'Enter the email on your account.'
            : Messages.phoneHint,
      );
      return;
    }
    await _run(() async {
      _resendAfter = await ref
          .read(accountRepositoryProvider)
          .requestResetCode(address, byEmail: _byEmail);
      _sentAt = _now();
      if (mounted) setState(() => _step = 2);
    });
  }

  void _switchMode() => setState(() {
    _byEmail = !_byEmail;
    _error = null;
  });

  Future<void> _verify() => _run(() async {
    _token = await ref
        .read(accountRepositoryProvider)
        .verifyResetCode(_address!, _code, byEmail: _byEmail);
    if (mounted) setState(() => _step = 3);
  });

  Future<void> _save() async {
    final problem = validateNewPassword(_a.text, _b.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    await _run(() async {
      await ref
          .read(accountRepositoryProvider)
          .setPasswordAndSignIn(_token!, _a.text);
      if (mounted) showToast(context, "Password saved. You're signed in.");
      // The router moves on to Devices once the session arrives.
    });
  }

  Widget _errorText() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: AppSpace.m),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.error_rounded,
                size: 18,
                color: AppColors.danger,
              ),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Text(
                  _error!,
                  style: AppText.body.copyWith(
                    color: AppColors.errorText,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        );

  @override
  Widget build(BuildContext context) {
    final step = switch (_step) {
      1 when _byEmail => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StepHeader(step: 1, title: 'Your email'),
          const SizedBox(height: AppSpace.xs),
          Text(
            "We'll email you a 6-digit code to set a new password.",
            style: AppText.note,
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
          _errorText(),
          const SizedBox(height: AppSpace.l),
          PrimaryButton(label: 'Send the code', busy: _busy, onPressed: _send),
          TextButton(
            onPressed: _busy ? null : _switchMode,
            child: const Text('Use my mobile number instead'),
          ),
        ],
      ),
      1 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StepHeader(step: 1, title: 'Your mobile number'),
          const SizedBox(height: AppSpace.l),
          TextField(
            controller: _mobile,
            enabled: !_busy,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: const InputDecoration(
              labelText: 'Mobile number',
              hintText: '0917 123 4567',
            ),
            onSubmitted: (_) => _send(),
          ),
          _errorText(),
          const SizedBox(height: AppSpace.l),
          PrimaryButton(label: 'Send the code', busy: _busy, onPressed: _send),
          TextButton(
            onPressed: _busy ? null : _switchMode,
            child: const Text('Use my email instead'),
          ),
        ],
      ),
      2 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StepHeader(step: 2, title: 'Enter the code'),
          const SizedBox(height: AppSpace.s),
          // Same words for any number, so nobody can learn who has an
          // account (enumeration-safe, CLAUDE.md section 6).
          Text(
            'If $_maskedAddress has an account, a 6-digit code is on '
            'its way. It can take a minute.',
            style: AppText.body,
          ),
          if (_byEmail) ...[
            const SizedBox(height: AppSpace.xs),
            Text('Not in your inbox? Check spam.', style: AppText.note),
          ],
          const SizedBox(height: AppSpace.l),
          CodeEntry(
            sentAt: _sentAt ?? _now(),
            resendAfterSeconds: _resendAfter,
            enabled: !_busy,
            now: widget.now,
            onChanged: (v) => setState(() => _code = v),
            onResend: _send,
          ),
          _errorText(),
          const SizedBox(height: AppSpace.l),
          PrimaryButton(
            label: 'Continue',
            busy: _busy,
            onPressed: _code.length == AppConfig.resetCodeLength
                ? _verify
                : null,
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _step = 1;
                    _error = null;
                  }),
            child: Text(
              _byEmail
                  ? 'Wrong email? Go back and try again.'
                  : 'Wrong number? Go back and try again.',
            ),
          ),
        ],
      ),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StepHeader(step: 3, title: 'New password'),
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
          _errorText(),
          const SizedBox(height: AppSpace.l),
          PrimaryButton(label: 'Save password', busy: _busy, onPressed: _save),
        ],
      ),
    };

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.l),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back to sign in',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => context.go('/login'),
                ),
              ),
              const SizedBox(height: AppSpace.s),
              GlassPanel(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: step,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
