import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import 'map_screen.dart' show mapFullscreenProvider;

/// The Arctic background behind every tab and a glass bottom bar with three
/// tabs: Devices, Map, Account.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const _tabs = [
    (Icons.water_drop_outlined, Icons.water_drop_rounded, 'Devices'),
    (Icons.map_outlined, Icons.map_rounded, 'Map'),
    (Icons.person_outline_rounded, Icons.person_rounded, 'Account'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The full-screen map hides the bar, on the Map tab only.
    final hideBar = ref.watch(mapFullscreenProvider) && shell.currentIndex == 1;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: shell,
        bottomNavigationBar: hideBar
            ? null
            : SafeArea(
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
                    crossAxisAlignment: CrossAxisAlignment.center,
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
        // A bottom bar gets loose constraints up to the full screen height, so
        // every piece must size to its content (the bar once filled the screen).
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSpace.pill),
          // Selected: pale tint with dark text (D68), never a strong fill.
          color: selected ? AppColors.actionTint : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: selected ? AppColors.onActionTint : AppColors.deepCyan,
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.strong.copyWith(
                fontSize: 12,
                color: selected ? AppColors.onActionTint : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
