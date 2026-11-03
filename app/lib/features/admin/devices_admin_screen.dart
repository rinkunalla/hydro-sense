import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import '../../data/providers.dart' show clockProvider;
import 'admin_widgets.dart';
import 'battery_chart.dart';

const addDeviceError =
    'Enter the 12-character ID shown on the device label or setup page.';
const allowedAgainMessage =
    'Allowed. The device reconnects within about an hour.';

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

  Future<void> _addDevice() async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => const _AddDeviceDialog(),
    );
    if (id == null || !mounted) return;
    try {
      await ref.read(adminRepositoryProvider).addAllowedDevice(id);
      _snack(
        '$id added. It appears as "Waiting to register" until it connects.',
      );
    } catch (e) {
      final code = callableDetails(e).code;
      _snack(
        code == 'DEVICE_REMOVED'
            ? 'This device was removed. Use Allow again in the Removed list.'
            : code == 'DEVICE_ID_INVALID'
            ? addDeviceError
            : callableMessage(e),
      );
    }
  }

  Future<void> _remove(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove device?'),
        content: Text(
          'Remove device $id? Its data is deleted and it cannot register again until you choose Allow again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(adminRepositoryProvider).removeDevice(id);
      _snack('$id removed.');
    } catch (e) {
      _snack(callableMessage(e));
    }
  }

  Future<void> _allow(String id) async {
    try {
      await ref.read(adminRepositoryProvider).allowDevice(id);
      _snack(allowedAgainMessage);
    } catch (e) {
      _snack(callableMessage(e));
    }
  }

  void _history(String id) => showDialog<void>(
    context: context,
    builder: (_) => BatteryHistoryDialog(deviceId: id),
  );

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(adminRowsProvider);
    final removed =
        ref.watch(removedProvider).valueOrNull ?? const <RemovedEntry>[];
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
              if (list.isEmpty) {
                return const Text('No devices have registered yet.');
              }
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
        const SizedBox(height: AppSpace.l),
        SectionCard(
          title: 'Removed',
          child: removed.isEmpty
              ? const Text('No removed devices.')
              : Column(
                  children: [
                    for (final r in removed)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.block,
                          color: AppColors.textMuted,
                        ),
                        title: Text(
                          r.id,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: r.removedAt == null
                            ? null
                            : Text('Removed ${clockTime(r.removedAt!, now)}'),
                        trailing: OutlinedButton(
                          onPressed: () => _allow(r.id),
                          child: const Text('Allow again'),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  DataTable _table(List<AdminRow> rows, DateTime now) {
    DataColumn col(String label, {bool numeric = false}) => DataColumn(
      label: Text(label),
      numeric: numeric,
      onSort: (i, asc) => setState(() {
        _sortColumn = i;
        _ascending = asc;
      }),
    );
    return DataTable(
      sortColumnIndex: _sortColumn,
      // Tighter than the 56 px default so all eight columns fit in 1200 px more often.
      columnSpacing: 24,
      horizontalMargin: 16,
      sortAscending: _ascending,
      headingRowColor: const WidgetStatePropertyAll(AppColors.surfaceAlt),
      columns: [
        col('Hardware ID'),
        col('Status'),
        col('Last seen'),
        col('Battery', numeric: true),
        col('Charging'),
        col('Firmware'),
        col('Last error'),
        const DataColumn(label: Text('Actions')),
      ],
      rows: [
        for (final r in rows)
          DataRow(
            color: WidgetStatePropertyAll(
              r.state == AdminState.offline || r.state == AdminState.sleeping
                  ? const Color(0xFFE2E6EA)
                  : null,
            ),
            cells: [
              DataCell(
                Text(r.id, style: const TextStyle(fontFamily: 'monospace')),
              ),
              DataCell(StateBadge(r.state)),
              DataCell(
                Text(
                  r.health?.lastSeen == null
                      ? '-'
                      : clockTime(r.health!.lastSeen!, now),
                ),
              ),
              DataCell(_battery(r)),
              DataCell(Text(r.health?.chargingStatus ?? '-')),
              DataCell(Text(r.health?.firmware ?? '-')),
              DataCell(
                Text(
                  r.lastError == null
                      ? '-'
                      : '${r.lastError!.code}${r.lastError!.ts == null ? '' : ' · ${clockTime(r.lastError!.ts!, now)}'}',
                ),
              ),
              DataCell(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (r.health != null)
                      IconButton(
                        tooltip: 'Battery history',
                        icon: const Icon(Icons.show_chart),
                        onPressed: () => _history(r.id),
                      ),
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _remove(r.id),
                    ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _battery(AdminRow r) {
    final h = r.health;
    if (h == null) return const Text('-');
    if (h.batteryFault) return const Text('Fault (no reading)');
    if (h.batteryVoltage == null) return const Text('-');
    final text = Text(
      '${h.batteryVoltage!.toStringAsFixed(2)} V · ${h.batteryPercent ?? '-'}%',
    );
    return r.lowBattery
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [const LowBatteryBadge(), const SizedBox(width: 8), text],
          )
        : text;
  }
}

class _AddDeviceDialog extends StatefulWidget {
  const _AddDeviceDialog();

  @override
  State<_AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<_AddDeviceDialog> {
  final _c = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final id = normalizeDeviceId(_c.text);
    if (id == null) {
      setState(() => _error = addDeviceError);
      return;
    }
    Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add device'),
    content: SizedBox(
      width: 420,
      child: TextField(
        controller: _c,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Device ID',
          hintText: 'A1B2C3D4E5F6',
          errorText: _error,
          errorMaxLines: 2,
        ),
        onSubmitted: (_) => _submit(),
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

/// 7-day pack voltage for one device, as a chart or a table.
class BatteryHistoryDialog extends ConsumerStatefulWidget {
  const BatteryHistoryDialog({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<BatteryHistoryDialog> createState() =>
      _BatteryHistoryDialogState();
}

class _BatteryHistoryDialogState extends ConsumerState<BatteryHistoryDialog> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(batteryHistoryProvider(widget.deviceId));
    final now = DateTime.now();
    final fmt = DateFormat('MMM d, h:mm a', 'en_US');
    return AlertDialog(
      title: Text('Battery history · ${widget.deviceId}'),
      content: SizedBox(
        width: 760,
        child: history.when(
          loading: () => const SizedBox(
            height: 280,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => const Text(Messages.generic),
          data: (points) {
            if (points.isEmpty) return const Text('No battery history yet.');
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pack voltage, last 7 days (one reading per 15 minutes)',
                  style: TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: AppSpace.m),
                if (_table)
                  SizedBox(
                    height: 280,
                    child: SingleChildScrollView(
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Time')),
                          DataColumn(label: Text('Voltage'), numeric: true),
                          DataColumn(label: Text('Percent'), numeric: true),
                        ],
                        rows: [
                          for (final p in points.reversed)
                            DataRow(
                              cells: [
                                DataCell(Text(fmt.format(p.at.toLocal()))),
                                DataCell(
                                  Text(
                                    '${p.voltage.toStringAsFixed(2)} V${p.sleep ? ' (sleep)' : ''}',
                                  ),
                                ),
                                DataCell(
                                  Text(
                                    p.percent == null ? '-' : '${p.percent}%',
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  )
                else
                  BatteryChart(points: points, now: now),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _table = !_table),
          child: Text(_table ? 'Show chart' : 'Show table'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
