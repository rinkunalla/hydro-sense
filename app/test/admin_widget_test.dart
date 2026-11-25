// Admin website (v3) with fake admin and device repositories.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydro_sense/core/glass.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/admin_providers.dart';
import 'package:hydro_sense/data/admin_repository.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/pipeline.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/repository.dart';
import 'package:hydro_sense/features/admin/admin_account_screen.dart';
import 'package:hydro_sense/features/admin/admin_setup_screen.dart';
import 'package:hydro_sense/features/admin/admin_shell.dart';
import 'package:hydro_sense/features/admin/dashboard_screen.dart';
import 'package:hydro_sense/features/admin/staff_screen.dart';
import 'package:hydro_sense/router.dart';

import 'test_data.dart';

final now = DateTime.now();

FirebaseFunctionsException fail(String code) => FirebaseFunctionsException(
  code: 'failed-precondition',
  message: code,
  details: {'code': code},
);

class FakeAdmin implements AdminRepository {
  List<StaffMember> staffList = [];
  List<AdminInfo> adminList = [];
  bool belowRecommended = false;
  Object? nextError;
  final calls = <String>[];

  Future<void> _rec(String c) async {
    calls.add(c);
    final e = nextError;
    nextError = null;
    if (e != null) throw e;
  }

  @override
  Future<List<StaffMember>> staff() async => staffList;
  @override
  Future<String> createStaff({
    required String name,
    required String username,
    required String password,
    String? mobile,
    String? email,
  }) async {
    await _rec('create $name $username ${mobile ?? '-'} ${email ?? '-'}');
    return 'new';
  }

  @override
  Future<void> updateStaff(
    String uid, {
    String? name,
    String? username,
    String? mobile,
    String? email,
    bool? disabled,
  }) => _rec(
    disabled != null
        ? 'disable $uid $disabled'
        : 'update $uid $name $username "$mobile" "$email"',
  );
  @override
  Future<void> resetStaffPassword(String uid, String password) =>
      _rec('password $uid $password');
  @override
  Future<void> deleteStaff(String uid, {required String confirmName}) =>
      _rec('delete $uid $confirmName');
  @override
  Future<void> addDevice(String deviceId, {String? name, SensorType? sensor}) =>
      _rec('add $deviceId $name ${sensor?.wire}');
  @override
  Future<void> removeDevice(String deviceId, {required String confirmName}) =>
      _rec('remove $deviceId $confirmName');
  @override
  Future<({List<AdminInfo> admins, bool belowRecommended})> admins() async =>
      (admins: adminList, belowRecommended: belowRecommended);
  @override
  Future<void> removeAdmin(String uid) => _rec('removeAdmin $uid');
  @override
  Future<void> updateMyAdminName(String name) => _rec('name $name');
  @override
  Future<void> updateMyAdminMobile(String mobile) => _rec('mobile $mobile');
  @override
  Future<void> syncMyAdmin() => _rec('sync');
  @override
  Future<void> signOutEverywhere() => _rec('signOutEverywhere');
  @override
  Future<void> requestAdminSetup(String email) => _rec('setupLink $email');
  @override
  Future<String> completeAdminSetup(String token, String password) async {
    await _rec('complete $token');
    return 'a@x.ph';
  }
}

/// Every device the admin sees, from a fixed list.
class FakeFleet implements ClientRepository {
  FakeFleet(this.views);

  final List<DeviceView> views;

  @override
  Stream<Fleet> fleet() => Stream.value(Fleet(views));

