import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/admin_providers.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import 'admin_widgets.dart';

/// Admin only, on a device's Details (D63, D69): the flow sensor fitted to
/// it, and Remove device.
class DeviceAdminCard extends ConsumerStatefulWidget {
  const DeviceAdminCard({super.key, required this.view});

  final DeviceView view;

  @override
  ConsumerState<DeviceAdminCard> createState() => _DeviceAdminCardState();
}

class _DeviceAdminCardState extends ConsumerState<DeviceAdminCard> {
  bool _busy = false;

  Future<void> _setSensor(SensorType? next) async {
    final d = widget.view.device;
    if (next == null || next == d.sensorType) return;
    final ok = await confirmAction(
      context,
      title: 'Change the sensor to ${next.label}?',
      message:
          'The flow limits start over from the ${next.label} starter values '
          '(Low flow below ${next.starterNormal.toStringAsFixed(1)} L/min). '
          'The device gets them in its next upload. Only do this after fitting the new sensor.',
      buttonLabel: 'Change sensor',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).setSensorType(d.id, next);
      if (mounted) showToast(context, 'Sensor set to ${next.label}');
    } catch (e) {
      if (mounted) showToast(context, adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final v = widget.view;
    final ok = await confirmByTyping(
      context,
      title: 'Remove ${v.nickname}?',
      message:
          'Its history, map place and live data are deleted at once and can\'t be restored. '
          'The device stops reporting until you add its ID again.',
      confirmWord: v.nickname,
      buttonLabel: 'Remove device',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .removeDevice(v.id, confirmName: v.nickname);
      if (!mounted) return;
      showToast(context, '${v.nickname} removed');
      context.go('/devices');
    } catch (e) {
      if (mounted) showToast(context, adminErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.view.device;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Device'),
          Text('ID ${d.id}', style: AppText.note),
          const SizedBox(height: AppSpace.s),
          DropdownButtonFormField<SensorType>(
            initialValue: d.sensorType,
            decoration: const InputDecoration(labelText: 'Flow sensor'),
            items: [
              for (final t in SensorType.values)
                DropdownMenuItem(
                  value: t,
                  child: Text(
                    '${t.label} (${t.cutoffMin.toStringAsFixed(0)}–${t.cutoffMax.toStringAsFixed(0)} L/min)',
                  ),
                ),
            ],
            onChanged: _busy ? null : _setSensor,
          ),
          const SizedBox(height: AppSpace.l),
          Align(
            alignment: Alignment.centerLeft,
            child: SecondaryButton(
              label: 'Remove device',
              icon: Icons.delete_outline_rounded,
              destructive: true,
              onPressed: _busy ? null : _remove,
            ),
          ),
        ],
      ),
    );
  }
}
