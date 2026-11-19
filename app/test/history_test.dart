// History (D49), the Devices filters, the website filters and the map tile
// cache rules: pure logic, plus the History screen with fake data.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:hydro_sense/core/glass.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/admin_logic.dart';
import 'package:hydro_sense/data/admin_repository.dart';
import 'package:hydro_sense/data/fleet_logic.dart';
import 'package:hydro_sense/data/history_logic.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/features/client/history_providers.dart';
import 'package:hydro_sense/features/client/history_screen.dart';
import 'package:hydro_sense/features/client/live_trend.dart';
import 'package:hydro_sense/features/client/tile_cache.dart';
import 'package:hydro_sense/features/client/widgets.dart'
    show rotorTurnsPerSecond;

import 'test_data.dart';

Problem problem(
  String id,
  ProblemType type,
  DateTime start, [
  DateTime? end,
  String device = '1',
]) => Problem(
  id: id,
  deviceId: device,
  type: type,
  startedAt: start,
  endedAt: end,
);

DateTime h(int hours) => testNow.subtract(Duration(hours: hours));

void main() {
  group('status strip', () {
    test('no problems: one Normal stretch', () {
      final s = statusStrip(
        const [],
        h(24),
        testNow,
        testNow,
        knownFrom: h(72),
      );
      expect(s, [StripSegment(StripKind.normal, h(24), testNow)]);
    });

    test('problems cut the day; Offline wins over a flow problem', () {
      final s = statusStrip(
        [
          problem('a', ProblemType.noFlow, h(6), h(3)),
          problem('b', ProblemType.offline, h(5), h(4)),
          problem('c', ProblemType.lowFlow, h(1)), // ongoing
          problem('d', ProblemType.batteryLow, h(10), h(9)), // not on the strip
        ],
        h(24),
        testNow,
        testNow,
        knownFrom: h(72),
      );
      expect(s.map((x) => x.kind).toList(), [
        StripKind.normal,
        StripKind.noFlow,
        StripKind.offline,
        StripKind.noFlow,
        StripKind.normal,
        StripKind.lowFlow,
      ]);
      expect(s.last.to, testNow);
    });

    test('time before the device registered is unknown', () {
      final s = statusStrip(const [], h(24), testNow, testNow, knownFrom: h(2));
      expect(s, [
        StripSegment(StripKind.unknown, h(24), h(2)),
        StripSegment(StripKind.normal, h(2), testNow),
      ]);
    });
  });

  group('calendar', () {
    final nov = DateTime(2026, 11);
    final list = [
      problem(
        'a',
        ProblemType.noFlow,
        DateTime(2026, 11, 2, 6, 10),
        DateTime(2026, 11, 2, 7, 2),
      ),
      problem(
        'b',
        ProblemType.offline,
        DateTime(2026, 11, 2, 23),
        DateTime(2026, 11, 3, 1),
      ),
    ];

    test(
      'dots per type, a green dot on a clean known day, nothing unknown',
      () {
        final m = monthMarks(
          nov,
          list,
          testNow,
          knownFrom: DateTime(2026, 10, 31),
        );
        expect(m[DateTime(2026, 11, 2)]!.types, {
          ProblemType.noFlow,
          ProblemType.offline,
        });
        expect(m[DateTime(2026, 11, 3)]!.types, {ProblemType.offline});
        expect(m[DateTime(2026, 11, 1)]!.clean, isTrue);
        expect(m[DateTime(2026, 11, 4)]!.clean, isFalse); // the future
        final early = monthMarks(
          nov,
          const [],
          testNow,
          knownFrom: DateTime(2026, 11, 2, 12),
        );
        expect(early[DateTime(2026, 11, 1)]!.clean, isFalse); // before setup
        expect(early[DateTime(2026, 11, 2)]!.clean, isTrue);
      },
    );

    test('month summary counts problems and time without water', () {
      final s = monthSummary(nov, list, testNow);
      expect(s.count, 2);
      expect(s.noWater, const Duration(minutes: 52));
      expect(durationText(const Duration(minutes: 130)), '2 h 10 min');
      expect(durationText(const Duration(seconds: 20)), 'under 1 min');
    });

    test('filters by device, type and state', () {
      final open = problem('c', ProblemType.lowFlow, h(1), null, '2');
      final all = [...list, open];
      expect(all.where(const HistoryFilter().keeps), hasLength(3));
      expect(
        all.where(const HistoryFilter(deviceIds: {'2'}).keeps).single.id,
        'c',
      );
      expect(
        all
            .where(const HistoryFilter(types: {ProblemType.offline}).keeps)
            .single
            .id,
        'b',
      );
      expect(
        all
            .where(const HistoryFilter(state: ProblemState.ongoing).keeps)
            .single
            .id,
        'c',
      );
      expect(
        all.where(const HistoryFilter(state: ProblemState.resolved).keeps),
        hasLength(2),
      );
    });
  });

  group('filters elsewhere', () {
    test('Devices: pills and nickname search', () {
      final views = [
        view('1', nickname: 'Garden'),
        view('2', nickname: 'Tank', flowStatus: 'No Flow'),
        view('3', nickname: 'North', online: false),
        view('4', nickname: 'Shed', registered: false),
        view('5', nickname: 'Barn', battery: 10),
      ];
      List<String> ids(DeviceFilter f, [String q = '']) =>
          filterDevices(views, f, q).map((v) => v.id).toList();
      expect(ids(DeviceFilter.problems), ['2', '5']);
      expect(ids(DeviceFilter.offline), ['3']);
      expect(ids(DeviceFilter.notSetUp), ['4']);
      expect(ids(DeviceFilter.all, 'gar'), ['1']);
    });

    test('website: users by pill and by name, mobile or email', () {
      const a = AdminUser(
        uid: 'a',
        name: 'Juan Dela Cruz',
        email: 'juan@example.com',
        phone: '639171234567',
        passwordSet: true,
      );
      const b = AdminUser(
        uid: 'b',
        name: 'Ana',
        email: 'ana@example.com',
        phone: '639180000000',
      );
      expect(userMatches(a, UserFilter.all, 'dela'), isTrue);
      expect(userMatches(a, UserFilter.all, '0917 123'), isTrue);
      expect(userMatches(a, UserFilter.all, 'ana@'), isFalse);
      expect(userMatches(b, UserFilter.noPassword, ''), isTrue);
      expect(userMatches(a, UserFilter.noPassword, ''), isFalse);
    });

    test(
      'website: devices by ID, label or owner; activity by group and admin',
      () {
        const d = AdminDevice(
          id: 'A4F00F6936B0',
          label: 'Unit 1',
          ownerName: 'Juan',
        );
        expect(deviceMatches(d, 'a4:f0'), isTrue);
        expect(deviceMatches(d, 'unit1'), isTrue);
        expect(deviceMatches(d, 'juan'), isTrue);
        expect(deviceMatches(d, 'ana'), isFalse);
        const e = AuditEntry(
          id: '1',
          action: 'device_removed',
          adminEmail: 'x@a.b',
        );
        expect(auditMatches(e, AuditGroup.devices, null), isTrue);
        expect(auditMatches(e, AuditGroup.users, null), isFalse);
        expect(auditMatches(e, AuditGroup.all, 'y@a.b'), isFalse);
      },
    );
  });

  group('Offline on the server clock (D51)', () {
    test('two missed heartbeats, at least 60 s; 180 s without a heartbeat', () {
      expect(offlineAfterS(30), 60);
      expect(offlineAfterS(15), 40);
      expect(offlineAfterS(null), 180);
    });

    test('measured from the server clock, not the phone', () {
      final seen = testNow.subtract(const Duration(seconds: 59));
      expect(silentTooLong(seen, 30, testNow), isFalse);
      expect(
        silentTooLong(seen, 30, testNow.add(const Duration(seconds: 1))),
        isTrue,
      );
      expect(silentTooLong(null, 30, testNow), isFalse);
    });
  });

  group('Activity date dropdowns (D53)', () {
    test('a year, a month or a single day', () {
      expect(calendarWindow(2026, null, null), (
        from: DateTime(2026),
        to: DateTime(2027),
      ));
      expect(calendarWindow(2026, 11, null), (
        from: DateTime(2026, 11),
        to: DateTime(2026, 12),
      ));
      expect(calendarWindow(2026, 12, 31), (
        from: DateTime(2026, 12, 31),
        to: DateTime(2027),
      ));
      expect(daysInMonth(2028, 2), 29);
      expect(daysInMonth(2026, 2), 28);
    });
  });

  test('the rotor spins faster with more flow and stops without it (D57)', () {
    expect(rotorTurnsPerSecond(null), 0);
    expect(rotorTurnsPerSecond(0), 0);
    expect(rotorTurnsPerSecond(0.5), 0.4); // slowest visible spin
    expect(rotorTurnsPerSecond(8), 2.0);
    expect(rotorTurnsPerSecond(40), 3.0); // capped
  });

  group('card chart (D61)', () {
    test('the left scale uses round steps', () {
      expect(niceStep(4.8), 5); // 0, 5, 10, 15, 20
      expect(niceStep(2.1), 2.5);
      expect(niceStep(0.3), 0.5);
      expect(niceStep(12), 20);
      expect(niceStep(1), 1);
    });

    test('rising, falling or steady from the last few points', () {
      expect(trendOf([5, 5.1, 5.2, 6]), Trend.rising);
      expect(trendOf([8, 7.5, 7, 6]), Trend.falling);
      expect(trendOf([8, 8.1, 7.95, 8.05]), Trend.steady); // within 0.2
      expect(trendOf([8]), Trend.steady);
    });

    test('a point a minute up to 2 h; 10-minute averages for 24 h', () {
      final byMinute = {for (var m = -30; m < 600; m++) m: m < 0 ? 2.0 : 6.0};
      final hour = trendPoints(byMinute, 600, TrendRange.hour);
      expect(hour, hasLength(60));
      expect(hour.first, (60, 6.0, true));
      final day = trendPoints(byMinute, 600, TrendRange.day);
      // Every 10-minute step of the 24 h, with or without readings.
      expect(day, hasLength(144));
      expect(day.first, (1440, 0.0, false)); // no reading: grey at 0
      // Yesterday's minutes count in the 24 h view.
      expect(day.firstWhere((p) => p.$3).$2, 2.0);
      expect(TrendRange.day.bucket, 10);
      expect(TrendRange.twoHours.bucket, 1);
    });

    test('the line never breaks: gaps sit at 0, one-minute gaps bridge', () {
      // Readings at minutes 0 to 9, none at 10 to 19, then 20 to 59.
      final byMinute = {
        for (var m = 0; m < 60; m++)
          if (m < 10 || m >= 20) m: 5.0,
      };
      final hour = trendPoints(byMinute, 60, TrendRange.hour);
      expect(hour, hasLength(60));
      (int, double, bool) at(int minute) => hour[minute];
      expect(at(10), (50, 5.0, true)); // 1st missing minute: bridged
      expect(at(11), (49, 5.0, true)); // 2nd: still bridged
      expect(at(12), (48, 0.0, false)); // then it is a gap: grey at 0
      expect(at(19), (41, 0.0, false));
      expect(at(20), (40, 5.0, true));
      // A reading just before the window carries in: no drop to 0 at the
      // left edge (minute 59 had 3 L/min, the window starts at minute 60).
      final edge = trendPoints({59: 3.0, 62: 3.0}, 120, TrendRange.hour);
      expect(edge.first, (60, 3.0, true));
      expect(edge[1], (59, 3.0, true));
      // A device that never sent: the whole range is grey at 0.
      expect(
        trendPoints(const {}, 60, TrendRange.hour).every((p) => !p.$3),
        isTrue,
      );
    });
  });

  group('map tile cache', () {
    test(
      'keeps a tile for its max-age, never over 24 h, never on no-store',
      () {
        expect(
          TileCacheClient.keepSeconds(
            'private, max-age=86400, must-revalidate',
          ),
          86400,
        );
        expect(TileCacheClient.keepSeconds('max-age=999999'), 86400);
        expect(TileCacheClient.keepSeconds('max-age=60'), 60);
        expect(TileCacheClient.keepSeconds('no-store, max-age=60'), 0);
        expect(TileCacheClient.keepSeconds(null), 0);
      },
    );

    test(
      'road map and satellite never share a cached tile; the key is ignored',
      () {
        final road = Uri.parse(
          'https://tile.googleapis.com/v1/2dtiles/15/1/2?session=ROAD&key=K1',
        );
        final roadNewKey = Uri.parse(
          'https://tile.googleapis.com/v1/2dtiles/15/1/2?session=ROAD&key=K2',
        );
        final satellite = Uri.parse(
          'https://tile.googleapis.com/v1/2dtiles/15/1/2?session=SAT&key=K1',
        );
        expect(TileCacheClient.keyOf(road), TileCacheClient.keyOf(roadNewKey));
        expect(
          TileCacheClient.keyOf(road),
          isNot(TileCacheClient.keyOf(satellite)),
        );
      },
    );
  });

  testWidgets(
    'History: the day list, filters, and no delete for an ongoing problem',
    (t) async {
      t.view.physicalSize = const Size(360 * 3, 1600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final problems = [
        problem(
          'p1',
          ProblemType.noFlow,
          today.add(const Duration(minutes: 1)),
          today.add(const Duration(minutes: 53)),
        ),
        problem(
          'p2',
          ProblemType.offline,
          today.add(const Duration(minutes: 2)),
        ),
      ];
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            fleetProvider.overrideWith(
              (_) => Stream.value(Fleet([view('1', nickname: 'Garden Line')])),
            ),
            clockProvider.overrideWith((_) => Stream.value(now)),
            monthProblemsProvider.overrideWith(
              (_, _) => Stream.value(problems),
            ),
            todaySeriesProvider.overrideWith(
              (_, _) => Stream.value({for (var m = 600; m < 660; m++) m: 12.0}),
            ),
            dayReadingsProvider.overrideWith(
              (_, _) async => {for (var i = 0; i < 40; i++) i: 6.0 + i % 3},
            ),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const AppBackground(child: HistoryScreen()),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('No water · Garden Line'), findsOneWidget);
      expect(find.text('Offline · Garden Line'), findsOneWidget);
      expect(find.textContaining('(52 min)'), findsOneWidget);
      expect(find.text('2 problems · 52 min without water'), findsOneWidget);
      expect(find.text('Flow · Garden Line'), findsOneWidget);
      // The date dropdowns show today (D53).
      expect(
        find.text(DateFormat('MMMM', 'en_US').format(now)),
        findsOneWidget,
      );
      expect(find.text('${now.year}'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp('Flow this day: average .* 100 of 1440 readings'),
        ),
        findsOneWidget,
      );

      // Type filter: only Offline.
      await t.tap(find.widgetWithText(FilterChip, 'Offline'));
      await t.pumpAndSettle();
      expect(find.text('No water · Garden Line'), findsNothing);

      // An ongoing problem offers a note but no Delete.
      await t.tap(find.text('Offline · Garden Line'));
      await t.pumpAndSettle();
      expect(find.text('Save note'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
      expect(find.textContaining("can't be deleted yet"), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
