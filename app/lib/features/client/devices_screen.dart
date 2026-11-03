import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/fleet_logic.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import 'calibrate.dart';
import 'widgets.dart';

/// Home: summary banner, AI insight card, device cards (docs/UI_UX_SPEC.md section 4.2).
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fleet = ref.watch(fleetProvider);
    final phoneOffline = ref.watch(phoneOfflineProvider).valueOrNull ?? false;

    // Polite live-region announcement when a card newly enters No Flow.
    ref.listen<AsyncValue<Fleet>>(fleetProvider, (prev, next) {
      final before = prev?.valueOrNull?.views;
      final after = next.valueOrNull?.views;
      if (before == null || after == null) return;
      for (final msg in newlyNoFlow(before, after)) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          msg,
          TextDirection.ltr,
          assertiveness: Assertiveness.polite,
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hydro Sense'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'calibrate') runCalibration(context, ref);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'calibrate',
                enabled: !phoneOffline,
                child: const Text('Calibrate flow'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: fleet.when(
          loading: () => const _Skeletons(),
          error: (_, _) =>
              _ErrorCard(onRetry: () => ref.invalidate(fleetProvider)),
          data: (f) => _FleetBody(fleet: f, phoneOffline: phoneOffline),
        ),
      ),
    );
  }
}

class _FleetBody extends ConsumerWidget {
  const _FleetBody({required this.fleet, required this.phoneOffline});

  final Fleet fleet;
  final bool phoneOffline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    final views = sortForHome(fleet.views);
    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
        if (phoneOffline && fleet.fromCache) ...[
          const _OfflineBanner(),
          const SizedBox(height: AppSpace.m),
        ],
        if (views.isEmpty)
          const _FirstRun()
        else ...[
          _SummaryBanner(bannerFor(views)),
          const SizedBox(height: AppSpace.m),
          _InsightCard(views: views, phoneOffline: phoneOffline),
          const SizedBox(height: AppSpace.m),
          FlipColumn(
            children: [
              for (final v in views)
                DeviceCard(key: ValueKey(v.id), view: v, now: now),
            ],
          ),
        ],
      ],
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.m),
    decoration: BoxDecoration(
      color: AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(AppSpace.cardRadius),
    ),
    child: const Row(
      children: [
        Icon(Icons.wifi_off, color: AppColors.text),
        SizedBox(width: AppSpace.s),
        Expanded(child: Text(Messages.offlineBanner)),
      ],
    ),
  );
}

class _SummaryBanner extends StatelessWidget {
  const _SummaryBanner(this.info);

  final BannerInfo info;

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(info.kind);
    return Semantics(
      container: true,
      label: info.text,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.l),
        decoration: BoxDecoration(
          color: s.soft,
          borderRadius: BorderRadius.circular(AppSpace.cardRadius),
        ),
        child: Row(
          children: [
            Icon(s.icon, color: s.strong, size: 28),
            const SizedBox(width: AppSpace.m),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  info.text,
                  style: TextStyle(
                    color: s.chipText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InsightCard extends ConsumerStatefulWidget {
  const _InsightCard({required this.views, required this.phoneOffline});

  final List<DeviceView> views;
  final bool phoneOffline;

  @override
  ConsumerState<_InsightCard> createState() => _InsightCardState();
}

class _InsightCardState extends ConsumerState<_InsightCard> {
  bool _refreshing = false;
  DateTime? _cooldownUntil;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await ref.read(repositoryProvider).refreshSummary();
    } catch (e) {
      final d = callableDetails(e);
      if (d.code == 'COOLDOWN' && d.retryAfterSeconds != null) {
        _cooldownUntil = DateTime.now().add(
          Duration(seconds: d.retryAfterSeconds!),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text(Messages.summaryFailed)));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(summaryProvider).valueOrNull;
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    final text = summary?.text;
    final stale = summaryIsStale(summary, widget.views);
    final cooling = _cooldownUntil != null && _cooldownUntil!.isAfter(now);
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted);

    Widget button = IconButton(
      tooltip: widget.phoneOffline ? 'Needs internet.' : 'Refresh summary',
      onPressed: widget.phoneOffline || cooling || _refreshing
          ? null
          : _refresh,
      icon: _refreshing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Water flow summary',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                button,
              ],
            ),
            if (stale) ...[
              const SizedBox(height: AppSpace.xs),
              const _SmallChip(StatusKind.lowFlow, 'May be out of date'),
            ],
            const SizedBox(height: AppSpace.s),
            Text(
              text ??
                  'No summary yet. One appears after the first change in flow.',
            ),
            if (summary?.lastUpdated != null) ...[
              const SizedBox(height: AppSpace.s),
              Text(
                'Updated ${clockTime(summary!.lastUpdated!, now)}',
                style: muted,
              ),
            ],
            if (cooling) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                'You can refresh again in ${waitText(_cooldownUntil!.difference(now))}.',
                style: muted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SmallChip extends StatelessWidget {
  const _SmallChip(this.kind, this.text);

  final StatusKind kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: s.soft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: s.chipText,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One device on the home list.
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.view, required this.now});

  final DeviceView view;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final status = view.status;
    final s = StatusStyle.of(status);
    final problem = view.isProblem;
    final offline = status == StatusKind.offline;
    final waiting = status == StatusKind.waiting;
    final h = view.health;
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted);
    final rate = view.device.flowRate;
    final rateText = offline || rate == null ? '-' : rate.toStringAsFixed(1);
    final rateSpoken = offline || rate == null
        ? 'no reading'
        : '$rateText liters per minute';

