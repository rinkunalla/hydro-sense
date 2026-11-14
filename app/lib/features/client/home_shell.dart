import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';

/// The Arctic background behind every tab and a glass bottom bar with three
/// tabs: Devices, Map, Account (docs/UI_UX_SPEC.md section 3).
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const _tabs = [
    (Icons.water_drop_outlined, Icons.water_drop_rounded, 'Devices'),
    (Icons.map_outlined, Icons.map_rounded, 'Map'),
    (Icons.person_outline_rounded, Icons.person_rounded, 'Account'),
  ];

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: shell,
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(
            AppSpace.l,
            0,
            AppSpace.l,
            AppSpace.m,
          ),
          child: GlassPanel(
            radius: AppSpace.pill,
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                for (final (i, t) in _tabs.indexed)
                  Expanded(
                    child: _Tab(
                      icon: i == shell.currentIndex ? t.$2 : t.$1,
                      label: t.$3,
                      selected: i == shell.currentIndex,
                      onTap: () => shell.goBranch(
                        i,
                        initialLocation: i == shell.currentIndex,
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

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    excludeSemantics: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(AppSpace.pill),
      onTap: onTap,
      child: AnimatedContainer(
        duration: reduceMotion(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        constraints: const BoxConstraints(minHeight: 52),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSpace.pill),
          gradient: selected
              ? const LinearGradient(colors: AppColors.buttonStops)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: selected ? Colors.white : AppColors.deepCyan,
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.strong.copyWith(
                fontSize: 12,
                color: selected ? Colors.white : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
