import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/core/time_format.dart';
import 'package:hydro_sense/data/fleet_logic.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/push.dart';
import 'package:hydro_sense/features/auth/code_entry.dart';
import 'package:hydro_sense/features/auth/password_rules.dart';
import 'package:hydro_sense/features/client/device_detail_screen.dart';
import 'package:hydro_sense/router.dart';

import 'test_data.dart';

void main() {
  group('fleet logic', () {
    test('sorts No Flow, Low Flow, Offline, Normal; ties by nickname', () {
      final sorted = sortForHome([
        view('1', nickname: 'Orchard'),
        view('2', nickname: 'Kitchen', online: false),
        view('3', nickname: 'Barn', flowStatus: 'Low Flow'),
        view('4', nickname: 'Garden Line', flowStatus: 'No Flow'),
        view('5', nickname: 'Apple'),
      ]);
      expect(sorted.map((v) => v.nickname), [
        'Garden Line',
        'Barn',
        'Kitchen',
        'Apple',
        'Orchard',
      ]);
    });

    test('Offline replaces the stale flow status', () {
      expect(
        view('1', flowStatus: 'Normal Flow', online: false).status,
        StatusKind.offline,
      );
      expect(view('1', flowStatus: null).status, StatusKind.waiting);
      // Registered but never reported (lastSeen null) is waiting, not offline.
      final fresh = DeviceView(
        const Device(id: 'x', nickname: 'X'),
        Health(id: 'x', registeredAt: testNow),
      );
      expect(fresh.status, StatusKind.waiting);
    });

    test(
      'a device assigned before it ever registered is Not set up yet (D41)',
      () {
        expect(view('1', registered: false).status, StatusKind.notSetUp);
        expect(
          const DeviceView(Device(id: 'x', nickname: 'X'), null).status,
          StatusKind.notSetUp,
        );
        expect(
          view('1', registered: false).freshnessAt(testNow),
          Freshness.none,
        );
      },
    );

    test('the banner shows only a live problem, worst first (4.1)', () {
      expect(problemBanner([view('1'), view('2')], testNow), isNull);
      final one = problemBanner([
        view('1'),
        view(
          '2',
          nickname: 'Garden Line',
          flowStatus: 'No Flow',
          abnormalSince: testNow.subtract(const Duration(minutes: 6)),
        ),
      ], testNow)!;
      expect(one.text, 'No water on Garden Line · It stopped 6 minutes ago');
      expect(one.kind, StatusKind.noFlow);
      final three = problemBanner([
        view('1', nickname: 'Kitchen', flowStatus: 'Low Flow'),
        view('2', nickname: 'Garden Line', flowStatus: 'No Flow'),
        view('3', nickname: 'Orchard', flowStatus: 'Low Flow'),
      ], testNow)!;
      expect(three.text, 'No water on Garden Line · +2 more');
      expect(
        problemBanner([
          view(
            '1',
            nickname: 'Kitchen',
            flowStatus: 'Low Flow',
            abnormalSince: testNow.subtract(const Duration(hours: 1)),
          ),
        ], testNow)!.text,
        'Low water flow on Kitchen · It started 1 hour ago',
      );
    });

    test(
      'since line: abnormalSince for problems, lastSeen when Offline (D34)',
      () {
        final start = testNow.subtract(const Duration(minutes: 42));
        expect(
          view('1', flowStatus: 'No Flow', abnormalSince: start).since,
          start,
        );
        final seen = testNow.subtract(const Duration(hours: 1));
        expect(view('1', online: false, lastSeen: seen).since, seen);
        expect(
          view('1', abnormalSince: start).since,
          isNull,
        ); // Normal: no line
      },
    );

    test('Live within 90 s, then Late, Offline only from the server (D35)', () {
      DeviceView at(int s) =>
          view('1', lastSeen: testNow.subtract(Duration(seconds: s)));
      expect(at(90).freshnessAt(testNow), Freshness.live);
      expect(at(91).freshnessAt(testNow), Freshness.late);
      expect(
        at(-30).freshnessAt(testNow),
        Freshness.live,
      ); // server clock ahead
      expect(view('1', online: false).freshnessAt(testNow), Freshness.offline);
    });

    test('a saved token with an unknown or old role is refreshed first', () {
      expect(needsFreshRole('user'), isFalse);
      expect(needsFreshRole('admin'), isFalse);
      expect(needsFreshRole('client'), isTrue); // v1 role, before the migration
      expect(needsFreshRole(null), isTrue);
    });

    test('a tapped push opens Details, the Map, or Devices (D37)', () {
      expect(
        routeForPush({'deviceId': 'A1B2C3D4E5F6'}, hasPipeline: true),
        '/devices/A1B2C3D4E5F6',
      );
      expect(
        routeForPush({'kind': 'batch'}, hasPipeline: true),
        '/map?focus=problem',
      );
      expect(routeForPush({'kind': 'batch'}, hasPipeline: false), '/devices');
      expect(
        routeForPush({'deviceId': '../account'}, hasPipeline: false),
        '/devices',
      );
    });

    test('code wording and timers (5.2)', () {
      expect(mmss(272), '4:32');
      expect(mmss(-3), '0:00');
      expect(
        codeErrorText('RESET_CODE_INVALID', 3),
        'That code is not right. 3 tries left.',
      );
      expect(
        codeErrorText('RESET_CODE_INVALID', 1),
        'That code is not right. 1 try left.',
      );
      expect(
        codeErrorText('RESET_LOCKED', null),
        'Too many wrong codes. Send a new one.',
      );
      expect(maskedPhone('639171234567'), '0917 ••• 4567');
      expect(displayPhone('639171234567'), '0917 123 4567');
    });

    test('announces only cards that newly entered No Flow', () {
      final before = [
        view('1', nickname: 'A'),
        view('2', nickname: 'B', flowStatus: 'No Flow'),
      ];
      final after = [
        view('1', nickname: 'A', flowStatus: 'No Flow'),
        view('2', nickname: 'B', flowStatus: 'No Flow'),
      ];
      expect(newlyNoFlow(before, after), ['A, no flow']);
    });
  });

  group('time format', () {
    test('relative ages, with "just now" for clock skew', () {
      expect(
        relativeAge(testNow.subtract(const Duration(seconds: 12)), testNow),
        '12 s ago',
      );
      expect(
        relativeAge(testNow.subtract(const Duration(minutes: 4)), testNow),
        '4 min ago',
      );
      expect(
        relativeAge(testNow.add(const Duration(seconds: 3)), testNow),
        'just now',
      );
    });

    test('clock time adds the date when not today', () {
      expect(clockTime(DateTime(2026, 11, 3, 15, 12), testNow), '3:12 PM');
      expect(
        clockTime(DateTime(2026, 11, 2, 15, 12), testNow),
        'Nov 2, 3:12 PM',
      );
    });

    test('cooldown wording', () {
      expect(waitText(const Duration(minutes: 8, seconds: 10)), '9 min');
      expect(waitText(const Duration(minutes: 42)), '42 min');
    });
  });

  group('router redirects', () {
    String? go(
      String loc, {
      bool signedIn = true,
      bool roleLoaded = true,
      String? role = 'user',
      bool profileLoaded = true,
    }) => redirectFor(
      location: loc,
      signedIn: signedIn,
      roleLoaded: roleLoaded,
      role: role,
      profileLoaded: profileLoaded,
    );

    test('signed out goes to Login, except Reset', () {
      expect(go('/devices', signedIn: false), '/login');
      expect(go('/reset', signedIn: false), isNull);
    });

    test('an admin on the phone app is refused', () {
      expect(go('/devices', role: 'admin'), '/login?refused=admin');
      expect(go('/devices', role: null), '/login?refused=other');
      expect(go('/login?refused=admin', role: 'admin'), isNull);
    });

    test('waits for the role and profile before deciding', () {
      expect(go('/devices', roleLoaded: false), '/loading');
      expect(go('/devices', profileLoaded: false), '/loading');
      expect(go('/loading'), '/devices');
      expect(go('/devices/ABC'), isNull);
    });

    test('a screen asked for while signed out opens after sign-in (D45)', () {
      // A tapped alert after the app signed out on start.
      expect(
        go('/devices/ABC', signedIn: false),
        '/login?next=%2Fdevices%2FABC',
      );
      expect(go('/login?next=%2Fdevices%2FABC', signedIn: false), isNull);
      // The way through Loading keeps it.
      expect(
        go('/login?next=%2Fdevices%2FABC', roleLoaded: false),
        '/loading?next=%2Fdevices%2FABC',
      );
      expect(go('/loading?next=%2Fdevices%2FABC'), '/devices/ABC');
      expect(go('/login?next=%2Fmap%3Ffocus%3Dproblem'), '/map?focus=problem');
      // Only screens inside the app; anything else goes home.
      expect(go('/login?next=%2F%2Fevil.com'), '/devices');
      expect(go('/login?next=https%3A%2F%2Fevil.com'), '/devices');
      expect(go('/login?next=%2Flogin'), '/devices');
    });
  });

  group('form rules', () {
    test('nickname 1 to 24 characters after trimming', () {
      expect(validateNickname('   '), "Name can't be empty.");
      expect(validateNickname(' Kitchen '), isNull);
      expect(validateNickname('x' * 24), isNull);
      expect(validateNickname('x' * 25), isNotNull);
    });

    test('new password at least 8 characters and repeated', () {
      expect(validateNewPassword('short', 'short'), isNotNull);
      expect(
        validateNewPassword('longenough', 'different'),
        "Passwords don't match.",
      );
      expect(validateNewPassword('longenough', 'longenough'), isNull);
    });
  });
}
