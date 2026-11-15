import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/admin_providers.dart';
import '../../data/providers.dart';
import 'admin_widgets.dart';

class _Dest {
  const _Dest(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;
}

const _destinations = [
  _Dest('/users', 'Users', Icons.people_alt_rounded),
  _Dest('/devices', 'Devices', Icons.memory_rounded),
  _Dest('/account', 'Account', Icons.person_rounded),
];

/// Glass top bar on every admin page: logo + "Admin", the three tabs, and the
/// admin's avatar (docs/UI_UX_SPEC.md section 6). Under 800 px the tabs move
/// into a drawer. Content is at most 1200 px wide.
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
    // Marks an invited admin active on the first sign-in and picks up a
    // verified email change (D40); the lists reload once it is done.
    ref
        .read(adminRepositoryProvider)
        .syncMyAdmin()
        .then((_) {
          if (!mounted) return;
          ref.invalidate(adminsProvider);
          ref.invalidate(adminUsersProvider);
          ref.invalidate(adminDevicesProvider);
        })
        .catchError((Object _) {});
  }

  int get _index {
    final i = _destinations.indexWhere(
      (d) => widget.location.startsWith(d.path),
    );
    return i < 0 ? 1 : i;
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
            gradient: const LinearGradient(colors: AppColors.buttonStops),
          ),
          child: const Icon(Icons.water_drop_rounded, color: Colors.white),
        ),
        const SizedBox(width: AppSpace.s),
        Text('Hydro Sense', style: AppText.title(18)),
        const SizedBox(width: AppSpace.s),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.tint,
            borderRadius: BorderRadius.circular(AppSpace.pill),
          ),
          child: Text(
            'Admin',
            style: AppText.strong.copyWith(
              fontSize: 12,
              color: AppColors.deepCyan,
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
          color: Colors.transparent,
          shape: const StadiumBorder(),
          child: Ink(
            decoration: selected
                ? const ShapeDecoration(
                    shape: StadiumBorder(),
                    gradient: LinearGradient(colors: AppColors.buttonStops),
                  )
                : null,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => context.go(d.path),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      d.icon,
                      size: 20,
                      color: selected ? Colors.white : AppColors.steel,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      d.label,
                      style: AppText.strong.copyWith(
                        fontSize: 15,
                        color: selected ? Colors.white : AppColors.ink,
                      ),
                    ),
                  ],
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
            const Spacer(),
            if (wide) ...[
              for (var i = 0; i < _destinations.length; i++) ...[
                tab(i),
                const SizedBox(width: 4),
              ],
              const Spacer(),
            ],
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
