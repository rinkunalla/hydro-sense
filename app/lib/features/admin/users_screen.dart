import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import 'activity_screen.dart' show TargetActivity;
import 'admin_widgets.dart';

/// Users: name, mobile, devices, status. A row opens
/// the side panel; Create user uses the same panel, empty.
class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  UserFilter _filter = UserFilter.all;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(adminUsersProvider);
    ref.invalidate(adminDevicesProvider);
  }

  Future<void> _open(AdminUser? user) async {
    final changed = await showSidePanel<bool>(
      context,
      title: user == null ? 'Create user' : user.name,
      builder: (_) => UserPanel(user: user),
    );
    if (changed == true) _refresh();
  }

  Future<void> _restore(AdminUser u) async {
    try {
      await ref.read(adminRepositoryProvider).restoreUser(u.uid);
      if (mounted) showToast(context, '${u.name} is restored.');
      _refresh();
    } catch (e) {
      if (mounted) showToast(context, adminErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(adminUsersProvider);
    final wide =
        MediaQuery.sizeOf(context).width >= AppConfig.adminRailBreakpoint;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
        AdminPageHeader(
          title: 'Users',
          actions: [
            SecondaryButton(
              label: 'Refresh',
              icon: Icons.refresh_rounded,
              onPressed: _refresh,
            ),
            PrimaryButton(
              label: 'Create user',
              icon: Icons.person_add_alt_1_rounded,
              onPressed: () => _open(null),
            ),
          ],
        ),
        users.when(
          loading: () => const SkeletonCard(height: 240),
          error: (e, _) => AppBanner(
            icon: Icons.error_outline_rounded,
            color: AppColors.danger,
            text: "Can't load the users. ${adminErrorText(e)}",
          ),
          data: (all) {
            int count(UserFilter f) =>
                all.where((u) => userMatches(u, f, '')).length;
            if (_filter != UserFilter.all && count(_filter) == 0) {
              _filter = UserFilter.all;
            }
            final rows = sortUsers(
              all.where((u) => userMatches(u, _filter, _search.text)).toList(),
            );
            const words = {
              UserFilter.all: 'All',
              UserFilter.noPassword: 'Password not set',
              UserFilter.deletionRequested: 'Deletion requested',
              UserFilter.suspended: 'Suspended',
            };
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Search by name, mobile or email',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                ),
                const SizedBox(height: AppSpace.s),
                Wrap(
                  spacing: AppSpace.s,
                  runSpacing: AppSpace.s,
                  children: [
                    for (final f in UserFilter.values)
                      if (f == UserFilter.all || count(f) > 0)
                        FilterPill(
                          label: '${words[f]} ${count(f)}',
                          selected: _filter == f,
                          onTap: () => setState(() => _filter = f),
                        ),
                  ],
                ),
                const SizedBox(height: AppSpace.m),
                GlassPanel(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
                  child: rows.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(AppSpace.l),
                          child: Text(
                            all.isEmpty
                                ? 'No users yet. Create the first one.'
                                : 'No users match.',
                            style: AppText.body,
                          ),
                        )
                      : Column(
                          children: [
                            if (wide) const _HeaderRow(),
                            for (final (i, u) in rows.indexed) ...[
                              if (i > 0 || wide)
                                const Divider(height: 1, thickness: 0.5),
                              _UserRow(
                                user: u,
                                wide: wide,
                                onOpen: () => _open(u),
                                onRestore: () => _restore(u),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    Widget h(String t, int flex) => Expanded(
      flex: flex,
      child: Text(t.toUpperCase(), style: AppText.label),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.l,
        AppSpace.s,
        56,
        AppSpace.s,
      ),
      child: Row(
        children: [
          h('Name', 4),
          h('Mobile number', 3),
          h('Devices', 1),
          h('Status', 3),
        ],
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.wide,
    required this.onOpen,
    required this.onRestore,
  });

  final AdminUser user;
  final bool wide;
  final VoidCallback onOpen;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final u = user;
    final status = u.suspended
        ? Text(
            'Suspended${u.purgeAfter == null ? '' : ' · deletes ${dayMonth(u.purgeAfter!)}'}',
            style: AppText.body.copyWith(fontSize: 14, color: AppColors.steel),
          )
        : Text(
            u.passwordSet ? 'Active' : 'Password not set',
            style: AppText.body.copyWith(fontSize: 14),
          );
    final note = u.deletionRequestedAt == null
        ? null
        : Text(
            'Asked to delete their account · ${dayMonth(u.deletionRequestedAt!)}',
            style: AppText.note.copyWith(color: const Color(0xFF8A5A00)),
          );
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(u.name, style: AppText.strong, overflow: TextOverflow.ellipsis),
        Text(u.email, style: AppText.note, overflow: TextOverflow.ellipsis),
        ?note,
      ],
    );
    final trailing = u.suspended
        ? TextButton(onPressed: onRestore, child: const Text('Restore'))
        : const Icon(Icons.chevron_right_rounded, color: AppColors.steel);

    return Semantics(
      button: true,
      label: 'Open ${u.name}',
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.l,
            vertical: AppSpace.m,
          ),
          child: wide
              ? Row(
                  children: [
                    Expanded(flex: 4, child: name),
                    Expanded(
                      flex: 3,
                      child: Text(displayPhone(u.phone), style: AppText.body),
                    ),
                    Expanded(
                      flex: 1,
                      child: Text('${u.deviceCount}', style: AppText.body),
                    ),
                    Expanded(flex: 3, child: status),
                    SizedBox(
                      width: 88,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: trailing,
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          name,
                          const SizedBox(height: 4),
                          Text(
                            '${displayPhone(u.phone)} · ${u.deviceCount} '
                            'device${u.deviceCount == 1 ? '' : 's'}',
                            style: AppText.note,
                          ),
                          status,
                        ],
                      ),
                    ),
                    trailing,
                  ],
                ),
        ),
      ),
    );
  }
}

