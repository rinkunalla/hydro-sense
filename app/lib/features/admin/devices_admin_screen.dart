import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import 'activity_screen.dart' show TargetActivity;
import 'admin_widgets.dart';

enum _Filter { all, unassigned, offline, notSetUp, removed }

/// Devices (docs/UI_UX_SPEC.md 6.2): connection status only (D24), from
/// adminListDevices, refreshed every ADMIN_DEVICES_REFRESH_S.
class DevicesAdminScreen extends ConsumerStatefulWidget {
  const DevicesAdminScreen({super.key});

  @override
  ConsumerState<DevicesAdminScreen> createState() => _DevicesAdminScreenState();
}

class _DevicesAdminScreenState extends ConsumerState<DevicesAdminScreen> {
  _Filter _filter = _Filter.all;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// null = the default order (Offline longest silent first, then Not set up
  /// yet, then Online); otherwise a column index.
  int? _sortColumn;
  bool _ascending = true;

  void _refresh() {
    ref.invalidate(adminDevicesProvider);
    ref.invalidate(adminUsersProvider);
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) showToast(context, done);
      _refresh();
    } catch (e) {
      if (mounted) showToast(context, adminErrorText(e));
    }
  }

  Future<void> _add() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => const AddDeviceDialog(),
    );
    if (added == true) _refresh();
  }

  Future<void> _assign(AdminDevice d) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => AssignDialog(device: d),
    );
    if (changed == true) _refresh();
  }

  Future<void> _open(AdminDevice d) async {
    final changed = await showSidePanel<bool>(
      context,
      title: d.display,
      builder: (_) => DevicePanel(device: d),
    );
    if (changed == true) _refresh();
  }

  List<AdminDevice> _sorted(List<AdminDevice> rows) {
    final list = [...rows];
    final col = _sortColumn;
    if (col == null) {
      int rank(AdminDevice d) => switch (stateOf(d)) {
        AdminState.offline => 0,
        AdminState.notSetUp => 1,
        AdminState.online => 2,
        AdminState.removed => 3,
      };
      list.sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        // Longest silent at the top.
        final at = a.lastSeen?.millisecondsSinceEpoch ?? 0;
        final bt = b.lastSeen?.millisecondsSinceEpoch ?? 0;
        return at.compareTo(bt);
      });
      return list;
    }
    list.sort((a, b) {
      final c = sortKey(a, col).compareTo(sortKey(b, col));
      return _ascending ? c : -c;
    });
    return list;
  }

  void _sortBy(int column) => setState(() {
    if (_sortColumn == column) {
      _ascending = !_ascending;
    } else {
      _sortColumn = column;
      _ascending = true;
    }
  });

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(adminDevicesProvider);
    final wide =
        MediaQuery.sizeOf(context).width >= AppConfig.adminRailBreakpoint;
    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
        AdminPageHeader(
          title: 'Devices',
          actions: [
            SecondaryButton(
              label: 'Refresh',
              icon: Icons.refresh_rounded,
              onPressed: _refresh,
            ),
            PrimaryButton(
              label: 'Add device',
              icon: Icons.add_rounded,
              onPressed: _add,
            ),
          ],
        ),
        devices.when(
          loading: () => const SkeletonCard(height: 240),
          error: (e, _) => AppBanner(
            icon: Icons.error_outline_rounded,
            color: AppColors.danger,
            text: "Can't load the devices. ${adminErrorText(e)}",
          ),
          data: (all) {
            final found = all
                .where((d) => deviceMatches(d, _search.text))
                .toList();
            final live = found.where((d) => !d.removed).toList();
            final unassigned = live.where((d) => d.ownerUid == null).toList();
            final offline = live
                .where((d) => stateOf(d) == AdminState.offline)
                .toList();
            final notSetUp = live
                .where((d) => stateOf(d) == AdminState.notSetUp)
                .toList();
            final removed = found.where((d) => d.removed).toList();
            if (_filter == _Filter.removed && removed.isEmpty) {
              _filter = _Filter.all;
            }
            final shown = _sorted(switch (_filter) {
              _Filter.all => live,
              _Filter.unassigned => unassigned,
              _Filter.offline => offline,
              _Filter.notSetUp => notSetUp,
              _Filter.removed => removed,
            });
            Widget pill(_Filter f, String label, int n) => FilterPill(
              label: '$label $n',
              selected: _filter == f,
              onTap: () => setState(() => _filter = f),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Search by ID, label or owner',
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
                    pill(_Filter.all, 'All', live.length),
                    pill(_Filter.unassigned, 'Unassigned', unassigned.length),
                    pill(_Filter.offline, 'Offline', offline.length),
                    if (notSetUp.isNotEmpty)
                      pill(_Filter.notSetUp, 'Not set up yet', notSetUp.length),
                    if (removed.isNotEmpty)
                      pill(_Filter.removed, 'Removed', removed.length),
                  ],
                ),
                const SizedBox(height: AppSpace.m),
                GlassPanel(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
                  child: shown.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(AppSpace.l),
                          child: Text(
                            all.isEmpty
                                ? 'No devices yet. Add the first one.'
                                : _search.text.isNotEmpty
                                ? 'No devices match.'
                                : 'No devices here.',
                            style: AppText.body,
                          ),
                        )
                      : Column(
                          children: [
                            if (wide)
                              _Header(
                                sortColumn: _sortColumn,
                                ascending: _ascending,
                                onSort: _sortBy,
                              ),
                            for (final (i, d) in shown.indexed) ...[
                              if (i > 0 || wide)
                                const Divider(height: 1, thickness: 0.5),
                              _DeviceRow(
                                device: d,
                                wide: wide,
                                now: now,
                                onOpen: d.removed ? null : () => _open(d),
                                onAssign: () => _assign(d),
                                onRestore: () => _run(
                                  () => ref
                                      .read(adminRepositoryProvider)
                                      .restoreDevice(d.id),
                                  '${d.display} is restored. It reconnects on its next try (within an hour).',
                                ),
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

/// The status words for one device ("Offline · since 6:10 AM").
String? _detail(AdminDevice d, DateTime now) => switch (stateOf(d)) {
  AdminState.offline when d.lastSeen != null =>
    'since ${clockTime(d.lastSeen!, now)}',
  AdminState.removed when d.purgeAfter != null =>
    'deletes ${dayMonth(d.purgeAfter!)}',
  _ => null,
};

class _Header extends StatelessWidget {
  const _Header({
    required this.sortColumn,
    required this.ascending,
    required this.onSort,
  });

  final int? sortColumn;
  final bool ascending;
  final ValueChanged<int> onSort;

  @override
  Widget build(BuildContext context) {
    // Column indexes match admin_logic.sortKey: 0 ID, 1 label, 2 owner, 3 status.
    Widget h(String t, int column, int flex) => Expanded(
      flex: flex,
      child: Semantics(
        button: true,
        label: 'Sort by $t',
        child: InkWell(
          onTap: () => onSort(column),
          child: Row(
            children: [
              Flexible(child: Text(t.toUpperCase(), style: AppText.label)),
              if (sortColumn == column)
                Icon(
                  ascending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 14,
                  color: AppColors.steel,
                ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.s, 0, AppSpace.s),
      child: Row(
        children: [
          h('Label', 1, 3),
          h('Device ID', 0, 3),
          h('Assigned to', 2, 3),
          h('Status', 3, 4),
          const SizedBox(width: 100),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.wide,
    required this.now,
    required this.onOpen,
    required this.onAssign,
    required this.onRestore,
  });

  final AdminDevice device;
  final bool wide;
  final DateTime now;
  final VoidCallback? onOpen;
  final VoidCallback onAssign;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final d = device;
    final label = Text(
      d.label ?? 'No label',
      style: d.label == null
          ? AppText.body.copyWith(color: AppColors.steel)
          : AppText.strong,
      overflow: TextOverflow.ellipsis,
    );
    final id = SelectableText(
      d.id,
      style: AppText.body.copyWith(fontFamily: 'monospace', fontSize: 14),
    );
    final owner = Text(
      d.ownerName ?? 'Unassigned',
      style: d.ownerName == null
          ? AppText.body.copyWith(color: AppColors.steel)
          : AppText.body,
      overflow: TextOverflow.ellipsis,
    );
    final status = StateBadge(stateOf(d), detail: _detail(d, now));
    final Widget trailing = d.removed
        ? TextButton(onPressed: onRestore, child: const Text('Restore'))
        : d.ownerUid == null
        ? TextButton(onPressed: onAssign, child: const Text('Assign'))
        : const Icon(Icons.chevron_right_rounded, color: AppColors.steel);

    final content = wide
        ? Row(
            children: [
              Expanded(flex: 3, child: label),
              Expanded(flex: 3, child: id),
              Expanded(flex: 3, child: owner),
              Expanded(flex: 4, child: status),
              SizedBox(
                width: 100,
                child: Align(alignment: Alignment.centerRight, child: trailing),
              ),
            ],
          )
        : Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [label, id, owner, status],
                ),
              ),
              trailing,
            ],
          );
    return Semantics(
      button: onOpen != null,
      label: onOpen == null ? null : 'Open ${d.display}',
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.l,
            vertical: AppSpace.m,
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Add device with the install checklist (D41).
class AddDeviceDialog extends ConsumerStatefulWidget {
  const AddDeviceDialog({super.key});

  @override
  ConsumerState<AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends ConsumerState<AddDeviceDialog> {
  final _id = TextEditingController();
  final _label = TextEditingController();
  bool _busy = false;
  String? _error;

  static const _steps = [
    'Flash the firmware; the serial log shows the ID.',
    'Add the ID here.',
    'Optional: bench-test it while it is unassigned.',
    'Hold BOOT for 5 seconds to clear the test Wi-Fi.',
    'Put the ID sticker on the device.',
    'Assign it to the buyer.',
  ];

  @override
  void dispose() {
    _id.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final id = normalizeDeviceId(_id.text);
    if (id == null) {
      setState(
        () => _error =
            'Enter the 12-character ID shown on the device label or setup page.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(adminRepositoryProvider)
          .addAllowedDevice(id, label: _label.text);
      if (!mounted) return;
      showToast(context, 'Added. Assign it to the buyer before delivery.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add device'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _id,
              autofocus: true,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Device ID',
                hintText: 'A4F00F6936B0',
              ),
            ),
            const SizedBox(height: AppSpace.m),
            TextField(
              controller: _label,
              enabled: !_busy,
              maxLength: AppConfig.labelMax,
              decoration: const InputDecoration(
                labelText: 'Label (optional, only admins see this)',
                hintText: 'Unit 1',
                counterText: '',
              ),
              onSubmitted: (_) => _save(),
            ),
            ErrorLine(_error),
            const SizedBox(height: AppSpace.l),
            Text('INSTALL CHECKLIST', style: AppText.label),
            const SizedBox(height: AppSpace.s),
            for (final (i, s) in _steps.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${i + 1}. $s', style: AppText.note),
              ),
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
        child: const Text('Add device'),
      ),
    ],
  );
}

/// Assign (unassigned device) or Reassign (owned device). Moving a device
/// from one user to another deletes its history (D20), so that is confirmed by
/// typing the label (D42).
class AssignDialog extends ConsumerStatefulWidget {
  const AssignDialog({super.key, required this.device});

  final AdminDevice device;

  @override
  ConsumerState<AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends ConsumerState<AssignDialog> {
  late final _label = TextEditingController(text: widget.device.label);
  String? _uid;
  bool _unassign = false;
  bool _busy = false;
  String? _error;

  bool get _reassign => widget.device.ownerUid != null;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final d = widget.device;
    final target = _unassign ? null : _uid;
    if (!_unassign && target == null) {
      setState(() => _error = 'Choose who gets it.');
      return;
    }
    if (_reassign) {
      final ok = await confirmByTyping(
        context,
        title: _unassign ? 'Unassign ${d.display}?' : 'Reassign ${d.display}?',
        message:
            'Its history is deleted first: readings, alerts, nickname, pin and '
            'flow limits. This cannot be undone.',
        confirmWord: d.confirmText,
        buttonLabel: _unassign ? 'Unassign' : 'Reassign',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(adminRepositoryProvider);
    try {
      final label = _label.text.trim();
      if (label != (d.label ?? '')) {
        await repo.updateDeviceLabel(d.id, label.isEmpty ? null : label);
      }
      await repo.assignDevice(d.id, target);
      if (!mounted) return;
      showToast(
        context,
        target == null
            ? 'Unassigned.'
            : 'Assigned. It appears in their app now.',
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
    final d = widget.device;
    final users = (ref.watch(adminUsersProvider).valueOrNull ?? const [])
        .where((u) => !u.suspended && u.uid != d.ownerUid)
        .toList();
    final chosen = users.where((u) => u.uid == _uid).firstOrNull;
    final first = chosen?.name.split(' ').first ?? 'the user';
    return AlertDialog(
      title: Text('${_reassign ? 'Reassign' : 'Assign'} ${d.display}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _label,
                enabled: !_busy,
                maxLength: AppConfig.labelMax,
                decoration: const InputDecoration(
                  labelText: 'Label (only admins see this)',
                  counterText: '',
                ),
              ),
              const SizedBox(height: AppSpace.m),
              Text('GIVE IT TO', style: AppText.label),
              const SizedBox(height: AppSpace.s),
              if (users.isEmpty && !_reassign)
                Text(
                  'No users yet. Create one on the Users page first.',
                  style: AppText.note,
                ),
              RadioGroup<String>(
                groupValue: _unassign ? '' : _uid,
                onChanged: (v) => setState(() {
                  _unassign = v == '';
                  _uid = v == '' ? null : v;
                }),
                child: Column(
                  children: [
                    for (final u in users)
                      RadioListTile<String>(
                        value: u.uid,
                        contentPadding: EdgeInsets.zero,
                        title: Text(u.name),
                        subtitle: Text(
                          '${u.deviceCount} device${u.deviceCount == 1 ? '' : 's'}',
                        ),
                      ),
                    if (_reassign)
                      const RadioListTile<String>(
                        value: '',
                        contentPadding: EdgeInsets.zero,
                        title: Text('Nobody (unassign)'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.s),
              Text(
                'It appears in $first\'s app right away. When a device moves '
                'from one user to another, its old history is deleted.',
                style: AppText.note,
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
          child: Text(_reassign ? 'Reassign' : 'Assign'),
        ),
      ],
    );
  }
}

/// An assigned device: label, owner, Reassign and Remove (D42).
class DevicePanel extends ConsumerStatefulWidget {
  const DevicePanel({super.key, required this.device});

  final AdminDevice device;

  @override
  ConsumerState<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends ConsumerState<DevicePanel> {
  late final _label = TextEditingController(text: widget.device.label);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _saveLabel() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final l = _label.text.trim();
      await ref
          .read(adminRepositoryProvider)
          .updateDeviceLabel(widget.device.id, l.isEmpty ? null : l);
      if (!mounted) return;
      showToast(context, 'Label saved.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reassign() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => AssignDialog(device: widget.device),
    );
    if (changed == true && mounted) Navigator.pop(context, true);
  }

  Future<void> _remove() async {
    final d = widget.device;
    final ok = await confirmByTyping(
      context,
      title: 'Remove ${d.display}?',
      message:
          'It stops uploading and leaves the owner\'s app. Its data is kept for '
          '${AppConfig.restoreWindowDays} days so you can restore it; after '
          'that it is deleted.',
      confirmWord: d.confirmText,
      buttonLabel: 'Remove',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .removeDevice(d.id, confirmLabel: d.confirmText);
      if (!mounted) return;
      showToast(
        context,
        '${d.display} is removed. You can restore it for 30 days.',
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
    final d = widget.device;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Device ID', style: AppText.note),
        SelectableText(
          d.id,
          style: AppText.strong.copyWith(fontFamily: 'monospace'),
        ),
        const SizedBox(height: AppSpace.m),
        StateBadge(stateOf(d), detail: _detail(d, DateTime.now())),
        const SizedBox(height: AppSpace.l),
        TextField(
          controller: _label,
          enabled: !_busy,
          maxLength: AppConfig.labelMax,
          decoration: const InputDecoration(
            labelText: 'Label (only admins see this)',
            counterText: '',
          ),
          onSubmitted: (_) => _saveLabel(),
        ),
        const SizedBox(height: AppSpace.s),
        Align(
          alignment: Alignment.centerLeft,
          child: SecondaryButton(
            label: 'Save label',
            onPressed: _busy ? null : _saveLabel,
          ),
        ),
        const SizedBox(height: AppSpace.l),
        Text('Assigned to', style: AppText.note),
        Text(d.ownerName ?? 'Unassigned', style: AppText.strong),
        const SizedBox(height: AppSpace.s),
        Text(
          'Reassign it for a wrong buyer, or a resold or replaced device. '
          'Its history is deleted when it moves.',
          style: AppText.note,
        ),
        ErrorLine(_error),
        const SizedBox(height: AppSpace.l),
        PrimaryButton(
          label: d.ownerUid == null ? 'Assign' : 'Reassign',
          onPressed: _busy ? null : _reassign,
        ),
        const SizedBox(height: AppSpace.m),
        SecondaryButton(
          label: 'Remove device',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onPressed: _busy ? null : _remove,
        ),
        const SizedBox(height: AppSpace.xl),
        TargetActivity(targetId: d.id),
      ],
    );
  }
}
