import 'package:flutter/material.dart';

import 'config.dart';
import 'theme.dart';

/// One line of the new-password tips: only the length is required; the rest
/// are suggestions that make a password harder to guess.
typedef PasswordTip = ({String label, bool met, bool required});

List<PasswordTip> passwordTips(String p) => [
  (
    label: 'At least ${AppConfig.minPasswordLength} characters',
    met: p.length >= AppConfig.minPasswordLength,
    required: true,
  ),
  (
    label: 'A capital letter (A-Z)',
    met: RegExp('[A-Z]').hasMatch(p),
    required: false,
  ),
  (
    label: 'A small letter (a-z)',
    met: RegExp('[a-z]').hasMatch(p),
    required: false,
  ),
  (label: 'A number (0-9)', met: RegExp('[0-9]').hasMatch(p), required: false),
  (
    label: r'A symbol, like ! @ # $',
    met: RegExp(r'[^A-Za-z0-9\s]').hasMatch(p),
    required: false,
  ),
];

/// A password box with a show/hide eye. NIST SP 800-63B: verifiers SHOULD
/// offer to display the password while it is typed, and SHOULD allow paste
/// (Flutter allows it). Used for every password the app or website asks for.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.helperText,
    this.autofillHints,
    this.onSubmitted,
    this.textInputAction,
    this.showTips = false,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final String? helperText;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  /// For a new password: live tips under the box (length required, the rest
  /// suggested, never enforced).
  final bool showTips;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: !_shown,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.visiblePassword,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helperText,
        suffixIcon: IconButton(
          tooltip: _shown ? 'Hide password' : 'Show password',
          icon: Icon(
            _shown ? Icons.visibility_off_rounded : Icons.visibility_rounded,
            color: AppColors.steel,
          ),
          onPressed: () => setState(() => _shown = !_shown),
        ),
      ),
    );
    if (!widget.showTips) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        field,
        const SizedBox(height: AppSpace.s),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (_, v, _) => _Tips(passwordTips(v.text)),
        ),
      ],
    );
  }
}

class _Tips extends StatelessWidget {
  const _Tips(this.tips);

  final List<PasswordTip> tips;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (i, t) in tips.indexed) ...[
        if (i == 1)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs, bottom: 2),
            child: Text('Stronger with:', style: AppText.note),
          ),
        Semantics(
          label:
              '${t.label}, ${t.met ? 'done' : (t.required ? 'needed' : 'suggested')}',
          excludeSemantics: true,
          child: Row(
            children: [
              Icon(
                t.met
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: t.met
                    ? StatusStyle.of(StatusKind.normal).strong
                    : AppColors.steel,
              ),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Text(
                  t.label,
                  style: AppText.note.copyWith(
                    color: t.met ? AppColors.ink : AppColors.steel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}
