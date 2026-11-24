import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/password_field.dart';
import '../../core/theme.dart';
import '../../data/account_repository.dart';
import '../auth/password_rules.dart';

/// The admin's own password change on Account (D40): the current password,
/// then the new one twice. Firebase ends the admin's other sessions.
/// Staff never change their own password; the admin sets it (D64).
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
          'Password changed. Your other sessions were signed out.',
        );
      }
    } catch (e) {
      if (mounted) {
        final m = authMessage(e);
        setState(
          () => _error = m == Messages.wrongCredentials
              ? Messages.wrongPassword
              : m,
        );
      }
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
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.m),
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
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: _busy
            ? const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  // A cold Cloud Function can take a few seconds to answer.
                  Text('Saving…'),
                ],
              )
            : const Text('Save'),
      ),
    ],
  );
}
