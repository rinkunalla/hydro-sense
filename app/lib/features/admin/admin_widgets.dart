import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/admin_logic.dart';

/// The admin site shows only connection states, never flow or battery colours
/// (D24, docs/UI_UX_SPEC.md section 6). Icon + word, never colour alone.
class StateBadge extends StatelessWidget {
  const StateBadge(this.state, {super.key, this.detail});

  final AdminState state;

  /// Extra words after the state, for example "since 3:42 PM".
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final (icon, color, word) = switch (state) {
      AdminState.online => (
        Icons.wifi_rounded,
        const Color(0xFF17845A),
        'Online',
      ),
      AdminState.offline => (
        Icons.cloud_off_rounded,
        const Color(0xFF5B6B80),
        'Offline',
      ),
      AdminState.notSetUp => (
        Icons.hourglass_empty_rounded,
        const Color(0xFFB87A00),
        'Not set up yet',
      ),
      AdminState.removed => (
        Icons.block_rounded,
        AppColors.errorText,
        'Removed',
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            detail == null ? word : '$word · $detail',
            overflow: TextOverflow.ellipsis,
            style: AppText.body.copyWith(fontSize: 14),
          ),
        ),
      ],
    );
  }
}

/// Page title with its main action on the right.
class AdminPageHeader extends StatelessWidget {
  const AdminPageHeader({
    super.key,
    required this.title,
    this.actions = const [],
  });

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.l),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: AppSpace.s,
      spacing: AppSpace.m,
      children: [
        Semantics(header: true, child: Text(title, style: AppText.title(28))),
        Wrap(spacing: AppSpace.s, runSpacing: AppSpace.s, children: actions),
      ],
    ),
  );
}

/// A filter pill with its count ("Unassigned 2").
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? null : const Color(0xE6FFFFFF),
      shape: const StadiumBorder(),
      child: Ink(
        decoration: selected
            ? const ShapeDecoration(
                shape: StadiumBorder(),
                gradient: LinearGradient(colors: AppColors.buttonStops),
              )
            : null,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              label,
              style: AppText.strong.copyWith(
                fontSize: 14,
                color: selected ? Colors.white : AppColors.ink,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Initials for an avatar ("Dana Perez" -> "DP").
String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  final s = parts.take(2).map((p) => p[0].toUpperCase()).join();
  return s.isEmpty ? '?' : s;
}

class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 40});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: AppColors.buttonStops),
      ),
      child: Text(
        initialsOf(name),
        style: AppText.strong.copyWith(
          color: Colors.white,
          fontSize: size * 0.38,
        ),
      ),
    ),
  );
}

/// Destructive confirmation (D42): the button turns on only once the admin
/// has typed [confirmWord] (the user's name or the device label).
Future<bool> confirmByTyping(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmWord,
  required String buttonLabel,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _TypeToConfirm(
        title: title,
        message: message,
        confirmWord: confirmWord,
        buttonLabel: buttonLabel,
      ),
    ) ??
    false;

/// Owns its text box, so the box lives exactly as long as the dialog
/// (including its closing animation).
class _TypeToConfirm extends StatefulWidget {
  const _TypeToConfirm({
    required this.title,
    required this.message,
    required this.confirmWord,
    required this.buttonLabel,
  });

  final String title;
  final String message;
  final String confirmWord;
  final String buttonLabel;

  @override
  State<_TypeToConfirm> createState() => _TypeToConfirmState();
}

class _TypeToConfirmState extends State<_TypeToConfirm> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool get _matches =>
      _c.text.trim().toLowerCase() == widget.confirmWord.trim().toLowerCase();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: AppSpace.l),
          Text('Type "${widget.confirmWord}" to confirm.', style: AppText.note),
          const SizedBox(height: AppSpace.s),
          TextField(
            controller: _c,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_matches) Navigator.pop(context, true);
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
        onPressed: _matches ? () => Navigator.pop(context, true) : null,
        child: Text(widget.buttonLabel),
      ),
    ],
  );
}

/// A yes/no question.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String buttonLabel,
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(message),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(buttonLabel),
          ),
        ],
      ),
    ) ??
    false;

/// A panel that slides in from the right over the page (Esc or the close
/// button dismiss it). Narrow screens get the full width.
Future<T?> showSidePanel<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext) builder,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: const Color(0x330A1B2E),
  transitionDuration: const Duration(milliseconds: 180),
  pageBuilder: (ctx, _, _) {
    final width = MediaQuery.sizeOf(ctx).width;
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: width < 520 ? width : 460,
        height: double.infinity,
        child: Material(
          color: AppColors.solidGlass,
          elevation: 8,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.l,
                    AppSpace.s,
                    AppSpace.s,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(title, style: AppText.title(20)),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpace.l),
                    child: builder(ctx),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  },
  transitionBuilder: (_, anim, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(0.08, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
    child: FadeTransition(opacity: anim, child: child),
  ),
);

/// A red error line under a form.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.text, {super.key});

  final String? text;

  @override
  Widget build(BuildContext context) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: AppSpace.s),
          child: Text(
            text!,
            style: AppText.body.copyWith(
              color: AppColors.errorText,
              fontSize: 14,
            ),
          ),
        );
}

/// The admin wording for a failed admin call (docs/UI_UX_SPEC.md 6).
String adminErrorText(Object e) => switch (callableDetails(e).code) {
  'EMAIL_IN_USE' => 'Another account already uses this email.',
  'PHONE_IN_USE' => 'Another user already has this mobile number.',
  'PHONE_INVALID' => Messages.phoneHint,
  'EMAIL_INVALID' => 'Enter a valid email address.',
  'NAME_INVALID' => 'Enter a name (1 to 60 characters).',
  'LABEL_INVALID' => 'Use a label of 1 to 24 characters.',
  'DEVICE_ID_INVALID' =>
    'Enter the 12-character ID shown on the device label or setup page.',
  'DEVICE_EXISTS' => 'This device is already added.',
  'DEVICE_NOT_FOUND' => 'This device is not on the list any more.',
  'USER_NOT_FOUND' => 'That user no longer exists.',
  'USER_SUSPENDED' => 'This user is deleted. Restore them first.',
  'CONFIRM_MISMATCH' => "The typed name doesn't match.",
  'LAST_ADMIN' => 'You are the only admin. Invite another admin first.',
  'SELF_REMOVE' => 'Ask another admin to remove you.',
  'INVITE_NOT_PENDING' => 'This admin has already signed in.',
  'COOLDOWN' => 'Too many setup links this hour. Try again later.',
  'RESTORE_EXPIRED' => 'The 30 days to restore have passed.',
  _ => callableMessage(e),
};

/// Glass card with a title, for the Account page.
class AdminCard extends StatelessWidget {
  const AdminCard({
    super.key,
    required this.title,
    required this.child,
    this.action,
  });

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => GlassPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: AppText.title(18)),
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: AppSpace.m),
        child,
      ],
    ),
  );
}
