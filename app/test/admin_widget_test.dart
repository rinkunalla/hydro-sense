// Admin website (KICKOFF.md stage 6) with a fake AdminRepository.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/errors.dart';
import 'package:hydro_sense/core/glass.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/admin_providers.dart';
import 'package:hydro_sense/data/admin_repository.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/repository.dart';
import 'package:hydro_sense/features/admin/admin_account_screen.dart';
import 'package:hydro_sense/features/admin/admin_setup_screen.dart';
import 'package:hydro_sense/features/admin/admin_shell.dart';
import 'package:hydro_sense/features/admin/devices_admin_screen.dart';
import 'package:hydro_sense/features/admin/users_screen.dart';
import 'package:hydro_sense/router.dart';

final now = DateTime.now();

FirebaseFunctionsException fail(String code) => FirebaseFunctionsException(
  code: 'failed-precondition',
  message: code,
  details: {'code': code},
);

class FakeAdmin implements AdminRepository {
  List<AdminDevice> deviceList = [];
  List<AdminUser> userList = [];
  List<AdminInfo> adminList = [];
  List<AuditEntry> log = [];
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
  Future<List<AdminDevice>> devices() async => deviceList;
  @override
  Future<void> addAllowedDevice(String deviceId, {String? label}) =>
      _rec('add $deviceId ${label ?? ''}'.trim());
  @override
  Future<void> updateDeviceLabel(String deviceId, String? label) =>
      _rec('label $deviceId $label');
  @override
  Future<void> assignDevice(String deviceId, String? uid) =>
      _rec('assign $deviceId $uid');
  @override
  Future<void> removeDevice(String deviceId, {required String confirmLabel}) =>
      _rec('remove $deviceId $confirmLabel');
  @override
  Future<void> restoreDevice(String deviceId) =>
      _rec('restoreDevice $deviceId');
  @override
  Future<List<AdminUser>> users() async => userList;
  @override
  Future<String> createUser({
    required String name,
    required String email,
    required String mobile,
  }) async {
    await _rec('create $name $email $mobile');
    return 'new';
  }

  @override
  Future<void> updateUser(
    String uid, {
    String? name,
    String? email,
    String? mobile,
  }) => _rec('update $uid $name $email $mobile');
  @override
  Future<void> deleteUser(String uid, {required String confirmName}) =>
      _rec('delete $uid $confirmName');
  @override
  Future<void> restoreUser(String uid) => _rec('restoreUser $uid');
  @override
  Future<({List<AdminInfo> admins, bool belowRecommended})> admins() async =>
      (admins: adminList, belowRecommended: belowRecommended);
  @override
  Future<void> inviteAdmin(String email) => _rec('invite $email');
  @override
  Future<void> resendAdminInvite(String uid) => _rec('resend $uid');
  @override
  Future<void> cancelAdminInvite(String uid) => _rec('cancel $uid');
  @override
  Future<void> removeAdmin(String uid) => _rec('removeAdmin $uid');
  @override
  Future<void> updateMyAdminName(String name) => _rec('name $name');
  @override
  Future<void> syncMyAdmin() => _rec('sync');
  @override
  Future<void> signOutEverywhere() => _rec('signOutEverywhere');
  @override
  Future<List<AuditEntry>> audit() async => log;
  @override
  Future<void> requestAdminSetup(String email) => _rec('setupLink $email');
  @override
  Future<String> completeAdminSetup(String token, String password) async {
    await _rec('complete $token');
    return 'a@x.ph';
  }
}

/// Any use of the user data layer from an admin screen fails the test.
class ForbiddenClientRepo implements ClientRepository {
  @override
  dynamic noSuchMethod(Invocation i) => throw StateError(
    'Admin screen touched the user repository: ${i.memberName}',
  );
}

