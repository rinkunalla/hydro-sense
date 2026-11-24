import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';
import 'admin_widgets.dart';

/// Admin: adds a device ID (from the sticker or the serial log) with its name
/// and sensor. It shows as Not set up yet until it first connects (D62).
Future<void> showAddDeviceDialog(BuildContext context) async {
  final added = await showDialog<String>(
    context: context,
    builder: (_) => const _AddDeviceDialog(),
  );
  if (added != null && context.mounted) {
    showToast(context, '$added added. Connect it to Wi-Fi to start.');
  }
}

class _AddDeviceDialog extends ConsumerStatefulWidget {
  const _AddDeviceDialog();

  @override
  ConsumerState<_AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends ConsumerState<_AddDeviceDialog> {
  final _id = TextEditingController();
  final _name = TextEditingController();
  SensorType _sensor = SensorType.yfS201;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final id = normalizeDeviceId(_id.text);
    if (id == null) {
      setState(
        () => _error =
            'Enter the 12-character ID shown on the device sticker or setup page.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final name = _name.text.trim();
    try {
      await ref
          .read(adminRepositoryProvider)
          .addDevice(id, name: name.isEmpty ? null : name, sensor: _sensor);
      if (mounted) Navigator.pop(context, name.isEmpty ? id : name);
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add device'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _id,
            enabled: !_busy,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Device ID',
              helperText: 'Like A4F00F6936B0, on the sticker or setup page',
            ),
          ),
          const SizedBox(height: AppSpace.s),
          TextField(
            controller: _name,
            enabled: !_busy,
            maxLength: AppConfig.nicknameMax,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              helperText: 'Where it is, like Main pipe or Tank',
            ),
          ),
          DropdownButtonFormField<SensorType>(
            initialValue: _sensor,
            decoration: const InputDecoration(labelText: 'Flow sensor'),
            items: [
              for (final t in SensorType.values)
                DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: _busy
                ? null
                : (t) => setState(() => _sensor = t ?? _sensor),
          ),
          ErrorLine(_error),
          const SizedBox(height: AppSpace.s),
          Text(
            'Every staff member sees it at once, as Not set up yet until it connects to Wi-Fi.',
            style: AppText.note,
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
        child: Text(_busy ? 'Adding…' : 'Add device'),
      ),
    ],
  );
}
