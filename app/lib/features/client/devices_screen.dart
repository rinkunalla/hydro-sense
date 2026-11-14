import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/fleet_logic.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import 'widgets.dart';

/// Devices (home): is water flowing to every area? (docs/UI_UX_SPEC.md 4.1)
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fleet = ref.watch(fleetProvider);
    final phoneOffline = ref.watch(phoneOfflineProvider).valueOrNull ?? false;
    final name = ref.watch(profileProvider).valueOrNull?.firstName ?? '';

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
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: fleet.when(
          loading: () => const _Skeletons(),
          error: (_, _) =>
              _ErrorCard(onRetry: () => ref.invalidate(fleetProvider)),
          data: (f) =>
              _FleetBody(fleet: f, phoneOffline: phoneOffline, firstName: name),
        ),
      ),
    );
  }
}

class _FleetBody extends ConsumerWidget {
  const _FleetBody({
    required this.fleet,
    required this.phoneOffline,
    required this.firstName,
  });

  final Fleet fleet;
  final bool phoneOffline;
  final String firstName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    if (fleet.views.isEmpty) return const NoDevicesYet();
    final views = sortForHome(fleet.views);
    final banner = problemBanner(views, now);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.l,
        AppSpace.xl,
        AppSpace.l,
        AppSpace.xxl * 3,
      ),
      children: [
        Semantics(
          header: true,
          child: Text(
            firstName.isEmpty ? 'Welcome back' : 'Welcome back, $firstName',
            style: AppText.title(26),
          ),
        ),
        const SizedBox(height: AppSpace.l),
        if (phoneOffline && fleet.fromCache) ...[
          const AppBanner(
            icon: Icons.wifi_off_rounded,
            color: AppColors.steel,
            text: Messages.offlineBanner,
          ),
          const SizedBox(height: AppSpace.m),
        ],
        if (banner != null) ...[
          AppBanner(
            icon: StatusStyle.of(banner.kind).icon,
            color: StatusStyle.of(banner.kind).strong,
            text: banner.text,
          ),
          const SizedBox(height: AppSpace.m),
        ],
        const SectionLabel('Your devices'),
        FlipColumn(
          children: [
            for (final v in views)
              v.status == StatusKind.notSetUp
                  ? NotSetUpCard(key: ValueKey(v.id), view: v)
                  : DeviceCard(key: ValueKey(v.id), view: v, now: now),
          ],
        ),
      ],
    );
  }
}

/// One device on the home list (docs/UI_UX_SPEC.md section 3, Device card).
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.view, required this.now});

  final DeviceView view;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final status = view.status;
    final s = StatusStyle.of(status);
    final offline = status == StatusKind.offline;
    final flagged = view.isProblem || offline;
    final rate = view.device.flowRate;
    final figure = offline || rate == null ? '–' : rate.toStringAsFixed(1);
    final sleeping = offline && view.health?.lowVoltageSleep == true;

    return Semantics(
      button: true,
      label:
          '${view.nickname}, ${s.word}'
          '${offline || rate == null ? '' : ', $figure litres per minute'}',
      child: GestureDetector(
        onTap: () => context.go('/devices/${view.id}'),
        child: GlassPanel(
          edge: flagged ? s.strong : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DeviceIllustration(ring: s.strong),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          view.nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.title(18),
                        ),
                        const SizedBox(height: AppSpace.xs),
                        StatusChip(status),
                        if (view.since != null) ...[
                          const SizedBox(height: AppSpace.xs),
                          SinceLine(view: view, now: now),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.m),
              Wrap(
                spacing: AppSpace.m,
                runSpacing: AppSpace.s,
                crossAxisAlignment: WrapCrossAlignment.end,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  ExcludeSemantics(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: figure,
                                style: AppText.reading(32).copyWith(
                                  color: offline
                                      ? AppColors.steel
                                      : AppColors.ink,
                                ),
                              ),
                              if (!offline && rate != null)
                                TextSpan(text: ' L/min', style: AppText.note),
                            ],
                          ),
                        ),
                        LiveCue(view: view, now: now),
                      ],
                    ),
                  ),
                  BatteryGauge(view),
                ],
              ),
              if (sleeping) ...[
                const SizedBox(height: AppSpace.s),
                Text(
                  'Sleeping to save its battery. It wakes when the sun recharges it.',
                  style: AppText.note.copyWith(color: AppColors.ink),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A device assigned before delivery that has never connected (D41): the Wi-Fi
/// steps live in its own card (docs/UI_UX_SPEC.md 4.1 and 4.3).
class NotSetUpCard extends StatelessWidget {
  const NotSetUpCard({super.key, required this.view});

  final DeviceView view;

  @override
  Widget build(BuildContext context) => GlassPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            DeviceIllustration(
              ring: StatusStyle.of(StatusKind.notSetUp).strong,
            ),
            const SizedBox(width: AppSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    view.nickname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.title(18),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  const StatusChip(StatusKind.notSetUp),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.l),
        const SectionLabel('Connect it to Wi-Fi'),
        const WifiSteps(),
      ],
    ),
  );
}