  @override
  Stream<Pipeline?> pipeline() => Stream.value(null);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<void> pumpAdmin(
  WidgetTester t,
  FakeAdmin fake,
  Widget screen, {
  Size size = const Size(1280, 900),
  List<DeviceView> devices = const [],
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        adminRepositoryProvider.overrideWithValue(fake),
        repositoryProvider.overrideWithValue(FakeFleet(devices)),
        // A signed-in admin, so the shared screens show the admin controls.
        uidProvider.overrideWithValue('admin1'),
        roleProvider.overrideWith((_) async => 'admin'),
        userProvider.overrideWith((_) => const Stream.empty()),
        clockProvider.overrideWith((_) => Stream.value(testNow)),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await t.pumpAndSettle();
}

const ana = StaffMember(
  uid: 'u1',
  name: 'Ana Cruz',
  username: 'ana',
  phone: '639171234567',
);
const ben = StaffMember(
  uid: 'u2',
  name: 'Ben Reyes',
  username: 'ben',
  disabled: true,
);

void main() {
  group('Shell, menu and banner', () {
    testWidgets(
      'five menu items on wide screens, a menu under 800 px; syncs once',
      (t) async {
        final fake = FakeAdmin();
        Widget shell() =>
            const AdminShell(location: '/dashboard', child: SizedBox());
        await pumpAdmin(t, fake, shell());
        for (final label in [
          'Dashboard',
          'Devices',
          'History',
          'Staff',
          'Account',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        // The map is the Dashboard (2026-11-25); no Activity since v3.
        expect(find.text('Map'), findsNothing);
        expect(find.text('Activity'), findsNothing);
        expect(fake.calls, contains('sync'));
        await pumpAdmin(t, fake, shell(), size: const Size(700, 900));
        expect(find.byTooltip('Menu'), findsOneWidget);
        expect(find.text('Staff'), findsNothing);
      },
    );

    testWidgets('the banner names what needs attention, worst first (D65)', (
      t,
    ) async {
      await pumpAdmin(
        t,
        FakeAdmin(),
        const AdminShell(location: '/staff', child: SizedBox()),
        devices: [
          view('D1', nickname: 'Tank'),
          view('D2', nickname: 'Garden', flowStatus: 'Low Flow'),
          view('D3', nickname: 'Main', flowStatus: 'No Flow'),
        ],
      );
      expect(
        find.textContaining('2 areas need attention: Main'),
        findsOneWidget,
      );
      // No button: the banner itself is the link.
      expect(find.text('Open Dashboard'), findsNothing);
    });

    testWidgets('tapping the banner opens the device, or the map for several', (
      t,
    ) async {
      Future<String> tapBannerWith(List<DeviceView> devices) async {
        final router = GoRouter(
          initialLocation: '/staff',
          routes: [
            ShellRoute(
              builder: (_, s, child) =>
                  AdminShell(location: s.uri.path, child: child),
              routes: [
                GoRoute(path: '/staff', builder: (_, _) => const SizedBox()),
                GoRoute(
                  path: '/dashboard',
                  builder: (_, s) => Text('dashboard ${s.uri.query}'),
                ),
                GoRoute(
                  path: '/devices/:id',
                  builder: (_, s) => Text('device ${s.pathParameters['id']}'),
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        t.view.physicalSize = const Size(1280, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(const SizedBox());
        await t.pumpWidget(
          ProviderScope(
            overrides: [
              adminRepositoryProvider.overrideWithValue(FakeAdmin()),
              repositoryProvider.overrideWithValue(FakeFleet(devices)),
              uidProvider.overrideWithValue('admin1'),
              roleProvider.overrideWith((_) async => 'admin'),
              userProvider.overrideWith((_) => const Stream.empty()),
              clockProvider.overrideWith((_) => Stream.value(testNow)),
            ],
            child: MaterialApp.router(
              theme: buildLightTheme(),
              routerConfig: router,
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.textContaining('need'));
        await t.pumpAndSettle();
        return router.routerDelegate.currentConfiguration.uri.toString();
      }

      expect(
        await tapBannerWith([
          view('D3', nickname: 'Main', flowStatus: 'No Flow'),
        ]),
        '/devices/D3',
      );
      expect(find.text('device D3'), findsOneWidget);
      expect(
        await tapBannerWith([
          view('D2', nickname: 'Garden', flowStatus: 'Low Flow'),
          view('D3', nickname: 'Main', flowStatus: 'No Flow'),
        ]),
        '/dashboard?focus=problem',
      );
      // The Dashboard lists them beside its map, so no banner there.
      expect(find.textContaining('need attention'), findsNothing);
    });

    testWidgets('no banner while every device is fine', (t) async {
      await pumpAdmin(
        t,
        FakeAdmin(),
        const AdminShell(location: '/staff', child: SizedBox()),
        devices: [view('D1')],
      );
      expect(find.textContaining('need attention'), findsNothing);
    });
  });

  group('Dashboard', () {
    testWidgets('counts and the devices that need attention', (t) async {
      await pumpAdmin(
        t,
        FakeAdmin(),
        const DashboardScreen(),
        devices: [
          view('D1', nickname: 'Tank'),
          view('D2', nickname: 'Main', flowStatus: 'No Flow'),
          view('D3', nickname: 'Shed', online: false),
        ],
      );
      expect(find.text('Needs attention now'), findsOneWidget);
      expect(find.text('Main'), findsOneWidget);
      expect(find.text('Shed'), findsOneWidget);
      expect(find.text('Tank'), findsNothing);
    });

    testWidgets('empty: points to the Devices page', (t) async {
      await pumpAdmin(t, FakeAdmin(), const DashboardScreen());
      expect(find.textContaining('No devices yet'), findsOneWidget);
    });
  });

  group('Staff (D64)', () {
    testWidgets('list with contacts, disabled last', (t) async {
      final fake = FakeAdmin()..staffList = [ben, ana];
      await pumpAdmin(t, fake, const StaffScreen());
      expect(find.text('Ana Cruz'), findsOneWidget);
      expect(find.text('Ben Reyes · Disabled'), findsOneWidget);
      expect(find.textContaining('0917 123 4567'), findsOneWidget);
      expect(find.textContaining('App alerts only'), findsOneWidget);
      final anaY = t.getTopLeft(find.text('Ana Cruz')).dy;
      final benY = t.getTopLeft(find.text('Ben Reyes · Disabled')).dy;
      expect(anaY, lessThan(benY));
    });

    testWidgets('add: one shown password, checked, then a taken username', (
      t,
    ) async {
      final fake = FakeAdmin();
      await pumpAdmin(t, fake, const StaffScreen());
      await t.tap(find.widgetWithText(PrimaryButton, 'Add staff'));
      await t.pumpAndSettle();
      // One password box, shown as typed: the admin tells them the password.
      final password = find.widgetWithText(TextField, 'Password');
      expect(password, findsOneWidget);
      expect(t.widget<TextField>(password).obscureText, isFalse);
      expect(find.text('Password again'), findsNothing);

      await t.enterText(find.widgetWithText(TextField, 'Name'), 'Juan');
      await t.enterText(find.widgetWithText(TextField, 'Username'), 'juan');
      await t.enterText(password, 'short');
      await t.tap(find.widgetWithText(FilledButton, 'Add staff'));
      await t.pumpAndSettle();
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(fake.calls, isEmpty);

      await t.enterText(password, 'secret-12');
      fake.nextError = fail('USERNAME_IN_USE');
      await t.tap(find.widgetWithText(FilledButton, 'Add staff'));
      await t.pumpAndSettle();
      expect(
        find.text('Another account already uses this username.'),
        findsOneWidget,
      );
      expect(fake.calls, ['create Juan juan - -']);
    });

    testWidgets(
      'panel: remove a contact, disable, and delete by typing the name',
      (t) async {
        final fake = FakeAdmin()..staffList = [ana];
        await pumpAdmin(t, fake, const StaffScreen());
        await t.tap(find.text('Ana Cruz'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Mobile number'), '');
        await t.tap(find.widgetWithText(PrimaryButton, 'Save'));
        await t.pumpAndSettle();
        expect(fake.calls.last, 'update u1 Ana Cruz ana "" ""');

        await t.tap(find.text('Disable account'));
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(FilledButton, 'Disable'));
        await t.pumpAndSettle();
        expect(fake.calls.last, 'disable u1 true');

        await t.tap(find.widgetWithText(SecondaryButton, 'Delete staff'));
        await t.pumpAndSettle();
        final delete = find.widgetWithText(FilledButton, 'Delete staff');
        expect(t.widget<FilledButton>(delete).onPressed, isNull);
        await t.enterText(find.byType(TextField).last, 'Ana Cruz');
        await t.pump();
        await t.tap(delete);
        await t.pumpAndSettle();
        expect(fake.calls.last, 'delete u1 Ana Cruz');
      },
    );

    testWidgets('Esc closes the panel', (t) async {
      final fake = FakeAdmin()..staffList = [ana];
      await pumpAdmin(t, fake, const StaffScreen());
      await t.tap(find.text('Ana Cruz'));
      await t.pumpAndSettle();
      expect(find.text('Set a new password'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Set a new password'), findsNothing);
    });
  });

  group('Account', () {
    testWidgets('admins without invites; the mobile for SMS alerts', (t) async {
      final fake = FakeAdmin()
        ..adminList = [
          AdminInfo(
            uid: 'a1',
            name: 'Dana Perez',
            email: 'dana@x.ph',
            phone: '639170000009',
            you: true,
            activatedAt: DateTime(2026, 11, 2),
            lastSignIn: now,
          ),
          const AdminInfo(uid: 'a2', email: 'mark@x.ph', invited: true),
        ];
      await pumpAdmin(t, fake, const AdminAccountScreen());
      expect(find.text('Admin since Nov 2, 2026'), findsOneWidget);
      expect(find.text('0917 000 0009'), findsOneWidget);
      // No invites on the website (2026-11-25).
      expect(find.text('Invite an admin'), findsNothing);
      expect(find.text('Resend'), findsNothing);
      expect(
        find.text("Add a second admin so you can't be locked out."),
        findsNothing,
      );
      expect(find.text('Setup not finished'), findsOneWidget);
      await t.enterText(
        find.widgetWithText(TextField, 'Mobile number for SMS alerts'),
        '',
      );
      await t.tap(find.widgetWithText(SecondaryButton, 'Save').at(1));
      await t.pumpAndSettle();
      expect(fake.calls, ['mobile ']);
    });
  });

  group('Setup', () {
    testWidgets('setup link request always gives the same reply', (t) async {
      final fake = FakeAdmin();
      await pumpAdmin(t, fake, const AdminSetupRequestScreen());
      await t.enterText(find.byType(TextField), 'who@x.ph');
      await t.tap(find.text('Send the link'));
      await t.pumpAndSettle();
      expect(fake.calls, ['setupLink who@x.ph']);
      expect(find.textContaining('Check your inbox.'), findsOneWidget);
    });

    testWidgets('an expired setup link says so', (t) async {
      final fake = FakeAdmin()..nextError = fail('RESET_TOKEN_INVALID');
      await pumpAdmin(t, fake, const AdminSetPasswordScreen(token: 'tok'));
      await t.enterText(find.byType(TextField).first, 'Secret-123');
      await t.enterText(find.byType(TextField).last, 'Secret-123');
      await t.tap(find.text('Save and sign in'));
      await t.pumpAndSettle();
      expect(
        find.text(
          'This link has expired or was already used. Ask for a new one.',
        ),
        findsOneWidget,
      );
    });

    test('the web build refuses staff; setup opens signed out', () {
      String? go(
        String? role, {
        String at = '/dashboard',
        bool signedIn = true,
      }) => redirectFor(
        location: at,
        signedIn: signedIn,
        roleLoaded: true,
        role: role,
        profileLoaded: true,
        requiredRole: 'admin',
        home: '/dashboard',
      );
      expect(go('admin'), isNull);
      expect(go('user'), '/login?refused=notadmin');
      expect(go(null, at: '/setup?token=x', signedIn: false), isNull);
      expect(go('admin', at: '/setup'), '/dashboard');
    });
  });
}
