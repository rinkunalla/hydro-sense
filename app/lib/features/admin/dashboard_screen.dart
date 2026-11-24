import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/admin_logic.dart';
import '../../data/providers.dart';
import '../client/widgets.dart';
import 'admin_widgets.dart';

/// The website's first page (D67): how many devices are in each state, and
/// the devices that need attention now, worst first.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fleet = ref.watch(fleetProvider);
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    final views = fleet.valueOrNull?.views ?? const [];
    final counts = countStatuses(views);
    final attention = needAttention(views);

    Widget tile(StatusKind kind, String label, int n) {
      final st = StatusStyle.of(kind);
      return SizedBox(
        width: 200,
        child: GlassPanel(
          child: Semantics(
            label: '$label: $n',
            excludeSemantics: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(st.icon, color: st.strong, size: 20),
                    const SizedBox(width: AppSpace.s),
                    Expanded(child: Text(label, style: AppText.strong)),
                  ],
                ),
                const SizedBox(height: AppSpace.xs),
                Text('$n', style: AppText.reading(36)),
              ],
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
        AdminPageHeader(
          title: 'Dashboard',
          actions: [
            SecondaryButton(
              label: 'Open map',
              icon: Icons.map_rounded,
              onPressed: () => context.go('/map'),
            ),
          ],
        ),
        if (fleet.hasError)
          Text(Messages.generic, style: AppText.body)
        else if (!fleet.hasValue)
          const Center(child: CircularProgressIndicator())
        else ...[
          Wrap(
            spacing: AppSpace.m,
            runSpacing: AppSpace.m,
            children: [
              tile(StatusKind.normal, 'Normal', counts.normal),
              tile(StatusKind.lowFlow, 'Low flow', counts.lowFlow),
              tile(StatusKind.noFlow, 'No water', counts.noFlow),
              tile(StatusKind.offline, 'Offline', counts.offline),
              if (counts.other > 0)
                tile(
                  StatusKind.notSetUp,
                  'Not set up or waiting',
                  counts.other,
                ),
            ],
          ),
          const SizedBox(height: AppSpace.l),
          AdminCard(
            title: attention.isEmpty
                ? 'Nothing needs attention'
                : 'Needs attention now',
            child: attention.isEmpty
                ? Text(
                    counts.total == 0
                        ? 'No devices yet. Add one on the Devices page.'
                        : 'Every device has water and is online.',
                    style: AppText.body,
                  )
                : Column(
                    children: [
                      for (final v in attention)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: StatusChip(v.status),
                          title: Text(v.nickname, style: AppText.strong),
                          subtitle: SinceLine(view: v, now: now),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.go('/devices/${v.id}'),
                        ),
                    ],
                  ),
          ),
        ],
      ],
    );
  }
}
