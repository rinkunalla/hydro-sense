import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/password_field.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import '../auth/password_rules.dart';
import 'admin_widgets.dart';

/// Wording for a failed staff action: the backend's codes, else the general text.
String staffError(Object e) {
  final code = callableDetails(e).code;
  return switch (code) {
    'USERNAME_IN_USE' => 'Another account already uses this username.',
    'USERNAME_INVALID' =>
      'Use ${AppConfig.usernameMin} to ${AppConfig.usernameMax} letters, numbers, dots, dashes or underscores, with no spaces.',
    'PHONE_IN_USE' => Messages.phoneInUse,
    'PHONE_INVALID' => 'Enter a Philippine mobile number, like 0917 123 4567.',
    'EMAIL_INVALID' => 'Enter a valid email address.',
    'NAME_INVALID' => Messages.nameEmpty,
    'PASSWORD_WEAK' =>
      'Use at least ${AppConfig.minPasswordLength} characters.',
    'CONFIRM_MISMATCH' => "The typed name doesn't match.",
    _ =>
      e is FirebaseFunctionsException && e.code == 'invalid-argument'
          ? (e.message ?? Messages.generic)
          : callableMessage(e),
  };
}

/// "0917 123 4567 · ana@x.ph", or what is missing.
String contactsOf(StaffMember s) {
  final parts = [
    if (s.phone != null) displayPhone(s.phone),
    if (s.email != null) s.email!,
  ];
  return parts.isEmpty ? 'App alerts only' : parts.join(' · ');
}

/// The Staff page (D64): the admin creates, edits, disables, deletes and
/// resets the password of every staff account. Staff change nothing.
class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});

  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => const _AddStaffDialog(),
    );
    if (created == true && mounted) {
      ref.invalidate(staffProvider);
      showToast(context, 'Staff account created');
    }
  }

  void _open(StaffMember s) => showSidePanel<void>(
    context,
    title: s.name,
    builder: (_) => _StaffPanel(member: s),
  ).then((_) => ref.invalidate(staffProvider));

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(staffProvider);
    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
        AdminPageHeader(
          title: 'Staff',
          actions: [
            PrimaryButton(
              label: 'Add staff',
              icon: Icons.person_add_alt_1_rounded,
              onPressed: _add,
            ),
          ],
        ),
        Text(
          'Staff sign in to the phone app with the username and password you give them. '
          'Alerts reach them on the app, and by SMS and email when you add a mobile number or email.',
          style: AppText.note,
        ),
        const SizedBox(height: AppSpace.m),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            labelText: 'Search by name, username, mobile or email',
          ),
        ),
        const SizedBox(height: AppSpace.m),
        staff.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text(callableMessage(e), style: AppText.body),
          data: (all) {
            final shown = sortStaff(
              all,
            ).where((s) => staffMatches(s, _search.text)).toList();
            if (all.isEmpty) {
              return GlassPanel(
                child: Text(
                  'No staff yet. Add the people who check the water lines.',
                  style: AppText.body,
                ),
              );
            }
            if (shown.isEmpty) {
              return Text('No staff match your search.', style: AppText.body);
            }
            return GlassPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final s in shown)
                    ListTile(
                      onTap: () => _open(s),
                      leading: Avatar(s.name, size: 40),
                      title: Text(
                        s.disabled ? '${s.name} · Disabled' : s.name,
                        style: AppText.strong.copyWith(
                          color: s.disabled ? AppColors.steel : AppColors.ink,
                        ),
                      ),
                      subtitle: Text(
                        '${s.username} · ${contactsOf(s)}',
                        style: AppText.note,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        s.lastSignIn == null
                            ? 'Never signed in'
                            : 'Signed in ${relativeAge(s.lastSignIn!, now)}',
                        style: AppText.note,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _AddStaffDialog extends ConsumerStatefulWidget {
  const _AddStaffDialog();

  @override
  ConsumerState<_AddStaffDialog> createState() => _AddStaffDialogState();
}

class _AddStaffDialogState extends ConsumerState<_AddStaffDialog> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _again = TextEditingController();
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _username, _password, _again, _mobile, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final problem = _name.text.trim().isEmpty
        ? Messages.nameEmpty
        : _username.text.trim().isEmpty
        ? 'Enter a username.'
        : validateNewPassword(_password.text, _again.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(adminRepositoryProvider)
          .createStaff(
            name: _name.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
            mobile: _mobile.text.trim().isEmpty ? null : _mobile.text.trim(),
            email: _email.text.trim().isEmpty ? null : _email.text.trim(),
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = staffError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add staff'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              maxLength: AppConfig.userNameMax,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: _username,
              enabled: !_busy,
              maxLength: AppConfig.usernameMax,
              decoration: const InputDecoration(
                labelText: 'Username',
                helperText: 'What they type to sign in, like juan.dc',
              ),
            ),
            const SizedBox(height: AppSpace.s),
            PasswordField(
              controller: _password,
              label: 'First password',
              enabled: !_busy,
            ),
            const SizedBox(height: AppSpace.s),
            PasswordField(
              controller: _again,
              label: 'Password again',
              enabled: !_busy,
            ),
            const SizedBox(height: AppSpace.s),
            TextField(
              controller: _mobile,
              enabled: !_busy,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile number (optional)',
                helperText: 'For SMS alerts',
              ),
            ),
            TextField(
              controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email (optional)',
                helperText: 'For email alerts',
              ),
            ),
            ErrorLine(_error),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? 'Saving…' : 'Add staff'),
      ),
    ],
  );
}

