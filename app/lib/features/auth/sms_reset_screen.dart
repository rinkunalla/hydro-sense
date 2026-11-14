import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/account_repository.dart';
import 'code_entry.dart';
import 'password_rules.dart';

/// Set or reset the password by SMS code, 3 steps (D22, docs/UI_UX_SPEC.md 5.2).
/// Step 1 always continues, so it never reveals whether a number has an account.
class SmsResetScreen extends ConsumerStatefulWidget {
  const SmsResetScreen({super.key, this.now});

  final DateTime Function()? now;

  @override
  ConsumerState<SmsResetScreen> createState() => _SmsResetScreenState();
}

class _SmsResetScreenState extends ConsumerState<SmsResetScreen> {
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  bool _byEmail = false;
  String? _emailSentTo;
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

  Future<void> _send() async {
    final phone = _phone;
    if (phone == null) {
      setState(() => _error = Messages.phoneHint);
      return;
    }
    await _run(() async {
      _resendAfter = await ref
          .read(accountRepositoryProvider)
          .requestResetCode(phone);
      _sentAt = _now();
      if (mounted) setState(() => _step = 2);
    });
  }

  /// Email link instead of an SMS code. Same reply whether or not the address
  /// has an account; only "no internet" and "too many tries" are told apart.
  Future<void> _sendEmail() async {
    final email = _email.text.trim();
    if (!email.contains('@') || email.length < 5) {
      setState(() => _error = 'Enter the email on your account.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountRepositoryProvider).sendResetEmail(email);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'network-request-failed' || e.code == 'too-many-requests') {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = authMessage(e);
          });
        }
        return;
      }
    } catch (_) {
      // Every other outcome gets the same confirmation (no account enumeration).
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _emailSentTo = email;
      });
    }
  }

  void _switchMode() => setState(() {
    _byEmail = !_byEmail;
    _error = null;
    _emailSentTo = null;
  });

  Widget _emailStep() {
    final sentTo = _emailSentTo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text('Set your password by email', style: AppText.title(24)),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          "We'll email you a link. Open it to choose a password.",
          style: AppText.note,
        ),
        const SizedBox(height: AppSpace.l),
        if (sentTo == null) ...[
          TextField(
            controller: _email,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email'),
            onSubmitted: (_) => _sendEmail(),
          ),
          _errorText(),
          const SizedBox(height: AppSpace.l),
          PrimaryButton(
            label: 'Send the link',
            busy: _busy,
            onPressed: _sendEmail,
          ),
        ] else ...[
          Text(
            'If $sentTo has an account, we sent a link to it. Open the link, '
            'choose a password, then come back and sign in.',
            style: AppText.body,
          ),
          const SizedBox(height: AppSpace.s),
          Text(
            "Not there after a few minutes? Check your spam folder.",
            style: AppText.note,
          ),
          const SizedBox(height: AppSpace.l),
          PrimaryButton(
            label: 'Back to sign in',
            onPressed: () => context.go('/login'),
          ),
        ],
        TextButton(
          onPressed: _busy ? null : _switchMode,
          child: const Text('Use my mobile number instead'),
        ),
      ],
    );
  }

  Future<void> _verify() => _run(() async {
    _token = await ref
        .read(accountRepositoryProvider)
        .verifyResetCode(_phone!, _code);
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
      1 when _byEmail => _emailStep(),
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
          Text(Messages.codeSent, style: AppText.note),
          Text(
            'We sent a 6-digit code to ${maskedPhone(_phone)}.',
            style: AppText.body,
          ),
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
            child: const Text('Wrong number? Go back and try again.'),
          ),
        ],
      ),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StepHeader(step: 3, title: 'New password'),
          const SizedBox(height: AppSpace.l),
          TextField(
            controller: _a,
            enabled: !_busy,
            obscureText: true,
            autofillHints: const [AutofillHints.newPassword],
            decoration: const InputDecoration(
              labelText: 'New password',
              helperText: 'At least 8 characters',
            ),
          ),
          const SizedBox(height: AppSpace.m),
          TextField(
            controller: _b,
            enabled: !_busy,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Type it again'),
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
