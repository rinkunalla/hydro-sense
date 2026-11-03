// Devices screen states (KICKOFF.md Phase 5), rendered with fake data: 1, 3 and 10
// devices, Offline, first run, loading, error, phone offline, and 1.5x text at 360 dp.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/app.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/features/client/devices_screen.dart';

import 'test_data.dart';

Widget harness(
  Stream<Fleet> fleet, {
  bool phoneOffline = false,
  Summary? summary,
}) => ProviderScope(
  overrides: [
    fleetProvider.overrideWith((_) => fleet),
    summaryProvider.overrideWith((_) => Stream.value(summary)),
    phoneOfflineProvider.overrideWith((_) => Stream.value(phoneOffline)),
    clockProvider.overrideWith((_) => Stream.value(testNow)),
  ],
  child: MaterialApp(
    theme: buildLightTheme(),
    builder: clampTextScale,
    home: const DevicesScreen(),
  ),
);

Future<void> phone(WidgetTester t, {double textScale = 1.0}) async {
  t.view.physicalSize = const Size(360 * 3, 780 * 3);
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

List<DeviceView> fleetOf(int n) => [
  for (var i = 0; i < n; i++)
    view(
      'D$i',
      nickname: 'Area number ${i.toString().padLeft(2, '0')} xxxxxxx',
      flowStatus: i % 4 == 0
          ? 'No Flow'
          : (i % 4 == 1 ? 'Low Flow' : 'Normal Flow'),
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
      expect(find.text('Water flow summary'), findsOneWidget);
      expect(find.byType(DeviceCard, skipOffstage: false), findsNWidgets(n));
      final first = t.widget<DeviceCard>(find.byType(DeviceCard).first);
      expect(first.view.status, StatusKind.noFlow);
    });
  }

  testWidgets('1.5x text at 360 dp wide has no clipping or overflow', (
    t,
  ) async {
    await phone(t, textScale: 1.5);
    await t.pumpWidget(harness(Stream.value(Fleet(fleetOf(3)))));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.drag(find.byType(ListView), const Offset(0, -2000));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('Offline device shows Offline, "-" L/min and Last seen', (
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
              flowStatus: 'Normal Flow',
              online: false,
              lowVoltageSleep: true,
            ),
          ]),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Normal'), findsNothing);
    expect(find.textContaining('Last seen'), findsOneWidget);
    expect(find.textContaining('Sleeping to save its battery'), findsOneWidget);
    expect(find.textContaining('No device is reporting'), findsOneWidget);
  });

  testWidgets('low battery, battery fault and paused alerts', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(
          Fleet([
            view('1', battery: 15),
            view('2', batteryFault: true, battery: null),
            view('3', pausedUntil: testNow.add(const Duration(hours: 1))),
          ]),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('15% Low battery'), findsOneWidget);
    expect(find.text('Battery reading unavailable'), findsOneWidget);
    expect(find.text('Alerts paused'), findsOneWidget);
  });

  testWidgets('first run shows the three setup steps', (t) async {
    await phone(t, textScale: 1.5);
    await t.pumpWidget(harness(Stream.value(const Fleet([]))));
    await t.pumpAndSettle();
    expect(find.text('No devices yet.'), findsOneWidget);
    expect(find.textContaining('HydroSense-XXXX'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('loading shows skeletons, then the list', (t) async {
    await phone(t);
    final c = StreamController<Fleet>();
    addTearDown(c.close);
    await t.pumpWidget(harness(c.stream));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(DeviceCard), findsNothing);
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

  testWidgets('phone offline with cached data shows the offline banner', (
    t,
  ) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(Fleet([view('1')], fromCache: true)),
        phoneOffline: true,
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('You are offline'), findsOneWidget);
    expect(find.textContaining('(may be outdated)'), findsOneWidget);
  });

  testWidgets('stale summary shows "May be out of date"', (t) async {
    await phone(t);
    await t.pumpWidget(
      harness(
        Stream.value(Fleet([view('1', statusChangedAt: testNow)])),
        summary: Summary(
          text: 'All good.',
          lastUpdated: testNow.subtract(const Duration(minutes: 5)),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('All good.'), findsOneWidget);
    expect(find.text('May be out of date'), findsOneWidget);
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
}
