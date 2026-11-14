import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/core/time_format.dart';
import 'package:hydro_sense/data/fleet_logic.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/features/auth/set_password_screen.dart';
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
        const Health(id: 'x'),
      );
      expect(fresh.status, StatusKind.waiting);
    });

    test('banner wording', () {
      expect(
        bannerFor([view('1'), view('2'), view('3')]).text,
        'All 3 areas have normal flow.',
      );
      expect(
        bannerFor([
          view('1'),
          view('2', nickname: 'Garden Line', flowStatus: 'No Flow'),
        ]).text,
        '1 area needs attention: Garden Line (No flow)',
      );
      final two = bannerFor([
        view('1', nickname: 'Kitchen', flowStatus: 'Low Flow'),
        view('2', nickname: 'Garden Line', flowStatus: 'No Flow'),
      ]);
      expect(
        two.text,
        '2 areas need attention, including Garden Line (No flow)',
      );
      expect(two.kind, StatusKind.noFlow);
      expect(
        bannerFor([view('1', online: false), view('2', online: false)]).text,
        'No device is reporting right now.',
      );
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
      bool must = false,
    }) => redirectFor(
      location: loc,
      signedIn: signedIn,
      roleLoaded: roleLoaded,
      role: role,
      profileLoaded: profileLoaded,
      mustChangePassword: must,
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

    test('a temporary password forces Set a new password first', () {
      expect(go('/devices', must: true), '/set-password');
      expect(go('/map', must: true), '/set-password');
      expect(go('/set-password', must: true), isNull);
      expect(go('/set-password'), '/devices');
    });

    test('waits for the role and profile before deciding', () {
      expect(go('/devices', roleLoaded: false), '/loading');
      expect(go('/devices', profileLoaded: false), '/loading');
      expect(go('/loading'), '/devices');
      expect(go('/devices/ABC'), isNull);
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

    test('signal words from RSSI', () {
      expect(signalOf(-55).word, 'Strong');
      expect(signalOf(-75).bars, 2);
      expect(signalOf(-90).word, 'Weak');
    });
  });
}