Future<void> pumpAdmin(
  WidgetTester t,
  FakeAdmin fake,
  Widget screen, {
  Size size = const Size(1280, 900),
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
        repositoryProvider.overrideWithValue(ForbiddenClientRepo()),
        userProvider.overrideWith((_) => Stream.value(null)),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await t.pumpAndSettle();
}

const ana = AdminUser(
  uid: 'u1',
  name: 'Ana Cruz',
  email: 'ana@x.ph',
  phone: '639171234567',
  deviceCount: 1,
  passwordSet: true,
);

void main() {
  group('Users', () {
    testWidgets('table, statuses, suspended filter and restore', (t) async {
      final fake = FakeAdmin()
        ..userList = [
          ana,
          const AdminUser(
            uid: 'u2',
            name: 'Ben Diaz',
            email: 'ben@x.ph',
            phone: '639181112222',
          ),
          AdminUser(
            uid: 'u3',
            name: 'Carlo',
            email: 'c@x.ph',
            phone: '639190000000',
            suspended: true,
            purgeAfter: DateTime(2026, 12, 13),
          ),
        ];
      await pumpAdmin(t, fake, const UsersScreen());
      expect(find.text('Ana Cruz'), findsOneWidget);
      expect(find.text('0917 123 4567'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Password not set'), findsOneWidget);
      expect(find.text('Suspended · deletes Dec 13'), findsOneWidget);
      await t.tap(find.text('Suspended 1'));
      await t.pumpAndSettle();
      expect(find.text('Ana Cruz'), findsNothing);
      await t.tap(find.text('Restore'));
      await t.pumpAndSettle();
      expect(fake.calls, ['restoreUser u3']);
    });

    testWidgets('empty state', (t) async {
      await pumpAdmin(t, FakeAdmin(), const UsersScreen());
      expect(find.text('No users yet. Create the first one.'), findsOneWidget);
    });

    testWidgets('create: checks the mobile, then reports a taken number', (
      t,
    ) async {
      final fake = FakeAdmin();
      await pumpAdmin(t, fake, const UsersScreen());
      await t.tap(find.text('Create user').first);
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Name'), 'Dana');
      await t.enterText(find.widgetWithText(TextField, 'Mobile number'), '12');
      await t.enterText(find.widgetWithText(TextField, 'Email'), 'd@x.ph');
      await t.tap(find.text('Create user').last);
      await t.pumpAndSettle();
      expect(find.text(Messages.phoneHint), findsOneWidget);
      expect(fake.calls, isEmpty);

      await t.enterText(
        find.widgetWithText(TextField, 'Mobile number'),
        '0917 555 0000',
      );
      fake.nextError = fail('PHONE_IN_USE');
      await t.tap(find.text('Create user').last);
      await t.pumpAndSettle();
      expect(
        find.text('Another user already has this mobile number.'),
        findsOneWidget,
      );
      await t.tap(find.text('Create user').last);
      await t.pumpAndSettle();
      expect(fake.calls.last, 'create Dana d@x.ph 0917 555 0000');
      expect(find.textContaining('User created.'), findsOneWidget);
    });

    testWidgets('delete needs the name typed; Esc closes the panel', (t) async {
      final fake = FakeAdmin()..userList = [ana];
      await pumpAdmin(t, fake, const UsersScreen());
      await t.tap(find.text('Ana Cruz'));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete user'));
      await t.pumpAndSettle();
      final delete = find.widgetWithText(FilledButton, 'Delete');
      expect(t.widget<FilledButton>(delete).onPressed, isNull);
      await t.enterText(find.byType(TextField).last, 'Ana Cruz');
      await t.pump();
      await t.tap(delete);
      await t.pumpAndSettle();
      expect(fake.calls, ['delete u1 Ana Cruz']);

      await t.tap(find.text('Ana Cruz'));
      await t.pumpAndSettle();
      expect(find.text('Save changes'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Save changes'), findsNothing);
    });
  });

  group('Devices', () {
    final rows = [
      AdminDevice(
        id: 'AAAAAAAAAAA1',
        label: 'Unit 1',
        ownerUid: 'u1',
        ownerName: 'Ana Cruz',
        registered: true,
        online: true,
        lastSeen: now,
      ),
      const AdminDevice(id: 'BBBBBBBBBBB2'),
      AdminDevice(
        id: 'CCCCCCCCCCC3',
        label: 'Unit 3',
        ownerUid: 'u1',
        ownerName: 'Ana Cruz',
        registered: true,
        lastSeen: now.subtract(const Duration(hours: 3)),
      ),
    ];

    testWidgets('counts, offline first, Assign only on unassigned rows', (
      t,
    ) async {
      final fake = FakeAdmin()
        ..deviceList = rows
        ..userList = [ana];
      await pumpAdmin(t, fake, const DevicesAdminScreen());
      expect(find.text('All 3'), findsOneWidget);
      expect(find.text('Unassigned 1'), findsOneWidget);
      expect(find.text('Offline 1'), findsOneWidget);
      expect(find.text('No label'), findsOneWidget);
      expect(find.text('Assign'), findsOneWidget);
      double y(String s) => t.getTopLeft(find.text(s)).dy;
      expect(y('Unit 3'), lessThan(y('Unit 1')), reason: 'offline first');
      expect(find.textContaining('Offline · since'), findsOneWidget);

      await t.tap(find.text('Assign'));
      await t.pumpAndSettle();
      await t.tap(find.text('Ana Cruz').last);
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Assign'));
      await t.pumpAndSettle();
      expect(fake.calls, ['assign BBBBBBBBBBB2 u1']);
    });

    testWidgets('add device: checks the ID and shows the checklist', (t) async {
      final fake = FakeAdmin();
      await pumpAdmin(t, fake, const DevicesAdminScreen());
      await t.tap(find.text('Add device').first);
      await t.pumpAndSettle();
      expect(find.text('INSTALL CHECKLIST'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'Device ID'), 'abc');
      await t.tap(find.widgetWithText(FilledButton, 'Add device'));
      await t.pump();
      expect(
        find.text(
          'Enter the 12-character ID shown on the device label or setup page.',
        ),
        findsOneWidget,
      );
      await t.enterText(
        find.widgetWithText(TextField, 'Device ID'),
        'a4:f0:0f:69:36:b0',
      );
      await t.tap(find.widgetWithText(FilledButton, 'Add device'));
      await t.pumpAndSettle();
      expect(fake.calls, ['add A4F00F6936B0']);
    });

    testWidgets('remove and reassign need the label typed', (t) async {
      final fake = FakeAdmin()
        ..deviceList = rows
        ..userList = [
          ana,
          const AdminUser(
            uid: 'u2',
            name: 'Ben Diaz',
            email: 'b@x.ph',
            phone: '639181112222',
          ),
        ];
      await pumpAdmin(t, fake, const DevicesAdminScreen());
      await t.tap(find.text('Unit 1'));
      await t.pumpAndSettle();
      await t.tap(find.text('Remove device'));
      await t.pumpAndSettle();
      final remove = find.widgetWithText(FilledButton, 'Remove');
      expect(t.widget<FilledButton>(remove).onPressed, isNull);
      await t.enterText(find.byType(TextField).last, 'unit 1');
      await t.pump();
      await t.tap(remove);
      await t.pumpAndSettle();
      expect(fake.calls, ['remove AAAAAAAAAAA1 Unit 1']);

      await t.tap(find.text('Unit 1'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(PrimaryButton, 'Reassign'));
      await t.pumpAndSettle();
      expect(find.textContaining('old history is deleted'), findsOneWidget);
      await t.tap(find.text('Ben Diaz'));
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Reassign'));
      await t.pumpAndSettle();
      expect(find.textContaining('Its history is deleted first'), findsOne);
      await t.enterText(find.byType(TextField).last, 'Unit 1');
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Reassign').last);
      await t.pumpAndSettle();
      expect(fake.calls.last, 'assign AAAAAAAAAAA1 u2');
    });
  });

  group('Account', () {
    testWidgets('one admin: the hint; invite; activity with Restore', (
      t,
    ) async {
      final fake = FakeAdmin()
        ..belowRecommended = true
        ..adminList = [
          AdminInfo(
            uid: 'a1',
            name: 'Dana Perez',
            email: 'dana@x.ph',
            you: true,
            activatedAt: DateTime(2026, 11, 2),
            lastSignIn: now,
          ),
          const AdminInfo(
            uid: 'a2',
            email: 'mark@x.ph',
            invited: true,
            inviteExpired: true,
          ),
        ]
        ..log = [
          AuditEntry(
            id: 'e1',
            at: now,
            adminEmail: 'dana@x.ph',
            action: 'user_deleted',
            targetId: 'u3',
            targetName: 'Carlo Diaz',
          ),
        ];
      await pumpAdmin(t, fake, const AdminAccountScreen());
      expect(
        find.text("Add a second admin so you can't be locked out."),
        findsOneWidget,
      );
      expect(find.text('Admin since Nov 2, 2026'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Invite expired'), findsOneWidget);
      expect(
        find.textContaining(
          'dana@x.ph deleted the user Carlo Diaz',
          findRichText: true,
        ),
        findsOne,
      );

      await t.tap(find.text('Resend'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Email').last, 'z@x.ph');
      await t.tap(find.widgetWithText(PrimaryButton, 'Invite'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Restore'));
      await t.tap(find.text('Restore'));
      await t.pumpAndSettle();
      expect(fake.calls, ['resend a2', 'invite z@x.ph', 'restoreUser u3']);
    });
  });

  group('Shell and setup', () {
    testWidgets('tabs on wide screens, a menu under 800 px; syncs once', (
      t,
    ) async {
      final fake = FakeAdmin();
      Widget shell() => const AdminShell(location: '/users', child: SizedBox());
      await pumpAdmin(t, fake, shell());
      expect(find.text('Users'), findsOneWidget);
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      expect(fake.calls, contains('sync'));
      await pumpAdmin(t, fake, shell(), size: const Size(700, 900));
      expect(find.byTooltip('Menu'), findsOneWidget);
      expect(find.text('Devices'), findsNothing);
    });

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
      expect(find.text('Stronger with:'), findsOneWidget);
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

    test('the web build refuses non-admins; setup opens signed out', () {
      String? go(String? role, {String at = '/users', bool signedIn = true}) =>
          redirectFor(
            location: at,
            signedIn: signedIn,
            roleLoaded: true,
            role: role,
            profileLoaded: true,
            requiredRole: 'admin',
            home: '/users',
          );
      expect(go('admin'), isNull);
      expect(go('user'), '/login?refused=notadmin');
      expect(go(null, at: '/setup?token=x', signedIn: false), isNull);
      expect(go(null, at: '/setup', signedIn: false), isNull);
      expect(go('admin', at: '/setup'), '/users');
    });
  });
}
