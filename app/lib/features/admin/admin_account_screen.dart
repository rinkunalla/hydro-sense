import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/password_field.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/account_repository.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import '../../data/providers.dart';
import 'admin_widgets.dart';
import 'change_password_dialog.dart';

/// Account: my profile (with the mobile for SMS alerts, D65) and security on
/// the left, the admins on the right.
class AdminAccountScreen extends ConsumerWidget {
  const AdminAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide =
        MediaQuery.sizeOf(context).width >= AppConfig.adminRailBreakpoint;
    const left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Profile(),
        SizedBox(height: AppSpace.l),
        _Security(),
      ],
    );
    const right = _Admins();
    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
        const AdminPageHeader(title: 'Account'),
        if (wide)
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              SizedBox(width: AppSpace.l),
              Expanded(child: right),
            ],
          )
        else ...const [left, SizedBox(height: AppSpace.l), right],
      ],
    );
  }
}

AdminInfo? _me(WidgetRef ref) => ref
    .watch(adminsProvider)
    .valueOrNull
    ?.admins
    .where((a) => a.you)
    .firstOrNull;

class _Profile extends ConsumerStatefulWidget {
  const _Profile();

  @override
  ConsumerState<_Profile> createState() => _ProfileState();
}

class _ProfileState extends ConsumerState<_Profile> {
  final _name = TextEditingController();
  final _mobile = TextEditingController();
  final _newEmail = TextEditingController();
  final _password = TextEditingController();
  bool _nameLoaded = false;
  bool _emailOpen = false;
  bool _busy = false;
  String? _emailError;
  String? _emailSent;

