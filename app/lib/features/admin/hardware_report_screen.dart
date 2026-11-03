import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_providers.dart';
import '../../data/providers.dart' show clockProvider;
import 'admin_widgets.dart';

class HardwareReportScreen extends ConsumerStatefulWidget {
  const HardwareReportScreen({super.key});

  @override
  ConsumerState<HardwareReportScreen> createState() =>
      _HardwareReportScreenState();
}

class _HardwareReportScreenState extends ConsumerState<HardwareReportScreen> {
  bool _running = false;
  DateTime? _cooldownUntil;

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      await ref.read(adminRepositoryProvider).runHardwareReport();
    } catch (e) {
      final d = callableDetails(e);
      if (d.code == 'COOLDOWN' && d.retryAfterSeconds != null) {
        setState(
          () => _cooldownUntil = DateTime.now().add(
            Duration(seconds: d.retryAfterSeconds!),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't run the report. The previous report is kept.",
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(diagnosticsProvider);
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    final cooling = _cooldownUntil != null && _cooldownUntil!.isAfter(now);
    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: [
        SectionCard(
          title: 'Hardware report',
          action: FilledButton.icon(
            onPressed: _running || cooling ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: const Text('Run report'),
          ),
          child: report.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => const Text(Messages.generic),
            data: (r) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  r?.text ??
                      'No report yet. Run one, or wait for the daily report at 6 AM.',
                ),
                if (r?.lastUpdated != null) ...[
                  const SizedBox(height: AppSpace.m),
                  Text(
                    'Updated ${clockTime(r!.lastUpdated!, now)}',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                ],
                if (cooling) ...[
                  const SizedBox(height: AppSpace.s),
                  Text(
                    'You can run the report again in ${waitText(_cooldownUntil!.difference(now))}.',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
