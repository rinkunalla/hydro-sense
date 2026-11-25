import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/admin_logic.dart';
import '../../data/providers.dart';
import '../client/map_screen.dart';
import '../client/widgets.dart';
import 'admin_widgets.dart';

/// The website's first page: the map (the app's own map with the pipeline,
/// and Edit pipeline for the admin) beside how many devices are in each state
/// and the devices that need attention now, worst first. Old /map links come
/// here with their focus (D67, 2026-11-25).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({
    super.key,
    this.focusProblem = false,
    this.focusDevice,
  });

  /// Centre the map on the problem segment.
  final bool focusProblem;

  /// Centre the map on this device (a device's "Show on map").
  final String? focusDevice;

  /// The side column's width on a wide screen.
  static const double sideWidth = 320;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide =
        MediaQuery.sizeOf(context).width >= AppConfig.adminRailBreakpoint;
    final map = ClipRRect(
      borderRadius: BorderRadius.circular(AppSpace.cardRadius),
      child: MapScreen(focusProblem: focusProblem, focusDevice: focusDevice),
    );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: map),
            const SizedBox(width: AppSpace.l),
            SizedBox(
              width: sideWidth,
              child: ListView(children: const [_Counts(), _Attention()]),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
        const _Counts(),
        SizedBox(height: 460, child: map),
        const _Attention(),
      ],
    );
  }
}

/// Normal, Low flow, No water and Offline in a 2 x 2 grid (and the devices
/// not set up or waiting for a first reading, when there are any).
class _Counts extends ConsumerWidget {
  const _Counts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fleet = ref.watch(fleetProvider);
    if (fleet.hasError) return Text(Messages.generic, style: AppText.body);
    if (!fleet.hasValue) {
      return const Padding(
        padding: EdgeInsets.all(AppSpace.l),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final c = countStatuses(fleet.requireValue.views);

    Widget tile(StatusKind kind, String label, int n) {
      final st = StatusStyle.of(kind);
      return GlassPanel(
        padding: const EdgeInsets.all(AppSpace.m),
        child: Semantics(
          label: '$label: $n',
          excludeSemantics: true,
          child: Row(
            children: [
              Icon(st.icon, color: st.strong, size: 20),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Text(
                  label,
                  style: AppText.strong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('$n', style: AppText.reading(24)),
            ],
          ),
        ),
      );
    }

    Widget pair(Widget a, Widget b) => Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: AppSpace.s),
        Expanded(child: b),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.m),
      child: Column(
        children: [
          pair(
            tile(StatusKind.normal, 'Normal', c.normal),
            tile(StatusKind.lowFlow, 'Low flow', c.lowFlow),
          ),
          const SizedBox(height: AppSpace.s),
          pair(
            tile(StatusKind.noFlow, 'No water', c.noFlow),
            tile(StatusKind.offline, 'Offline', c.offline),
          ),
          if (c.other > 0) ...[
            const SizedBox(height: AppSpace.s),
            tile(StatusKind.notSetUp, 'Not set up or waiting', c.other),
          ],
        ],
      ),
    );
  }
}

/// The devices that need attention now; a row opens its Details.
class _Attention extends ConsumerWidget {
  const _Attention();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fleet = ref.watch(fleetProvider);
    if (!fleet.hasValue) return const SizedBox.shrink();
    final views = fleet.requireValue.views;
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    final attention = needAttention(views);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.m),
      child: AdminCard(
        title: attention.isEmpty
            ? 'Nothing needs attention'
            : 'Needs attention now',
        child: attention.isEmpty
            ? Text(
                views.isEmpty
                    ? 'No devices yet. Add one on the Devices page.'
                    : 'Every device has water and is online.',
                style: AppText.body,
              )
            : Column(
                children: [
                  for (final v in attention)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(v.nickname, style: AppText.strong),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: AppSpace.xs),
                          StatusChip(v.status),
                          SinceLine(view: v, now: now),
                        ],
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.go('/devices/${v.id}'),
                    ),
                ],
              ),
      ),
    );
  }
}
