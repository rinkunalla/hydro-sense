// User app screens (KICKOFF.md stage 4) with fake data: 1, 3 and 10 devices,
// Not set up yet, Offline, Live/Late, the since line, the empty state, loading,
// error, no internet, reduce motion and solid glass, and 1.5x text at 360 dp.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/app.dart';
import 'package:hydro_sense/core/glass.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/features/client/device_detail_screen.dart';
import 'package:hydro_sense/features/client/devices_screen.dart';
import 'package:hydro_sense/features/client/widgets.dart';

import 'test_data.dart';

Widget harness(
  Stream<Fleet> fleet, {
  bool phoneOffline = false,
  Widget home = const DevicesScreen(),
  List<FlowPoint> history = const [],
  bool solid = false,
}) => ProviderScope(
  overrides: [
    fleetProvider.overrideWith((_) => fleet),
    phoneOfflineProvider.overrideWith((_) => Stream.value(phoneOffline)),
    clockProvider.overrideWith((_) => Stream.value(testNow)),
    profileProvider.overrideWith(
      (_) => Stream.value(const UserProfile(displayName: 'Juan Dela Cruz')),
    ),
    flowHistoryProvider.overrideWith((_, _) async => history),
    solidGlassProvider.overrideWith((_) => _FixedSolid(solid)),
  ],
  child: MaterialApp(
    theme: buildLightTheme(),
    builder: clampTextScale,
    home: AppBackground(child: home),
  ),
);

class _FixedSolid extends SolidGlassNotifier {
  _FixedSolid(bool v) {
    state = v;
  }
}

/// A 360 dp phone with the OS "Remove animations" setting on, so the endless
/// Live ripple and pipe water stand still and pumpAndSettle can finish.
Future<void> phone(
  WidgetTester t, {
  double textScale = 1.0,
  bool reduceMotion = true,
}) async {
  t.view.physicalSize = const Size(360 * 3, 780 * 3);
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.textScaleFactorTestValue = textScale;
  t.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reduceMotion);
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

List<DeviceView> fleetOf(int n) => [
  for (var i = 0; i < n; i++)
    view(
      'D$i',
      nickname: 'Area number ${i.toString().padLeft(2, '0')} xxxxxxx',
      flowStatus: i % 4 == 0
          ? 'No Flow'
          : (i % 4 == 1 ? 'Low Flow' : 'Normal Flow'),
      abnormalSince: testNow.subtract(const Duration(minutes: 42)),
      online: i % 5 != 4,
      battery: i == 2 ? 15 : 80,
    ),
];

