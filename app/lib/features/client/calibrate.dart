import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/time_format.dart';
import '../../data/models.dart';
import '../../data/providers.dart';

/// "Garden Line: updated" and the two kept-limits wordings (docs/UI_UX_SPEC.md section 4.5).
String calibrationLine(CalibrationResult r) => switch (r.result) {
  'updated' => '${r.nickname}: updated',
  'kept_recent_alert' =>
    '${r.nickname}: kept current limits (this line had a problem in the last 24 h)',
  _ =>
    '${r.nickname}: kept current limits (not enough steady flow data in the last 24 h)',
};

Future<void> runCalibration(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Calibrate flow limits?'),
      content: const Text(
        'Hydro Sense will use the last 24 hours of water use to adjust when a line counts as '
        'Low or No flow. Each device applies the new limits on its next update '
        '(within about a minute).',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Calibrate'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  String title = 'Calibration results';
  List<String> lines;
  try {
    final results = await ref.read(repositoryProvider).calibrate();
    lines = results.isEmpty
        ? ['No devices to calibrate yet.']
        : results.map(calibrationLine).toList();
  } catch (e) {
    final d = callableDetails(e);
    title = 'Not calibrated';
    lines = [
      d.code == 'COOLDOWN' && d.retryAfterSeconds != null
          ? 'You can calibrate again in ${waitText(Duration(seconds: d.retryAfterSeconds!))}.'
          : callableMessage(e),
    ];
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(l)),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
