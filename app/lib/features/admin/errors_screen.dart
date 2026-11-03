import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_providers.dart';
import '../../data/providers.dart' show clockProvider;
import 'admin_widgets.dart';

/// Codes from docs/ERROR_HANDLING.md section 3 that land in error_logs.
const errorCodes = [
  'AI_FAILED',
  'AI_INVALID_OUTPUT',
  'ALERT_CAP_REACHED',
  'CALIBRATION_FALLBACK',
  'DEVICE_AUTH_FAILED',
  'DEVICE_RESET',
  'EMAIL_FAILED',
  'INTERNAL',
  'PAYLOAD_INVALID',
  'PROVISIONING_KEY_INVALID',
  'REGISTER_RATE_LIMITED',
  'SMS_FAILED',
];

class ErrorsScreen extends ConsumerStatefulWidget {
  const ErrorsScreen({super.key});

  @override
  ConsumerState<ErrorsScreen> createState() => _ErrorsScreenState();
}

class _ErrorsScreenState extends ConsumerState<ErrorsScreen> {
  String? _device;
  String? _code;
  int _pages = 1;

  @override
  Widget build(BuildContext context) {
    final devices =
        (ref.watch(healthListProvider).valueOrNull ?? const [])
            .map((h) => h.id)
            .toList()
          ..sort();
    final page = ref.watch(
      errorPageProvider((deviceId: _device, code: _code, pages: _pages)),
    );
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();

    return ListView(
      padding: const EdgeInsets.all(AppSpace.xl),
      children: [
        SectionCard(
          title: 'Errors',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: AppSpace.l,
                runSpacing: AppSpace.m,
                children: [
                  _Filter(
                    label: 'Device',
                    value: _device,
                    options: devices,
                    onChanged: (v) => setState(() {
                      _device = v;
                      _pages = 1;
                    }),
                  ),
                  _Filter(
                    label: 'Code',
                    value: _code,
                    options: errorCodes,
                    onChanged: (v) => setState(() {
                      _code = v;
                      _pages = 1;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.l),
              page.when(
                loading: () => const LinearProgressIndicator(),
                error: (_, _) => const Text(Messages.generic),
                data: (errors) {
                  if (errors.isEmpty) return const Text('No errors logged.');
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          headingRowColor: const WidgetStatePropertyAll(
                            AppColors.surfaceAlt,
                          ),
                          columns: const [
                            DataColumn(label: Text('Time')),
                            DataColumn(label: Text('Device')),
                            DataColumn(label: Text('Source')),
                            DataColumn(label: Text('Code')),
                            DataColumn(label: Text('Message')),
                          ],
                          rows: [
                            for (final e in errors)
                              DataRow(
                                cells: [
                                  DataCell(
                                    Text(
                                      e.ts == null
                                          ? '-'
                                          : clockTime(e.ts!, now),
                                    ),
                                  ),
                                  DataCell(
                                    Text(
                                      e.deviceId ?? 'system',
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                  DataCell(Text(e.source)),
                                  DataCell(Text(e.code)),
                                  DataCell(
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 420,
                                      ),
                                      child: Text(
                                        e.message,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      if (errors.length >= _pages * AppConfig.errorLogsPageSize)
                        TextButton(
                          onPressed: () => setState(() => _pages++),
                          child: const Text('Load more'),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Filter extends StatelessWidget {
  const _Filter({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 260,
    child: DropdownButtonFormField<String?>(
      isExpanded: true,
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('All')),
        for (final o in options)
          DropdownMenuItem<String?>(
            value: o,
            child: Text(o, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    ),
  );
}
