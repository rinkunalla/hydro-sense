import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/password_field.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/account_repository.dart';
import '../../data/providers.dart';
import '../auth/password_rules.dart';

/// Account.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileProvider).valueOrNull;
    final solid = ref.watch(solidGlassProvider);
    final name = p?.displayName ?? '';
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();

    // Read only (D64): the admin changes staff details and passwords.
    Widget row(String label, String value) => Padding(
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
        ],
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
                      ).copyWith(color: AppColors.onActionTint),
                    ),
                  ),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: AppText.title(20)),
                        Text('Staff', style: AppText.note),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.m),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  row('Username', p?.username ?? '-'),
                  row(
                    'Mobile number',
                    p?.phone == null ? 'None' : displayPhone(p?.phone),
                  ),
                  row('Email', p?.email ?? 'None'),
                  const SizedBox(height: AppSpace.s),
                  Text(
                    'Alerts reach you on this phone and on the mobile number and email above. Ask your admin to change your details or password.',
                    style: AppText.note,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.l),
            const SectionLabel('Display'),
            GlassPanel(
              child: MergeSemantics(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Solid glass', style: AppText.strong),
                  subtitle: Text(
                    'Easier to read: no see-through panels',
                    style: AppText.note,
                  ),
                  value: solid,
                  activeThumbColor: Colors.white,
                  activeTrackColor: AppColors.action,
                  onChanged: (v) =>
                      ref.read(solidGlassProvider.notifier).set(v),
                ),
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