  @override
  void dispose() {
    _name.dispose();
    _mobile.dispose();
    _newEmail.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showToast(context, Messages.nameEmpty);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).updateMyAdminName(name);
      ref.invalidate(adminsProvider);
      if (mounted) showToast(context, 'Name saved');
    } catch (e) {
      if (mounted) showToast(context, adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The admin's own number for SMS alerts; empty removes it (D65).
  Future<void> _saveMobile() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateMyAdminMobile(_mobile.text.trim());
      ref.invalidate(adminsProvider);
      if (mounted) {
        showToast(
          context,
          _mobile.text.trim().isEmpty
              ? 'Mobile removed. Alerts reach you by email only.'
              : 'Mobile saved. SMS alerts go to this number.',
        );
      }
    } catch (e) {
      if (mounted) showToast(context, adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeEmail(String oldEmail) async {
    final email = _newEmail.text.trim();
    if (!email.contains('@')) {
      setState(() => _emailError = 'Enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _emailError = null;
    });
    try {
      await ref
          .read(accountRepositoryProvider)
          .changeEmail(_password.text, email);
      if (!mounted) return;
      setState(() {
        _emailOpen = false;
        _emailSent =
            'We sent a link to $email. Your email changes after you open it. '
            'Until then, sign in with $oldEmail.';
      });
      _password.clear();
    } catch (e) {
      if (!mounted) return;
      final m = authMessage(e);
      setState(
        () => _emailError = m == Messages.wrongCredentials
            ? 'That password is not right.'
            : m,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = _me(ref);
    final user = ref.watch(userProvider).valueOrNull;
    final email = user?.email ?? me?.email ?? '';
    final name = me?.name ?? user?.displayName ?? '';
    if (!_nameLoaded && me != null) {
      _nameLoaded = true;
      _name.text = name;
      _mobile.text = me.phone == null ? '' : displayPhone(me.phone);
    }
    return AdminCard(
      title: 'My profile',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(name.isEmpty ? email : name, size: 52),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.isEmpty ? email : name, style: AppText.strong),
                    Text(email, style: AppText.note),
                    if (me?.activatedAt != null)
                      Text(
                        'Admin since ${dayMonthYear(me!.activatedAt!)}',
                        style: AppText.note,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.l),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  enabled: !_busy,
                  maxLength: AppConfig.userNameMax,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    counterText: '',
                  ),
                  onSubmitted: (_) => _saveName(),
                ),
              ),
              const SizedBox(width: AppSpace.s),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SecondaryButton(
                  label: 'Save',
                  onPressed: _busy ? null : _saveName,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.s),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _mobile,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Mobile number for SMS alerts',
                    helperText: 'Empty: alerts by email only',
                  ),
                  onSubmitted: (_) => _saveMobile(),
                ),
              ),
              const SizedBox(width: AppSpace.s),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SecondaryButton(
                  label: 'Save',
                  onPressed: _busy ? null : _saveMobile,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.l),
          Text('Email', style: AppText.note),
          Row(
            children: [
              Expanded(child: Text(email, style: AppText.body)),
              if (!_emailOpen)
                SecondaryButton(
                  label: 'Change email',
                  onPressed: () => setState(() {
                    _emailOpen = true;
                    _emailSent = null;
                  }),
                ),
            ],
          ),
          if (_emailSent != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.s),
              child: Text(_emailSent!, style: AppText.note),
            ),
          if (_emailOpen) ...[
            const SizedBox(height: AppSpace.m),
            TextField(
              controller: _newEmail,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'New email'),
            ),
            const SizedBox(height: AppSpace.m),
            PasswordField(
              controller: _password,
              label: 'Current password',
              enabled: !_busy,
              onSubmitted: (_) => _changeEmail(email),
            ),
            ErrorLine(_emailError),
            const SizedBox(height: AppSpace.m),
            Wrap(
              spacing: AppSpace.s,
              children: [
                PrimaryButton(
                  label: 'Send verification link',
                  busy: _busy,
                  onPressed: () => _changeEmail(email),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _emailOpen = false;
                          _emailError = null;
                        }),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.l),
          Text('Password', style: AppText.note),
          Row(
            children: [
              Expanded(child: Text('••••••••', style: AppText.body)),
              SecondaryButton(
                label: 'Change password',
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const ChangePasswordDialog(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Security extends ConsumerWidget {
  const _Security();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = _me(ref);
    final now = DateTime.now();
    return AdminCard(
      title: 'Security',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            me?.lastSignIn == null
                ? 'Last sign-in: not known yet'
                : 'Last sign-in: ${clockTime(me!.lastSignIn!, now)}',
            style: AppText.body,
          ),
          const SizedBox(height: AppSpace.m),
          Wrap(
            spacing: AppSpace.s,
            runSpacing: AppSpace.s,
            children: [
              SecondaryButton(
                label: 'Sign out everywhere',
                icon: Icons.devices_other_rounded,
                onPressed: () async {
                  final ok = await confirmAction(
                    context,
                    title: 'Sign out everywhere?',
                    message:
                        'Sign out on every computer and phone, including this one?',
                    buttonLabel: 'Sign out everywhere',
                  );
                  if (!ok) return;
                  try {
                    await ref.read(adminRepositoryProvider).signOutEverywhere();
                  } catch (_) {}
                  await signOut(ref);
                },
              ),
              SecondaryButton(
                label: 'Sign out',
                icon: Icons.logout_rounded,
                destructive: true,
                onPressed: () => signOut(ref),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Admins extends ConsumerStatefulWidget {
  const _Admins();

  @override
  ConsumerState<_Admins> createState() => _AdminsState();
}

/// The website's admins, with Remove for the others. There are no invites
/// (2026-11-25): a new admin is added with tools/seed-admins.ts.
class _AdminsState extends ConsumerState<_Admins> {
  bool _busy = false;
  String? _error;

  Future<void> _act(Future<void> Function() f, String done) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
      ref.invalidate(adminsProvider);
      if (mounted) showToast(context, done);
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusOf(AdminInfo a, DateTime now) {
    if (a.you) return 'You';
    if (a.invited) return 'Setup not finished';
    return a.lastSignIn == null
        ? 'Active'
        : 'Active · last sign-in ${clockTime(a.lastSignIn!, now)}';
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(adminsProvider);
    final repo = ref.read(adminRepositoryProvider);
    final now = DateTime.now();
    return AdminCard(
      title: 'Admins',
      child: data.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorLine(adminErrorText(e)),
        data: (d) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final a in d.admins)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
                child: Row(
                  children: [
                    Avatar(a.display, size: 36),
                    const SizedBox(width: AppSpace.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.display, style: AppText.strong),
                          Text(a.email, style: AppText.note),
                          Text(_statusOf(a, now), style: AppText.note),
                        ],
                      ),
                    ),
                    if (!a.you && !a.invited)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                final ok = await confirmAction(
                                  context,
                                  title: 'Remove ${a.display}?',
                                  message:
                                      "Remove ${a.display} as an admin? They can't "
                                      'sign in to the admin website any more.',
                                  buttonLabel: 'Remove',
                                  destructive: true,
                                );
                                if (ok) {
                                  await _act(
                                    () => repo.removeAdmin(a.uid),
                                    '${a.display} is no longer an admin.',
                                  );
                                }
                              },
                        child: const Text('Remove'),
                      ),
                  ],
                ),
              ),
            ErrorLine(_error),
          ],
        ),
      ),
    );
  }
}