    final freshness = offline && h?.lastSeen != null
        ? 'Last seen ${clockTime(h!.lastSeen!, now)}'
        : h?.lastSeen != null
        ? 'Updated ${relativeAge(h!.lastSeen!, now)}'
        : null;

    return Semantics(
      button: true,
      label: '${view.nickname}, ${s.word.toLowerCase()}, $rateSpoken',
      child: Material(
        color: problem ? s.soft : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpace.cardRadius),
          side: const BorderSide(color: AppColors.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/devices/${view.id}'),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (problem) Container(width: 4, color: s.strong),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.l),
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  view.nickname,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: AppSpace.s),
                              Flexible(child: StatusChip(status)),
                            ],
                          ),
                          const SizedBox(height: AppSpace.s),
                          if (waiting)
                            const LinearProgressIndicator(minHeight: 3)
                          else
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: rateText,
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w600,
                                      color: offline
                                          ? AppColors.textMuted
                                          : AppColors.text,
                                    ),
                                  ),
                                  const TextSpan(text: ' L/min'),
                                ],
                              ),
                            ),
                          const SizedBox(height: AppSpace.s),
                          Wrap(
                            spacing: AppSpace.m,
                            runSpacing: AppSpace.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              BatteryLine(view),
                              if (view.pausedAt(now))
                                const StatusChip(StatusKind.paused),
                              if (freshness != null)
                                Text(freshness, style: muted),
                            ],
                          ),
                          if (offline && h?.lowVoltageSleep == true) ...[
                            const SizedBox(height: AppSpace.xs),
                            Text(
                              'Sleeping to save its battery. It wakes when the sun recharges it.',
                              style: muted,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Skeletons extends StatelessWidget {
  const _Skeletons();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppSpace.l),
    children: [
      for (var i = 0; i < AppConfig.skeletonCards; i++)
        Container(
          height: 120,
          margin: const EdgeInsets.only(bottom: AppSpace.m),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(AppSpace.cardRadius),
          ),
        ),
    ],
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppSpace.l),
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(Messages.devicesFailed),
              const SizedBox(height: AppSpace.m),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    ],
  );
}

class _FirstRun extends StatelessWidget {
  const _FirstRun();

  @override
  Widget build(BuildContext context) {
    final steps = [
      'Ask your installer to add your device ID, then power on your Hydro Sense device.',
      'On your phone, join the Wi-Fi network named "HydroSense-XXXX" and choose your home Wi-Fi.',
      'Wait about a minute. The device appears here by itself.',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(
              child: Icon(Icons.sensors, size: 64, color: AppColors.accent),
            ),
            const SizedBox(height: AppSpace.m),
            Text(
              'No devices yet.',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpace.m),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.s),
                child: Text('${i + 1}. ${steps[i]}'),
              ),
          ],
        ),
      ),
    );
  }
}
