import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';

/// "4:32" for the code timers.
String mmss(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The wording for a failed code check (docs/UI_UX_SPEC.md 5.2).
String codeErrorText(String? code, int? triesLeft) => switch (code) {
  'RESET_CODE_INVALID' =>
    'That code is not right. ${triesLeft ?? 0} ${triesLeft == 1 ? 'try' : 'tries'} left.',
  'RESET_CODE_EXPIRED' => Messages.codeExpired,
  'RESET_LOCKED' => Messages.codeLocked,
  'DAILY_LIMIT' => Messages.dailyLimit,
  'RESET_TOKEN_INVALID' => Messages.resetExpired,
  _ => Messages.generic,
};

/// Six code boxes over one hidden field (so paste and SMS autofill work), plus
/// the expiry and resend timers.
class CodeEntry extends StatefulWidget {
  const CodeEntry({
    super.key,
    required this.sentAt,
    required this.resendAfterSeconds,
    required this.onResend,
    required this.onChanged,
    this.enabled = true,
    this.now,
  });

  final DateTime sentAt;
  final int resendAfterSeconds;
  final Future<void> Function() onResend;
  final ValueChanged<String> onChanged;
  final bool enabled;

  /// Tests pass a fixed clock.
  final DateTime Function()? now;

  @override
  State<CodeEntry> createState() => _CodeEntryState();
}

class _CodeEntryState extends State<CodeEntry> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  Timer? _tick;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _now().difference(widget.sentAt).inSeconds;
    final expiresIn = AppConfig.resetCodeTtlS - elapsed;
    final resendIn = widget.resendAfterSeconds - elapsed;
    final text = _c.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < AppConfig.resetCodeLength; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpace.s),
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 0.85,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xF2FFFFFF),
                          borderRadius: BorderRadius.circular(
                            AppSpace.tileRadius,
                          ),
                          border: Border.all(
                            color: i == text.length && _focus.hasFocus
                                ? AppColors.deepCyan
                                : AppColors.outline,
                            width: i == text.length && _focus.hasFocus ? 2 : 1,
                          ),
                        ),
                        child: Text(
                          i < text.length ? text[i] : '',
                          style: AppText.reading(24),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: _c,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(AppConfig.resetCodeLength),
                  ],
                  decoration: const InputDecoration(labelText: '6-digit code'),
                  onChanged: (v) {
                    setState(() {});
                    widget.onChanged(v);
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.m),
        Text(
          expiresIn > 0
              ? 'Code expires in ${mmss(expiresIn)}'
              : Messages.codeExpired,
          style: AppText.note,
        ),
        if (resendIn > 0)
          Text('Send again in ${mmss(resendIn)}', style: AppText.note)
        else
          TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
            ),
            onPressed: widget.enabled
                ? () async {
                    _c.clear();
                    widget.onChanged('');
                    await widget.onResend();
                  }
                : null,
            child: const Text('Send the code again'),
          ),
      ],
    );
  }
}

/// "Step n of 3" header shared by the reset and mobile-change flows.
class StepHeader extends StatelessWidget {
  const StepHeader({super.key, required this.step, required this.title});

  final int step;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('STEP $step OF 3', style: AppText.label),
      const SizedBox(height: AppSpace.xs),
      Semantics(header: true, child: Text(title, style: AppText.title(24))),
    ],
  );
}
