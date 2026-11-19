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
import '../../data/models.dart';
import '../../data/providers.dart';
import '../auth/password_rules.dart';

/// Account.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  AlertPrefs? _pending; // optimistic switches while a save runs

  @override
  void initState() {
    super.initState();
    // A verify-before-update link opened since the last visit: copy the new email.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final authEmail = ref.read(userProvider).valueOrNull?.email;
      final saved = ref.read(profileProvider).valueOrNull?.email;
      if (authEmail != null && saved != null && authEmail != saved) {
        try {
          await ref.read(accountRepositoryProvider).syncMyEmail();
        } catch (_) {}
      }
    });
  }

  Future<void> _setPrefs(AlertPrefs next) async {
    final uid = ref.read(uidProvider);
    if (uid == null) return;
    setState(() => _pending = next);
    try {
      await ref.read(repositoryProvider).setAlertPrefs(uid, next);
    } catch (_) {
      if (mounted) showToast(context, Messages.saveFailed);
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  Future<void> _requestDeletion() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Request account deletion?'),
        content: const Text(
          'Ask your Hydro Sense provider to delete your account? Your devices and history will be removed after that. You can keep using the app until then.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Send request'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(accountRepositoryProvider).requestAccountDeletion();
      if (mounted) {
        showToast(
          context,
          'Request sent. Your Hydro Sense provider will contact you.',
        );
      }
    } catch (e) {
      if (mounted) showToast(context, callableMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileProvider).valueOrNull;
    final prefs = _pending ?? p?.alertPrefs ?? const AlertPrefs();
    final solid = ref.watch(solidGlassProvider);
    final name = p?.displayName ?? '';
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();

    Widget row(String label, String value, VoidCallback onChange) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.note),
                Text(value, style: AppText.strong),
              ],
            ),
          ),
          SecondaryButton(label: 'Change', onPressed: onChange),
        ],
      ),
    );

    Widget toggle(
      String title,
      String note,
      bool value,
      ValueChanged<bool> on,
    ) => MergeSemantics(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: AppText.strong),
        subtitle: Text(note, style: AppText.note),
        value: value,
        activeThumbColor: Colors.white,
        activeTrackColor: AppColors.deepCyan,
        onChanged: _pending == null || toggleIsDisplay(title) ? on : null,
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.l,
            AppSpace.xl,
            AppSpace.l,
            AppSpace.xxl * 3,
          ),
          children: [
            Semantics(
              header: true,
              child: Text('Account', style: AppText.title(26)),
            ),
            const SizedBox(height: AppSpace.l),
            GlassPanel(
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: AppColors.tint,
                    child: Text(
                      initials.isEmpty ? '?' : initials,
                      style: AppText.title(
                        20,
                      ).copyWith(color: AppColors.deepCyan),
                    ),
                  ),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: AppText.title(20)),
                        Text(
                          '${p?.deviceCount ?? 0} ${p?.deviceCount == 1 ? 'device' : 'devices'}',
                          style: AppText.note,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.m),
            GlassPanel(
              child: Column(
                children: [
                  row('Name', name, () => _dialog(_NameDialog(current: name))),
                  row(
                    'Mobile number',
                    displayPhone(p?.phone),
                    () => context.go('/account/phone'),
                  ),
                  row(
                    'Email',
                    p?.email ?? '-',
                    () => _dialog(const _EmailDialog()),
                  ),
                  row(
                    'Password',
                    '••••••••',
                    () => _dialog(const ChangePasswordDialog()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.l),
            const SectionLabel('Alerts'),
            GlassPanel(
              child: Column(
                children: [
                  toggle(
                    'Phone notification',
                    'Every alert, right away',
                    prefs.push,
                    (v) => _setPrefs(prefs.copyWith(push: v)),
                  ),
                  toggle(
                    'SMS',
                    'When water stops',
                    prefs.sms,
                    (v) => _setPrefs(prefs.copyWith(sms: v)),
                  ),
                  toggle(
                    'Email',
                    'Every alert',
                    prefs.email,
                    (v) => _setPrefs(prefs.copyWith(email: v)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.l),
            const SectionLabel('Display'),
            GlassPanel(
              child: toggle(
                'Solid glass',
                'Easier to read: no see-through panels',
                solid,
                (v) => ref.read(solidGlassProvider.notifier).set(v),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            SecondaryButton(
              label: 'Sign out',
              icon: Icons.logout_rounded,
              destructive: true,
              onPressed: () => signOut(ref),
            ),
            const SizedBox(height: AppSpace.s),
            Center(
              child: p?.deletionRequested == true
                  ? Text(
                      'Deletion requested. Your Hydro Sense provider will contact you.',
                      style: AppText.note,
                    )
                  : TextButton(
                      onPressed: _requestDeletion,
                      child: const Text('Request account deletion'),
                    ),
            ),
            Center(
              child: Text(
                'Hydro Sense ${AppConfig.appVersion}',
                style: AppText.note,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The display switch is local and never waits for a save.
  bool toggleIsDisplay(String title) => title == 'Solid glass';

  void _dialog(Widget d) =>
      showDialog<void>(context: context, builder: (_) => d);
}

/// Shared error line for the account dialogs.
/// A dialog button's text, with a small spinner and "Saving…" while a call
/// runs: a cold Cloud Function can take a few seconds to answer.
Widget _buttonLabel(String label, bool busy) => busy
    ? const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('Saving…'),
        ],
      )
    : Text(label);

Widget _errorLine(String? error) => error == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: AppSpace.m),
        child: Text(
          error,
          style: AppText.body.copyWith(
            color: AppColors.errorText,
            fontSize: 14,
          ),
        ),
      );

String accountError(Object e) {
  final code = callableDetails(e).code;
  if (code == 'PHONE_IN_USE') return Messages.phoneInUse;
  if (code == 'NAME_INVALID') return "Enter your name (at most 60 characters).";
  final auth = authMessage(e);
  if (auth == Messages.wrongCredentials) return Messages.wrongPassword;
  return auth == Messages.generic ? callableMessage(e) : auth;
}

class _NameDialog extends ConsumerStatefulWidget {
  const _NameDialog({required this.current});

  final String current;

  @override
  ConsumerState<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends ConsumerState<_NameDialog> {
  late final _c = TextEditingController(text: widget.current);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_c.text.trim().isEmpty) {
      setState(() => _error = Messages.nameEmpty);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(accountRepositoryProvider).updateMyName(_c.text.trim());
      if (mounted) {
        Navigator.pop(context);
        showToast(context, 'Name saved');
      }
    } catch (e) {
      if (mounted) setState(() => _error = accountError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Change name'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _c,
          autofocus: true,
          enabled: !_busy,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) => _save(),
        ),
        _errorLine(_error),
      ],
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: _buttonLabel('Save', _busy),
      ),
    ],
  );
}

class _EmailDialog extends ConsumerStatefulWidget {
  const _EmailDialog();

  @override
  ConsumerState<_EmailDialog> createState() => _EmailDialogState();
}

class _EmailDialogState extends ConsumerState<_EmailDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _sentTo;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim().toLowerCase();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(accountRepositoryProvider)
          .changeEmail(_password.text, email);
      if (mounted) setState(() => _sentTo = email);
    } catch (e) {
      if (mounted) setState(() => _error = accountError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sentTo != null) {
      return AlertDialog(
        title: const Text('Check your inbox'),
        content: Text(
          'We sent a link to $_sentTo. Your email changes after you open it.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: const Text('Change email'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _email,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'New email'),
            ),
            const SizedBox(height: AppSpace.m),
            PasswordField(
              controller: _password,
              label: 'Current password',
              enabled: !_busy,
              onSubmitted: (_) => _send(),
            ),
            _errorLine(_error),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _send,
          child: _buttonLabel('Send verification link', _busy),
        ),
      ],
    );
  }
}

class ChangePasswordDialog extends ConsumerStatefulWidget {
  const ChangePasswordDialog({super.key});

  @override
  ConsumerState<ChangePasswordDialog> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends ConsumerState<ChangePasswordDialog> {
  final _current = TextEditingController();
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
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
          .read(accountRepositoryProvider)
          .changePassword(_current.text, _a.text);
      if (mounted) {
        Navigator.pop(context);
        showToast(
          context,
          'Password changed. You were signed out on your other phones.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = accountError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Change password'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PasswordField(
            controller: _current,
            label: 'Current password',
            enabled: !_busy,
          ),
          const SizedBox(height: AppSpace.m),
          PasswordField(
            controller: _a,
            label: 'New password',
            enabled: !_busy,
            showTips: true,
          ),
          const SizedBox(height: AppSpace.m),
          PasswordField(
            controller: _b,
            label: 'Type it again',
            enabled: !_busy,
          ),
          _errorLine(_error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: _buttonLabel('Save', _busy),
      ),
    ],
  );
}
