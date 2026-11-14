import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import '../../data/providers.dart' show clockProvider;
import 'admin_widgets.dart';

// Stage 2 keeps this page working on the v2 data (adminListDevices, D24);
// stage 6 rebuilds it with filters, assignment and the device panel.

const addDeviceError =
    'Enter the 12-character ID shown on the device label or setup page.';

class DevicesAdminScreen extends ConsumerStatefulWidget {
  const DevicesAdminScreen({super.key});

  @override
  ConsumerState<DevicesAdminScreen> createState() => _DevicesAdminScreenState();
}

class _DevicesAdminScreenState extends ConsumerState<DevicesAdminScreen> {
  int _sortColumn = 0;
  bool _ascending = true;

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      ref.invalidate(adminDevicesProvider);
      _snack(done);
    } catch (e) {
      final code = callableDetails(e).code;
      _snack(code == 'DEVICE_ID_INVALID' ? addDeviceError : callableMessage(e));
    }
  }

  Future<void> _addDevice() async {
    final r = await showDialog<({String id, String label})>(
      context: context,
      builder: (_) => const _AddDeviceDialog(),
    );
    if (r == null || !mounted) return;
    await _run(
      () => ref
          .read(adminRepositoryProvider)
          .addAllowedDevice(r.id, label: r.label),
      '${r.id} added. It shows as "Not set up yet" until it connects.',
    );
  }

  Future<void> _remove(AdminDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => TypedConfirmDialog(
        title: 'Remove device?',
        body:
            'Device ${d.id} stops uploading at once. Its data is kept for 30 days, '
            'and any admin can restore it until then.',
        expected: d.confirmText,
        action: 'Remove',
      ),
    );
    if (ok != true || !mounted) return;
    await _run(
      () => ref
          .read(adminRepositoryProvider)
          .removeDevice(d.id, confirmLabel: d.confirmText),
      '${d.id} removed. You can restore it for 30 days.',
    );
  }

  Future<void> _restore(AdminDevice d) => _run(
    () => ref.read(adminRepositoryProvider).restoreDevice(d.id),
    '${d.id} restored. It reconnects within about an hour.',
  );

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(adminDevicesProvider);
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();

    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: [
        SectionCard(
          title: 'Devices',
          action: FilledButton.icon(
            onPressed: _addDevice,
            icon: const Icon(Icons.add),
            label: const Text('Add device'),
          ),
          child: rows.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => const Text(Messages.generic),
            data: (list) {
              if (list.isEmpty) return const Text('No devices added yet.');
              final sorted = [...list]
                ..sort((a, b) {
                  final r = sortKey(
                    a,
                    _sortColumn,
                  ).compareTo(sortKey(b, _sortColumn));
                  return _ascending ? r : -r;
                });
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _table(sorted, now),
              );
            },
          ),
        ),
      ],
    );
  }

  DataTable _table(List<AdminDevice> rows, DateTime now) {
    DataColumn col(String label) => DataColumn(
      label: Text(label),
      onSort: (i, asc) => setState(() {
        _sortColumn = i;
        _ascending = asc;
      }),
    );
    return DataTable(
      sortColumnIndex: _sortColumn,
      columnSpacing: 24,
      horizontalMargin: 16,
      sortAscending: _ascending,
      headingRowColor: const WidgetStatePropertyAll(AppColors.surfaceAlt),
      columns: [
        col('Hardware ID'),
        col('Label'),
        col('Owner'),
        col('Status'),
        const DataColumn(label: Text('Actions')),
      ],
      rows: [
        for (final d in rows)
          DataRow(
            cells: [
              DataCell(
                Text(d.id, style: const TextStyle(fontFamily: 'monospace')),
              ),
              DataCell(Text(d.label ?? '-')),
              DataCell(Text(d.ownerName ?? 'Unassigned')),
              DataCell(StateBadge(stateOf(d), detail: _detail(d, now))),
              DataCell(
                d.removed
                    ? TextButton(
                        onPressed: () => _restore(d),
                        child: const Text('Restore'),
                      )
                    : IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _remove(d),
                      ),
              ),
            ],
          ),
      ],
    );
  }

  /// "since 3:42 PM" for Offline (D34); the purge date for Removed (D42).
  String? _detail(AdminDevice d, DateTime now) => switch (stateOf(d)) {
    AdminState.offline when d.lastSeen != null =>
      'since ${clockTime(d.lastSeen!, now)}',
    AdminState.removed when d.purgeAfter != null =>
      '· deleted ${clockTime(d.purgeAfter!, now)}',
    _ => null,
  };
}

/// Destructive confirmation: the admin types the name or label (D42).
class TypedConfirmDialog extends StatefulWidget {
  const TypedConfirmDialog({
    super.key,
    required this.title,
    required this.body,
    required this.expected,
    required this.action,
  });

  final String title;
  final String body;
  final String expected;
  final String action;

  @override
  State<TypedConfirmDialog> createState() => _TypedConfirmDialogState();
}

class _TypedConfirmDialogState extends State<TypedConfirmDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // Same rule as the server: case and spacing do not matter (lib/userInput.ts).
  String _norm(String s) =>
      s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  @override
  Widget build(BuildContext context) {
    final ok = _norm(_c.text) == _norm(widget.expected);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.body),
            const SizedBox(height: AppSpace.m),
            Text('Type "${widget.expected}" to confirm.'),
            const SizedBox(height: AppSpace.s),
            TextField(
              controller: _c,
              autofocus: true,
              onChanged: (_) => setState(() {}),
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
          onPressed: ok ? () => Navigator.pop(context, true) : null,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

class _AddDeviceDialog extends StatefulWidget {
  const _AddDeviceDialog();

  @override
  State<_AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<_AddDeviceDialog> {
  final _id = TextEditingController();
  final _label = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _label.dispose();
    super.dispose();
  }

  void _submit() {
    final id = normalizeDeviceId(_id.text);
    if (id == null) {
      setState(() => _error = addDeviceError);
      return;
    }
    Navigator.pop(context, (id: id, label: _label.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add device'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _id,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Device ID',
              hintText: 'A1B2C3D4E5F6',
              errorText: _error,
              errorMaxLines: 2,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AppSpace.m),
          TextField(
            controller: _label,
            maxLength: 24,
            decoration: const InputDecoration(
              labelText: 'Label (optional)',
              hintText: 'Unit 1',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Add')),
    ],
  );
}
