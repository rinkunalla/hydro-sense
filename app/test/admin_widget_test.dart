// Admin website screens with a fake AdminRepository (stage 2 data layer).
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/admin_logic.dart';
import 'package:hydro_sense/data/admin_providers.dart';
import 'package:hydro_sense/data/admin_repository.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/repository.dart';
import 'package:hydro_sense/features/admin/admin_shell.dart';
import 'package:hydro_sense/features/admin/create_user_card.dart';
import 'package:hydro_sense/features/admin/devices_admin_screen.dart';
import 'package:hydro_sense/router.dart';

import 'test_data.dart';

class FakeAdmin implements AdminRepository {
  List<AdminDevice> list = [];
  Object? createError;
  final calls = <String>[];

  @override
  Future<List<AdminDevice>> devices() async => list;
  @override
  Future<void> addAllowedDevice(String deviceId, {String? label}) async =>
      calls.add('add $deviceId ${label ?? ''}'.trim());
  @override
  Future<void> removeDevice(
    String deviceId, {
    required String confirmLabel,
  }) async => calls.add('remove $deviceId $confirmLabel');
  @override
  Future<void> restoreDevice(String deviceId) async =>
      calls.add('restore $deviceId');
  @override
  Future<String> createUser({
    required String name,
    required String email,
    required String mobile,
  }) async {
    calls.add('create $name $email $mobile');
    if (createError != null) throw createError!;
    return 'uid1';
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
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        adminRepositoryProvider.overrideWithValue(fake),
        repositoryProvider.overrideWithValue(ForbiddenClientRepo()),
        clockProvider.overrideWith((_) => Stream.value(testNow)),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

const unit1 = AdminDevice(
  id: 'A1B2C3D4E5F1',
  label: 'Unit 1',
  ownerUid: 'u1',
  ownerName: 'Juan',
  registered: true,
  online: true,
);

void main() {
  test('admin states come only from registration, online and removal', () {
    expect(stateOf(unit1), AdminState.online);
    expect(
      stateOf(const AdminDevice(id: 'x', registered: true)),
      AdminState.offline,
    );
    expect(stateOf(const AdminDevice(id: 'x')), AdminState.notSetUp);
    expect(
      stateOf(AdminDevice(id: 'x', registered: true, removedAt: testNow)),
      AdminState.removed,
    );
  });

  testWidgets('devices table: label, owner and every status', (t) async {
    final fake = FakeAdmin()
      ..list = [
        unit1,
        AdminDevice(
          id: 'A1B2C3D4E5F2',
          registered: true,
          lastSeen: testNow.subtract(const Duration(hours: 2)),
        ),
        const AdminDevice(id: 'A1B2C3D4E5F3'),
        AdminDevice(
          id: 'A1B2C3D4E5F4',
          registered: true,
          removedAt: testNow,
          purgeAfter: testNow.add(const Duration(days: 30)),
        ),
      ];
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    expect(find.text('Unit 1'), findsOneWidget);
    expect(find.text('Juan'), findsOneWidget);
    expect(find.text('Unassigned'), findsNWidgets(3));
    expect(find.text('Online'), findsOneWidget);
    expect(find.textContaining('Offline since'), findsOneWidget);
    expect(find.text('Not set up yet'), findsOneWidget);
    expect(find.textContaining('Removed'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
  });

  testWidgets('devices page with no devices', (t) async {
    await pumpAdmin(t, FakeAdmin(), const DevicesAdminScreen());
    expect(find.text('No devices added yet.'), findsOneWidget);
  });

  testWidgets('add device validates the ID and sends the label', (t) async {
    final fake = FakeAdmin();
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    await t.tap(find.text('Add device'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Device ID'), '123');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();
    expect(find.text(addDeviceError), findsOneWidget);
    await t.enterText(
      find.widgetWithText(TextField, 'Device ID'),
      'a1:b2:c3:d4:e5:f6',
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Label (optional)'),
      'Unit 9',
    );
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();
    expect(fake.calls, ['add A1B2C3D4E5F6 Unit 9']);
  });

  testWidgets('remove needs the typed label (D42)', (t) async {
    final fake = FakeAdmin()..list = [unit1];
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    await t.tap(find.byTooltip('Remove'));
    await t.pumpAndSettle();
    expect(find.text('Type "Unit 1" to confirm.'), findsOneWidget);
    final remove = find.widgetWithText(FilledButton, 'Remove');
    expect(t.widget<FilledButton>(remove).onPressed, isNull);
    await t.enterText(find.byType(TextField), 'unit  1 ');
    await t.pump();
    expect(t.widget<FilledButton>(remove).onPressed, isNotNull);
    await t.tap(remove);
    await t.pumpAndSettle();
    expect(fake.calls, ['remove A1B2C3D4E5F1 Unit 1']);
  });

  testWidgets('a removed device can be restored', (t) async {
    final fake = FakeAdmin()
      ..list = [AdminDevice(id: 'A1B2C3D4E5F4', removedAt: testNow)];
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    await t.tap(find.text('Restore'));
    await t.pumpAndSettle();
    expect(fake.calls, ['restore A1B2C3D4E5F4']);
  });

  testWidgets('create user sends name, email and mobile', (t) async {
    final fake = FakeAdmin();
    await pumpAdmin(t, fake, const CreateUserCard());
    await t.enterText(find.widgetWithText(TextField, 'Name'), 'Juan');
    await t.enterText(
      find.widgetWithText(TextField, 'Email'),
      'juan@example.com',
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Mobile number'),
      '0917 123 4567',
    );
    await t.tap(find.widgetWithText(FilledButton, 'Create user'));
    await t.pumpAndSettle();
    expect(fake.calls.single, 'create Juan juan@example.com 0917 123 4567');
    expect(find.text('User created'), findsOneWidget);
  });

  testWidgets('create user validates the phone before calling', (t) async {
    final fake = FakeAdmin();
    await pumpAdmin(t, fake, const CreateUserCard());
    await t.enterText(find.widgetWithText(TextField, 'Name'), 'Juan');
    await t.enterText(
      find.widgetWithText(TextField, 'Email'),
      'juan@example.com',
    );
    await t.enterText(find.widgetWithText(TextField, 'Mobile number'), '12345');
    await t.tap(find.widgetWithText(FilledButton, 'Create user'));
    await t.pumpAndSettle();
    expect(fake.calls, isEmpty);
    expect(find.text(phoneHint), findsOneWidget);
  });

  testWidgets('create user shows the duplicate-mobile message', (t) async {
    final fake = FakeAdmin()
      ..createError = FirebaseFunctionsException(
        code: 'already-exists',
        message: 'x',
        details: {'code': 'PHONE_IN_USE'},
      );
    await pumpAdmin(t, fake, const CreateUserCard());
    await t.enterText(find.widgetWithText(TextField, 'Name'), 'Juan');
    await t.enterText(
      find.widgetWithText(TextField, 'Email'),
      'juan@example.com',
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Mobile number'),
      '09171234567',
    );
    await t.tap(find.widgetWithText(FilledButton, 'Create user'));
    await t.pumpAndSettle();
    expect(
      find.text('Another account already uses this mobile number.'),
      findsOneWidget,
    );
  });

  testWidgets('rail on wide screens, drawer under 800 px', (t) async {
    final fake = FakeAdmin();
    Widget shell() => const AdminShell(location: '/devices', child: SizedBox());
    await pumpAdmin(t, fake, shell());
    expect(find.byType(NavigationRail), findsOneWidget);
    await pumpAdmin(t, fake, shell(), size: const Size(700, 900));
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
  });

  test('the web build refuses non-admins', () {
    String? go(String? role) => redirectFor(
      location: '/devices',
      signedIn: true,
      roleLoaded: true,
      role: role,
      profileLoaded: true,
      requiredRole: 'admin',
      home: '/devices',
    );
    expect(go('admin'), isNull);
    expect(go('user'), '/login?refused=notadmin');
    expect(go(null), '/login?refused=notadmin');
  });
}