void main() {
  for (final n in [1, 3, 10]) {
    testWidgets('renders $n devices without overflow, problems first', (
      t,
    ) async {
      await phone(t);
      await t.pumpWidget(harness(Stream.value(Fleet(fleetOf(n)))));
      await t.pumpAndSettle();
      expect(find.text('Welcome back, Juan'), findsOneWidget);
      expect(find.byType(DeviceCard, skipOffstage: false), findsNWidgets(n));
      final first = t.widget<DeviceCard>(find.byType(DeviceCard).first);
      expect(first.view.status, StatusKind.noFlow);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('1.5x text at 360 dp wide has no clipping or overflow', (
    t,
  ) async {
    await phone(t, textScale: 1.5);
    await t.pumpWidget(
      harness(
        Stream.value(
          Fleet([
            ...fleetOf(3),
            view('N1', nickname: 'New pump house', registered: false),
          ]),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.drag(find.byType(ListView), const Offset(0, -3000));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('the banner names the worst live problem; the since line shows', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(
          Fleet([
            view('1'),
            view(
              '2',
              nickname: 'Garden Line',
              flowStatus: 'No Flow',
              abnormalSince: testNow.subtract(const Duration(minutes: 6)),
            ),
          ]),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.text('No water on Garden Line · It stopped 6 minutes ago'),
      findsOneWidget,
    );
    expect(find.textContaining('Since 3:06 PM · 6 min'), findsOneWidget);
  });

  testWidgets('no banner when every area is fine', (t) async {
    await phone(t);
    await t.pumpWidget(harness(Stream.value(Fleet([view('1'), view('2')]))));
    await t.pumpAndSettle();
    expect(find.byType(AppBanner), findsNothing);
  });

  testWidgets('Live within 90 s, Late after, Offline replaces both', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(
          Fleet([
            view(
              '1',
              nickname: 'Fresh',
              lastSeen: testNow.subtract(const Duration(seconds: 12)),
            ),
            view(
              '2',
              nickname: 'Slow',
              lastSeen: testNow.subtract(const Duration(minutes: 2)),
            ),
            view('3', nickname: 'Gone', online: false),
          ]),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Late'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('Offline device: "–" L/min, Offline since, sleeping note', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(
          Fleet([
            view(
              '1',
              nickname: 'Garden Line',
              online: false,
              lastSeen: testNow.subtract(const Duration(hours: 1)),
              lowVoltageSleep: true,
            ),
          ]),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Normal'), findsNothing);
    expect(find.text('–'), findsOneWidget);
    expect(find.text('Offline since 2:12 PM'), findsOneWidget);
    expect(find.textContaining('Sleeping to save its battery'), findsOneWidget);
  });

  testWidgets('low battery and battery fault', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(
          Fleet([
            view('1', battery: 15),
            view('2', batteryFault: true, battery: null),
          ]),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('15% low'), findsOneWidget);
    expect(find.text('Battery reading unavailable'), findsOneWidget);
  });

  testWidgets(
    'Not set up yet: Wi-Fi steps in the card, How? opens details (D41)',
    (t) async {
      await phone(t);
      await t.pumpWidget(
        harness(
          Stream.value(
            Fleet([view('1', nickname: 'Pump house', registered: false)]),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Not set up yet'), findsOneWidget);
      expect(find.text('CONNECT IT TO WI-FI'), findsOneWidget);
      expect(find.textContaining('192.168.4.1'), findsNothing);
      await t.tap(find.text('How?'));
      await t.pumpAndSettle();
      expect(find.textContaining('192.168.4.1'), findsOneWidget);
      expect(find.byType(DeviceCard), findsNothing);
    },
  );

  testWidgets('a Not set up yet card turns into live readings by itself', (
    t,
  ) async {
    await phone(t);
    final c = StreamController<Fleet>();
    addTearDown(c.close);
    await t.pumpWidget(harness(c.stream));
    c.add(Fleet([view('1', registered: false)]));
    await t.pumpAndSettle();
    expect(find.byType(NotSetUpCard), findsOneWidget);
    c.add(Fleet([view('1')]));
    await t.pumpAndSettle();
    expect(find.byType(DeviceCard), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
  });

  testWidgets('no devices at all shows the empty state', (t) async {
    await phone(t, textScale: 1.5);
    await t.pumpWidget(harness(Stream.value(const Fleet([]))));
    await t.pumpAndSettle();
    expect(find.text('No devices yet'), findsOneWidget);
    expect(
      find.textContaining('registered to your account before delivery'),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('loading shows skeletons, never a spinner, then the list', (
    t,
  ) async {
    await phone(t);
    final c = StreamController<Fleet>();
    addTearDown(c.close);
    await t.pumpWidget(harness(c.stream));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SkeletonCard), findsWidgets);
    c.add(Fleet([view('1')]));
    await t.pumpAndSettle();
    expect(find.byType(DeviceCard), findsOneWidget);
  });

  testWidgets('stream error shows Try again', (t) async {
    await phone(t);
    await t.pumpWidget(harness(Stream<Fleet>.error(Exception('denied'))));
    await t.pumpAndSettle();
    expect(find.text("Can't load your devices right now."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('phone offline with cached data shows the banner', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(Fleet([view('1')], fromCache: true)),
        phoneOffline: true,
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.text('No internet · Showing the last saved readings'),
      findsOneWidget,
    );
  });

  testWidgets('devices appear and disappear live', (t) async {
    await phone(t);
    final c = StreamController<Fleet>();
    addTearDown(c.close);
    await t.pumpWidget(harness(c.stream));
    c.add(Fleet([view('1'), view('2')]));
    await t.pumpAndSettle();
    expect(find.byType(DeviceCard), findsNWidgets(2));
    c.add(Fleet([view('1'), view('2'), view('3')]));
    await t.pumpAndSettle();
    expect(find.byType(DeviceCard), findsNWidgets(3));
    c.add(Fleet([view('2')]));
    await t.pumpAndSettle();
    expect(find.byType(DeviceCard), findsOneWidget);
  });

  testWidgets('with motion on, the ripple and pipe animate without errors', (
    t,
  ) async {
    await phone(t, reduceMotion: false);
    await t.pumpWidget(
      harness(
        Stream.value(Fleet([view('1')])),
        home: const DeviceDetailScreen(deviceId: '1'),
      ),
    );
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(t.takeException(), isNull);
    expect(t.hasRunningAnimations, isTrue);
  });

  testWidgets('under reduce motion nothing animates on Details', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(Fleet([view('1')])),
        home: const DeviceDetailScreen(deviceId: '1'),
      ),
    );
    await t.pumpAndSettle();
    expect(t.hasRunningAnimations, isFalse);
    expect(find.byType(PipeView), findsOneWidget);
  });

  testWidgets('solid glass: no blur anywhere', (t) async {
    await phone(t);
    await t.pumpWidget(harness(Stream.value(Fleet([view('1')])), solid: true));
    await t.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    // A new ProviderScope keeps its first overrides, so start from an empty tree.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(harness(Stream.value(Fleet([view('1')]))));
    await t.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsWidgets);
  });

  testWidgets('Details: number, pipe, battery trend and the 24 h chart', (
    t,
  ) async {
    await phone(t, textScale: 1.5);
    await t.pumpWidget(
      harness(
        Stream.value(
          Fleet([
            view(
              '1',
              nickname: 'Garden Line',
              flowStatus: 'Low Flow',
              flowRate: 1.4,
              abnormalSince: testNow.subtract(const Duration(minutes: 42)),
            ),
          ]),
        ),
        home: const DeviceDetailScreen(deviceId: '1'),
        history: [
          for (var i = 0; i < 288; i++)
            FlowPoint(
              testNow.subtract(Duration(minutes: 5 * (288 - i))),
              i > 250 ? 'No Flow' : 'Normal Flow',
              i > 250 ? 0 : 6 + (i % 7) * 0.3,
            ),
        ],
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Garden Line'), findsOneWidget);
    expect(find.text('Low flow'), findsOneWidget);
    expect(find.textContaining('Since 2:30 PM · 42 min'), findsOneWidget);
    expect(find.textContaining('Steady'), findsOneWidget);
    expect(find.text('FLOW, LAST 24 HOURS'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Flow over the last 24 hours')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('Details with no history says so', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(Fleet([view('1')])),
        home: const DeviceDetailScreen(deviceId: '1'),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('No readings in the last 24 hours.'), findsOneWidget);
  });
}