/// The side panel: create (user == null) or edit a user, and Delete user.
/// Pops true when something changed.
class UserPanel extends ConsumerStatefulWidget {
  const UserPanel({super.key, this.user});

  final AdminUser? user;

  @override
  ConsumerState<UserPanel> createState() => _UserPanelState();
}

class _UserPanelState extends ConsumerState<UserPanel> {
  late final _name = TextEditingController(text: widget.user?.name);
  late final _mobile = TextEditingController(
    text: widget.user == null ? '' : displayPhone(widget.user!.phone),
  );
  late final _email = TextEditingController(text: widget.user?.email);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _mobile.dispose();
    _email.dispose();
    super.dispose();
  }

  String? _check() {
    if (_name.text.trim().isEmpty) return 'Enter a name.';
    final m = _mobile.text.replaceAll(RegExp(r'[\s-]'), '');
    if (!AppConfig.phMobilePattern.hasMatch(m)) return Messages.phoneHint;
    if (!_email.text.trim().contains('@')) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  Future<void> _save() async {
    final problem = _check();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(adminRepositoryProvider);
    final name = _name.text.trim();
    final email = _email.text.trim();
    final mobile = _mobile.text.trim();
    try {
      final u = widget.user;
      if (u == null) {
        await repo.createUser(name: name, email: email, mobile: mobile);
        if (!mounted) return;
        showToast(
          context,
          "User created. Ask them to open the app and tap 'Forgot password?' to set their password.",
        );
      } else {
        await repo.updateUser(
          u.uid,
          name: name == u.name ? null : name,
          email: email == u.email ? null : email,
          mobile: mobile == displayPhone(u.phone) ? null : mobile,
        );
        if (!mounted) return;
        showToast(context, 'Changes saved.');
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final u = widget.user!;
    final ok = await confirmByTyping(
      context,
      title: 'Delete ${u.name}?',
      message:
          "They can't sign in and get no alerts. You can restore the account "
          'for ${AppConfig.restoreWindowDays} days; after that their devices '
          'are unassigned and all history is deleted.',
      confirmWord: u.name,
      buttonLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .deleteUser(u.uid, confirmName: u.name);
      if (!mounted) return;
      showToast(
        context,
        '${u.name} is deleted. You can restore them for 30 days.',
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    final devices = ref.watch(adminDevicesProvider).valueOrNull ?? const [];
    final mine = [
      for (final d in devices)
        if (u != null && d.ownerUid == u.uid && !d.removed) d.display,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (u != null) ...[
          Row(
            children: [
              Avatar(u.name, size: 48),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.name, style: AppText.strong),
                    if (u.createdAt != null)
                      Text(
                        'Created ${dayMonthYear(u.createdAt!)}',
                        style: AppText.note,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.l),
        ],
        TextField(
          controller: _name,
          enabled: !_busy,
          maxLength: AppConfig.userNameMax,
          decoration: const InputDecoration(labelText: 'Name', counterText: ''),
        ),
        const SizedBox(height: AppSpace.m),
        TextField(
          controller: _mobile,
          enabled: !_busy,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Mobile number',
            hintText: '0917 123 4567',
          ),
        ),
        const SizedBox(height: AppSpace.m),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email'),
          onSubmitted: (_) => _save(),
        ),
        if (u != null) ...[
          const SizedBox(height: AppSpace.m),
          Text(
            mine.isEmpty ? 'Devices: none yet' : 'Devices: ${mine.join(', ')}',
            style: AppText.body.copyWith(fontSize: 14),
          ),
        ],
        ErrorLine(_error),
        const SizedBox(height: AppSpace.l),
        PrimaryButton(
          label: u == null ? 'Create user' : 'Save changes',
          busy: _busy,
          onPressed: u?.suspended == true ? null : _save,
        ),
        if (u != null && !u.suspended) ...[
          const SizedBox(height: AppSpace.m),
          SecondaryButton(
            label: 'Delete user',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onPressed: _busy ? null : _delete,
          ),
        ],
        if (u != null) ...[
          const SizedBox(height: AppSpace.xl),
          TargetActivity(targetId: u.uid),
        ],
      ],
    );
  }
}
