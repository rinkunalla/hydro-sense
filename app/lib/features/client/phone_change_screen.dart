import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/account_repository.dart';
import '../auth/code_entry.dart';
import 'account_screen.dart' show accountError;

/// Change mobile number, 3 steps (D31, docs/UI_UX_SPEC.md 5.5): the code goes to
/// the NEW number; the change applies once it is confirmed.
class PhoneChangeScreen extends ConsumerStatefulWidget {
  const PhoneChangeScreen({super.key, this.now});

  final DateTime Function()? now;

  @override
  ConsumerState<PhoneChangeScreen> createState() => _PhoneChangeScreenState();
}

class _PhoneChangeScreenState extends ConsumerState<PhoneChangeScreen> {
  final _mobile = TextEditingController();
  final _password = TextEditingController();
  int _step = 1;
  bool _busy = false;
  String? _error;
  String _code = '';
  String _sentTo = '';
  DateTime? _sentAt;
  int _resendAfter = AppConfig.resetResendS;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void dispose() {
    _mobile.dispose();
    _password.dispose();
    super.dispose();
  }

  void _done() => context.canPop() ? context.pop() : context.go('/account');

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
              : d.code == 'REAUTH_REQUIRED'
              ? 'Enter your current password again.'
              : d.code != null && d.code!.startsWith('RESET_') ||
                    d.code == 'DAILY_LIMIT'
              ? codeErrorText(d.code, d.triesLeft)
              : accountError(e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send({bool again = false}) async {
    final raw = _mobile.text.replaceAll(RegExp(r'[\s-]'), '');
    if (!AppConfig.phMobilePattern.hasMatch(raw)) {
      setState(() => _error = Messages.phoneHint);
      return;
    }
    await _run(() async {
      final repo = ref.read(accountRepositoryProvider);
      if (!again) await repo.reauthenticate(_password.text);
      final r = await repo.requestPhoneChangeCode(raw);
      _sentTo = r.sentTo;
      _resendAfter = r.resendAfterSeconds;
      _sentAt = _now();
      if (mounted) setState(() => _step = 2);
    });
  }

  Future<void> _confirm() => _run(() async {
    final masked = await ref
        .read(accountRepositoryProvider)
        .confirmPhoneChange(_code);
    if (!mounted) return;
    showToast(context, 'Mobile number changed. Alerts now go to $masked.');
    _done();
  });

  @override
  Widget build(BuildContext context) {
    final error = _error == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: AppSpace.m),
            child: Text(
              _error!,
              style: AppText.body.copyWith(
                color: AppColors.errorText,
                fontSize: 14,
              ),
            ),
          );
    final body = _step == 1
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const StepHeader(step: 1, title: 'New mobile number'),
              const SizedBox(height: AppSpace.l),
              TextField(
                controller: _mobile,
                enabled: !_busy,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'New mobile number',
                  hintText: '0918 222 2210',
                ),
              ),
              const SizedBox(height: AppSpace.m),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                ),
                onSubmitted: (_) => _send(),
              ),
              error,
              const SizedBox(height: AppSpace.l),
              PrimaryButton(
                label: 'Send the code',
                busy: _busy,
                onPressed: _send,
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const StepHeader(step: 2, title: 'Enter the code'),
              const SizedBox(height: AppSpace.s),
              Text(
                'We sent a 6-digit code to your new number $_sentTo.',
                style: AppText.body,
              ),
              const SizedBox(height: AppSpace.l),
              CodeEntry(
                sentAt: _sentAt ?? _now(),
                resendAfterSeconds: _resendAfter,
                enabled: !_busy,
                now: widget.now,
                onChanged: (v) => setState(() => _code = v),
                onResend: () => _send(again: true),
              ),
              error,
              const SizedBox(height: AppSpace.l),
              PrimaryButton(
                label: 'Confirm',
                busy: _busy,
                onPressed: _code.length == AppConfig.resetCodeLength
                    ? _confirm
                    : null,
              ),
            ],
          );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.l),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _done,
              ),
            ),
            GlassPanel(padding: const EdgeInsets.all(AppSpace.xl), child: body),
          ],
        ),
      ),
    );
  }
}
