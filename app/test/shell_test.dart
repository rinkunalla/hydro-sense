// The real tab shell (HomeShell inside go_router's shell route). It once filled
// the whole screen on a phone because a bottom bar gets loose constraints up to
// the full height; the screen tests drew pages alone and missed it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydro_sense/app.dart';
import 'package:hydro_sense/core/glass.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/features/client/home_shell.dart';

Widget page(String name) => Scaffold(
  backgroundColor: Colors.transparent,
  body: Center(child: Text('$name page')),
);

void main() {
  for (final scale in [1.0, 1.5]) {
    testWidgets('the tab bar stays a bar at ${scale}x text', (t) async {
      t.view.physicalSize = const Size(360 * 3, 780 * 3);
      t.view.devicePixelRatio = 3;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);

      final router = GoRouter(
        initialLocation: '/devices',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => HomeShell(shell: shell),
            branches: [
              for (final name in ['devices', 'map', 'account'])
                StatefulShellBranch(
                  routes: [
                    GoRoute(path: '/$name', builder: (_, _) => page(name)),
                  ],
                ),
            ],
          ),
        ],
      );
      await t.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            theme: buildLightTheme(),
            builder: clampTextScale,
            routerConfig: router,
          ),
        ),
      );
      await t.pumpAndSettle();

      final bar = t.getSize(find.byType(GlassPanel).last);
      expect(bar.height, lessThan(110), reason: 'bar height ${bar.height}');
      expect(bar.height, greaterThanOrEqualTo(52));
      // The page above the bar is visible and can be tapped.
      expect(find.text('devices page').hitTestable(), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Map'));
      await t.pumpAndSettle();
      expect(find.text('map page').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