/// The three setup steps; step 2 opens its details with How? / Hide.
class WifiSteps extends StatefulWidget {
  const WifiSteps({super.key});

  @override
  State<WifiSteps> createState() => _WifiStepsState();
}

class _WifiStepsState extends State<WifiSteps> {
  bool _open = false;

  Widget _step(int n, String title, Widget body) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.m),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: AppColors.buttonStops),
          ),
          child: Text(
            '$n',
            style: AppText.strong.copyWith(color: Colors.white, fontSize: 14),
          ),
        ),
        const SizedBox(width: AppSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.strong),
              const SizedBox(height: 2),
              body,
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final note = AppText.note.copyWith(color: AppColors.ink);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _step(
          1,
          'Switch the device on',
          Text('Plug it in or turn on its switch.', style: note),
        ),
        _step(
          2,
          'Connect it to Wi-Fi',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_open)
                Text(
                  'Join its HydroSense-XXXX Wi-Fi and pick your home Wi-Fi.',
                  style: note,
                )
              else
                for (final line in const [
                  'In the phone\'s Wi-Fi settings, join HydroSense-XXXX.',
                  'A setup page opens (or go to 192.168.4.1).',
                  'Pick your home Wi-Fi, type its password, tap Save.',
                  'The device light blinks slowly, then stays on.',
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text('• $line', style: note),
                  ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                ),
                onPressed: () => setState(() => _open = !_open),
                child: Text(_open ? 'Hide' : 'How?'),
              ),
            ],
          ),
        ),
        _step(
          3,
          'Wait about a minute',
          Text('This card turns into live readings by itself.', style: note),
        ),
        Text(
          'Changing Wi-Fi later: hold BOOT on the device for 5 seconds while it runs.',
          style: AppText.note,
        ),
      ],
    );
  }
}

/// Shown only when no device is assigned to the user (docs/UI_UX_SPEC.md 4.3).
class NoDevicesYet extends StatelessWidget {
  const NoDevicesYet({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: GlassPanel(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DeviceIllustration(ring: AppColors.deepCyan, size: 88),
            const SizedBox(height: AppSpace.l),
            Text(
              'No devices yet',
              textAlign: TextAlign.center,
              style: AppText.title(22),
            ),
            const SizedBox(height: AppSpace.s),
            Text(
              'Devices you buy are registered to your account before delivery and appear here.',
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: AppColors.steel),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Skeletons extends StatelessWidget {
  const _Skeletons();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppSpace.l),
    children: [
      for (var i = 0; i < AppConfig.skeletonCards; i++) ...[
        const SkeletonCard(),
        const SizedBox(height: AppSpace.m),
      ],
    ],
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: GlassPanel(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 40,
              color: AppColors.deepCyan,
            ),
            const SizedBox(height: AppSpace.m),
            Text(
              Messages.devicesFailed,
              textAlign: TextAlign.center,
              style: AppText.strong,
            ),
            const SizedBox(height: AppSpace.l),
            PrimaryButton(label: 'Try again', onPressed: onRetry),
          ],
        ),
      ),
    ),
  );
}