/// One staff member: details, password reset, disable or enable, delete.
class _StaffPanel extends ConsumerStatefulWidget {
  const _StaffPanel({required this.member});

  final StaffMember member;

  @override
  ConsumerState<_StaffPanel> createState() => _StaffPanelState();
}

class _StaffPanelState extends ConsumerState<_StaffPanel> {
  late final _name = TextEditingController(text: widget.member.name);
  late final _username = TextEditingController(text: widget.member.username);
  late final _mobile = TextEditingController(
    text: widget.member.phone == null ? '' : displayPhone(widget.member.phone),
  );
  late final _email = TextEditingController(text: widget.member.email ?? '');
  late bool _disabled = widget.member.disabled;
  bool _busy = false;
  String? _error;

  StaffMember get m => widget.member;

  @override
  void dispose() {
    for (final c in [_name, _username, _mobile, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) showToast(context, done);
    } catch (e) {
      if (mounted) setState(() => _error = staffError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  AdminRepository get _repo => ref.read(adminRepositoryProvider);

  Future<void> _save() => _run(
    () => _repo.updateStaff(
      m.uid,
      name: _name.text.trim(),
      username: _username.text.trim(),
      // Empty removes the contact, which stops that alert channel (D65).
      mobile: _mobile.text.trim(),
      email: _email.text.trim(),
    ),
    'Saved',
  );

  Future<void> _toggleDisabled() async {
    final next = !_disabled;
    if (next) {
      final ok = await confirmAction(
        context,
        title: 'Disable ${m.name}?',
        message:
            'They are signed out at once, can\'t sign in, and get no alerts until you enable the account again.',
        buttonLabel: 'Disable',
        destructive: true,
      );
      if (!ok) return;
    }
    await _run(
      () => _repo.updateStaff(m.uid, disabled: next),
      next ? 'Account disabled' : 'Account enabled',
    );
    if (mounted && _error == null) setState(() => _disabled = next);
  }

  Future<void> _resetPassword() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _ResetPasswordDialog(member: m),
    );
    if (changed == true && mounted) {
      showToast(context, 'Password changed. Tell ${m.name} the new one.');
    }
  }

  Future<void> _delete() async {
    final ok = await confirmByTyping(
      context,
      title: 'Delete ${m.name}?',
      message:
          'The account is deleted at once and can\'t be restored. Their alerts stop.',
      confirmWord: m.name,
      buttonLabel: 'Delete staff',
    );
    if (!ok || !mounted) return;
    await _run(
      () => _repo.deleteStaff(m.uid, confirmName: m.name),
      'Staff account deleted',
    );
    if (mounted && _error == null) Navigator.pop(context);
  }

  // A column: the side panel scrolls its content itself.
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _name,
        enabled: !_busy,
        maxLength: AppConfig.userNameMax,
        decoration: const InputDecoration(labelText: 'Name'),
      ),
      TextField(
        controller: _username,
        enabled: !_busy,
        maxLength: AppConfig.usernameMax,
        decoration: const InputDecoration(labelText: 'Username'),
      ),
      TextField(
        controller: _mobile,
        enabled: !_busy,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(
          labelText: 'Mobile number',
          helperText: 'Empty: no SMS alerts',
        ),
      ),
      TextField(
        controller: _email,
        enabled: !_busy,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(
          labelText: 'Email',
          helperText: 'Empty: no email alerts',
        ),
      ),
      ErrorLine(_error),
      const SizedBox(height: AppSpace.m),
      PrimaryButton(label: 'Save', busy: _busy, onPressed: _save),
      const SizedBox(height: AppSpace.xl),
      const SectionLabel('Sign-in'),
      SecondaryButton(
        label: 'Set a new password',
        icon: Icons.key_rounded,
        onPressed: _busy ? null : _resetPassword,
      ),
      const SizedBox(height: AppSpace.s),
      SecondaryButton(
        label: _disabled ? 'Enable account' : 'Disable account',
        icon: _disabled ? Icons.lock_open_rounded : Icons.block_rounded,
        onPressed: _busy ? null : _toggleDisabled,
      ),
      const SizedBox(height: AppSpace.xl),
      SecondaryButton(
        label: 'Delete staff',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        onPressed: _busy ? null : _delete,
      ),
    ],
  );
}

class _ResetPasswordDialog extends ConsumerStatefulWidget {
  const _ResetPasswordDialog({required this.member});

  final StaffMember member;

  @override
  ConsumerState<_ResetPasswordDialog> createState() =>
      _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends ConsumerState<_ResetPasswordDialog> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _busy = false;
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
      await ref
          .read(adminRepositoryProvider)
          .resetStaffPassword(widget.member.uid, _a.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = staffError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('New password for ${widget.member.name}'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Their old password stops working and they are signed out everywhere.',
            style: AppText.note,
          ),
          const SizedBox(height: AppSpace.m),
          PasswordField(controller: _a, label: 'New password', enabled: !_busy),
          const SizedBox(height: AppSpace.s),
          PasswordField(
            controller: _b,
            label: 'New password again',
            enabled: !_busy,
          ),
          ErrorLine(_error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? 'Saving…' : 'Set password'),
      ),
    ],
  );
}
