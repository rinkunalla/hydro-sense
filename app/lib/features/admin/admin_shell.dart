import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/providers.dart';
import 'admin_widgets.dart';

class _Dest {
  const _Dest(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;
}

/// The website menu (D67). The Dashboard is the map (2026-11-25), so there
/// is no separate Map item; the pipeline editor (/map/edit) sits under it.
const _destinations = [
  _Dest('/dashboard', 'Dashboard', Icons.dashboard_rounded),
  _Dest('/devices', 'Devices', Icons.water_drop_rounded),
  _Dest('/history', 'History', Icons.history_rounded),
  _Dest('/staff', 'Staff', Icons.people_alt_rounded),
  _Dest('/account', 'Account', Icons.person_rounded),
];

/// Glass top bar on every admin page: logo + "Admin", the menu, and the
/// admin's avatar; under it the alert banner while something needs attention.
/// Under 800 px the menu moves into a drawer. Content is at most 1200 px wide.
class AdminShell extends ConsumerStatefulWidget {
  const AdminShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends ConsumerState<AdminShell> {
  @override
  void initState() {
    super.initState();
    // Marks an invited admin active on the first sign-in, picks up a verified
    // email change and lets the account read the live channel (/members);
    // the lists and live data reload once it is done.
    ref
        .read(adminRepositoryProvider)
        .syncMyAdmin()
        .then((_) {
          if (!mounted) return;
          ref.invalidate(adminsProvider);
          ref.invalidate(staffProvider);
          ref.invalidate(fleetProvider);
        })
        .catchError((Object _) {});
  }

  int get _index {
    // The pipeline editor (/map/edit) belongs to the Dashboard's map.
    final i = _destinations.indexWhere(
      (d) => widget.location.startsWith(d.path),
    );
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= AppConfig.adminRailBreakpoint;
    final user = ref.watch(userProvider).valueOrNull;
    final me = (user?.displayName?.isNotEmpty ?? false)
        ? user!.displayName!
        : (user?.email ?? 'Admin');

    final logo = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: AppColors.action,
          ),
          child: const Icon(Icons.water_drop_rounded, color: Colors.white),
        ),
        const SizedBox(width: AppSpace.s),
        Text('Hydro Sense', style: AppText.title(18)),
        const SizedBox(width: AppSpace.s),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.actionTint,
            borderRadius: BorderRadius.circular(AppSpace.pill),
          ),
          child: Text(
            'Admin',
            style: AppText.strong.copyWith(
              fontSize: 12,
              color: AppColors.onActionTint,
            ),
          ),
        ),
      ],
    );

    Widget tab(int i) {
      final d = _destinations[i];
      final selected = i == _index;
      return Semantics(
        button: true,
        selected: selected,
        child: Material(
          // Selected: pale tint with dark text (D68).
          color: selected ? AppColors.actionTint : Colors.transparent,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => context.go(d.path),
            // Text only: six items with icons overflowed the bar at 1280 px.
            // The drawer under 800 px keeps the icons.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                d.label,
                style: AppText.strong.copyWith(
                  fontSize: 15,
                  color: selected ? AppColors.onActionTint : AppColors.ink,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.m, AppSpace.l, 0),
      child: GlassPanel(
        radius: AppSpace.pill,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (!wide)
              Builder(
                builder: (c) => IconButton(
                  tooltip: 'Menu',
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: () => Scaffold.of(c).openDrawer(),
                ),
              ),
            logo,
            if (wide)
              // Scrolls sideways instead of overflowing on a narrow window.
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < _destinations.length; i++) ...[
                          tab(i),
                          const SizedBox(width: 2),
                        ],
                      ],
                    ),
                  ),
                ),
              )
            else
              const Spacer(),
            Tooltip(
              message: me,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => context.go('/account'),
                child: Avatar(me, size: 36),
              ),
            ),
          ],
        ),
      ),
    );

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        drawer: wide
            ? null
            : Drawer(
                child: SafeArea(
                  child: ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(AppSpace.l),
                        child: logo,
                      ),
                      for (var i = 0; i < _destinations.length; i++)
                        ListTile(
                          leading: Icon(_destinations[i].icon),
                          title: Text(_destinations[i].label),
                          selected: i == _index,
                          selectedColor: AppColors.onActionTint,
                          selectedTileColor: AppColors.actionTint,
                          onTap: () {
                            Navigator.pop(context);
                            context.go(_destinations[i].path);
                          },
                        ),
                    ],
                  ),
                ),
              ),
        body: SafeArea(
          child: Column(
            children: [
              bar,
              // The Dashboard lists the same devices beside its map.
              if (widget.location != '/dashboard') const AlertBanner(),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppConfig.adminMaxContentWidth,
                    ),
                    child: widget.child,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The website's on-screen alert (D65): while the site is open, every device
/// that has no water, low flow or is offline, worst first. It follows the
/// live data, so it shows as soon as the device reports the problem. Tapping
/// it opens that device's Details, or the Dashboard's map when several devices
/// need attention. Not shown on the Dashboard, which lists them beside its map.
class AlertBanner extends ConsumerWidget {
  const AlertBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = ref.watch(fleetProvider).valueOrNull?.views ?? const [];
    final items = needAttention(views);
    if (items.isEmpty) return const SizedBox.shrink();
    final worst = StatusStyle.of(items.first.status);
    final shown = items
        .take(3)
        .map((v) => '${v.nickname} (${StatusStyle.of(v.status).word})')
        .join(', ');
    final more = items.length > 3 ? ', +${items.length - 3} more' : '';
    final text = items.length == 1
        ? '$shown needs attention.'
        : '${items.length} areas need attention: $shown$more.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.s, AppSpace.l, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppConfig.adminMaxContentWidth,
        ),
        child: Semantics(
          liveRegion: true,
          button: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppSpace.cardRadius),
              onTap: () => context.go(
                items.length == 1
                    ? '/devices/${items.first.id}'
                    : '/dashboard?focus=problem',
              ),
              child: GlassPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.m,
                  vertical: AppSpace.s,
                ),
                child: Row(
                  children: [
                    Icon(worst.icon, color: worst.strong),
                    const SizedBox(width: AppSpace.s),
                    Expanded(child: Text(text, style: AppText.strong)),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
