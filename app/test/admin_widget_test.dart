// Admin website screens (KICKOFF.md Phase 6) with a fake AdminRepository.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/admin_providers.dart';
import 'package:hydro_sense/data/admin_repository.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/repository.dart';
import 'package:hydro_sense/features/admin/admin_shell.dart';
import 'package:hydro_sense/features/admin/battery_chart.dart';
import 'package:hydro_sense/features/admin/devices_admin_screen.dart';
import 'package:hydro_sense/features/admin/errors_screen.dart';
import 'package:hydro_sense/features/admin/hardware_report_screen.dart';
import 'package:hydro_sense/features/admin/overview_screen.dart';
import 'package:hydro_sense/router.dart';

import 'test_data.dart';

class FakeAdmin implements AdminRepository {
  List<Health> healthList = [];
  List<AllowedEntry> allowedList = [];
  List<RemovedEntry> removedList = [];
  List<ErrorEntry> errorList = [];
  List<BatteryPoint> battery = [];
  ClientInfo? clientInfo;
  Object? createError;
  final calls = <String>[];

  @override
  Stream<List<Health>> health() => Stream.value(healthList);
  @override
  Stream<List<AllowedEntry>> allowed() => Stream.value(allowedList);
  @override
  Stream<List<RemovedEntry>> removed() => Stream.value(removedList);
  @override
  Stream<List<ErrorEntry>> errors({
    String? deviceId,
    String? code,
    int limit = 100,
  }) => Stream.value(
    errorList.where((e) => deviceId == null || e.deviceId == deviceId).toList(),
  );
  @override
  Stream<List<BatteryPoint>> batteryHistory(String deviceId, Duration window) =>
      Stream.value(battery);
  @override
  Stream<Diagnostics?> diagnostics() => Stream.value(null);
  @override
  Stream<ClientInfo?> client() => Stream.value(clientInfo);

  @override
  Future<void> addAllowedDevice(String deviceId) async =>
      calls.add('add $deviceId');
  @override
  Future<void> removeDevice(String deviceId) async =>
      calls.add('remove $deviceId');
  @override
  Future<void> allowDevice(String deviceId) async =>
      calls.add('allow $deviceId');
  @override
  Future<void> runHardwareReport() async => calls.add('report');
  @override
  Future<CreateClientResult> createClient({
    required String name,
    required String email,
    required String phone,
    required bool temporaryPassword,
  }) async {
    calls.add('create $name $email $phone temp=$temporaryPassword');
    if (createError != null) throw createError!;
    return CreateClientResult(
      temporaryPassword: temporaryPassword ? 'Abc23Def45gh' : null,
      emailSent: true,
      adopted: 2,
    );
  }
}

/// Any use of the client data layer from an admin screen fails the test.
class ForbiddenClientRepo implements ClientRepository {
  @override
  dynamic noSuchMethod(Invocation i) => throw StateError(
    'Admin screen touched the client repository: ${i.memberName}',
  );
}

Health h(
  String id, {
  bool online = true,
  int? pct = 80,
  bool sleep = false,
  DateTime? lastSeen,
}) => Health(
  id: id,
  online: online,
  lastSeen: lastSeen ?? testNow.subtract(const Duration(minutes: 2)),
  batteryPercent: pct,
  batteryVoltage: pct == null ? null : 6.6 + 1.8 * pct / 100,
  chargingStatus: 'Steady',
  lowVoltageSleep: sleep,
  firmware: '1.0.0',
);

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
  await t.pumpAndSettle();
}

void main() {
  testWidgets('overview counts registered, online, offline and low battery', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    final fake = FakeAdmin()
      ..healthList = [
        h('A1'),
        h('A2', online: false),
        h('A3', pct: 15),
        h('A4', online: false, sleep: true),
      ]
      ..allowedList = [const AllowedEntry('B1', null)];
    await pumpAdmin(t, fake, const OverviewScreen());
    expect(find.bySemanticsLabel('Registered: 4'), findsOneWidget);
    expect(find.bySemanticsLabel('Online: 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Offline: 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Low battery: 1'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('overview with zero devices', (t) async {
    await pumpAdmin(t, FakeAdmin(), const OverviewScreen());
    expect(find.text('No devices have registered yet.'), findsOneWidget);
  });

  testWidgets('create client: temporary password shown once, then Done', (
    t,
  ) async {
    final fake = FakeAdmin();
    await pumpAdmin(t, fake, const OverviewScreen());
    expect(find.text('Create client account'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'Name'), 'Juan');
    await t.enterText(
      find.widgetWithText(TextField, 'Email'),
      'juan@example.com',
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Mobile number'),
      '0917 123 4567',
    );
    await t.tap(find.text('Create a temporary password'));
    await t.tap(find.text('Create client'));
    await t.pumpAndSettle();
    expect(
      fake.calls.single,
      'create Juan juan@example.com 0917 123 4567 temp=true',
    );
    expect(
      find.textContaining('Copy it now. It is shown once.'),
      findsOneWidget,
    );
    expect(find.text('Abc23Def45gh'), findsOneWidget);
    expect(find.textContaining('2 already-registered devices'), findsOneWidget);
  });

  testWidgets('create client validates the phone before calling', (t) async {
    final fake = FakeAdmin();
    await pumpAdmin(t, fake, const OverviewScreen());
    await t.enterText(find.widgetWithText(TextField, 'Name'), 'Juan');
    await t.enterText(
      find.widgetWithText(TextField, 'Email'),
      'juan@example.com',
    );
    await t.enterText(find.widgetWithText(TextField, 'Mobile number'), '12345');
    await t.tap(find.text('Create client'));
    await t.pumpAndSettle();
    expect(fake.calls, isEmpty);
    expect(
      find.text('Enter a Philippine mobile number, for example 09171234567.'),
      findsOneWidget,
    );
  });

  testWidgets('create client shows "A client account already exists."', (
    t,
  ) async {
    final fake = FakeAdmin()
      ..createError = FirebaseFunctionsException(
        code: 'already-exists',
        message: 'x',
        details: {'code': 'CLIENT_EXISTS'},
      );
    await pumpAdmin(t, fake, const OverviewScreen());
    await t.enterText(find.widgetWithText(TextField, 'Name'), 'Juan');
    await t.enterText(
      find.widgetWithText(TextField, 'Email'),
      'juan@example.com',
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Mobile number'),
      '09171234567',
    );
    await t.tap(find.text('Create client'));
    await t.pumpAndSettle();
    expect(find.text('A client account already exists.'), findsOneWidget);
  });

  testWidgets('existing client replaces the form with name and email', (
    t,
  ) async {
    final fake = FakeAdmin()
      ..clientInfo = const ClientInfo(
        uid: 'c1',
        name: 'Juan',
        email: 'juan@example.com',
      );
    await pumpAdmin(t, fake, const OverviewScreen());
    expect(find.text('Create client account'), findsNothing);
    expect(find.text('Juan'), findsOneWidget);
    expect(find.text('juan@example.com'), findsOneWidget);
  });

  testWidgets('devices table: waiting, online, offline, sleeping rows', (
    t,
  ) async {
    final fake = FakeAdmin()
      ..healthList = [
        h('A1B2C3D4E5F1'),
        h('A1B2C3D4E5F2', online: false),
        h('A1B2C3D4E5F3', online: false, sleep: true),
      ]
      ..allowedList = [
        const AllowedEntry('A1B2C3D4E5F9', null),
        const AllowedEntry('A1B2C3D4E5F1', null),
      ];
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    expect(find.text('A1B2C3D4E5F9'), findsOneWidget);
    expect(find.text('Waiting to register'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Sleeping (low battery)'), findsOneWidget);
  });

  testWidgets('add device validates and normalizes the ID', (t) async {
    final fake = FakeAdmin();
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    await t.tap(find.text('Add device'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '123');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();
    expect(find.text(addDeviceError), findsOneWidget);
    await t.enterText(find.byType(TextField), 'a1:b2:c3:d4:e5:f6');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();
    expect(fake.calls, ['add A1B2C3D4E5F6']);
  });

  testWidgets('remove asks for confirmation with the spec wording', (t) async {
    final fake = FakeAdmin()..healthList = [h('A1B2C3D4E5F6')];
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    await t.ensureVisible(find.byTooltip('Remove'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Remove'));
    await t.pumpAndSettle();
    expect(
      find.text(
        'Remove device A1B2C3D4E5F6? Its data is deleted and it cannot register again until you choose Allow again.',
      ),
      findsOneWidget,
    );
    await t.tap(find.widgetWithText(FilledButton, 'Remove'));
    await t.pumpAndSettle();
    expect(fake.calls, ['remove A1B2C3D4E5F6']);
  });

  testWidgets('removed devices can be allowed again', (t) async {
    final fake = FakeAdmin()
      ..removedList = [RemovedEntry('A1B2C3D4E5F6', testNow)];
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    await t.tap(find.text('Allow again'));
    await t.pumpAndSettle();
    expect(fake.calls, ['allow A1B2C3D4E5F6']);
    expect(find.text(allowedAgainMessage), findsOneWidget);
  });

  testWidgets('battery history chart and table', (t) async {
    final fake = FakeAdmin()
      ..healthList = [h('A1B2C3D4E5F6')]
      ..battery = [
        for (var i = 0; i < 7 * 96; i++)
          BatteryPoint(
            testNow.subtract(Duration(minutes: 15 * (7 * 96 - i))),
            7.6 + 0.4 * ((i % 96) - 48).abs() / 48 - 0.3 * i / (7 * 96),
            60,
          ),
      ];
    await pumpAdmin(t, fake, const DevicesAdminScreen());
    await t.ensureVisible(find.byTooltip('Battery history'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Battery history'));
    await t.pumpAndSettle();
    expect(find.byType(BatteryChart), findsOneWidget);
    expect(t.takeException(), isNull);
    final chart = t.getCenter(find.byType(BatteryChart));
    final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: chart);
    await t.pump();
    expect(t.takeException(), isNull);
    await t.tap(find.text('Show table'));
    await t.pumpAndSettle();
    expect(find.text('Voltage'), findsOneWidget);
  });

  testWidgets('errors screen empty state', (t) async {
    await pumpAdmin(t, FakeAdmin(), const ErrorsScreen());
    expect(find.text('No errors logged.'), findsOneWidget);
  });

  testWidgets('errors screen lists entries newest first', (t) async {
    final fake = FakeAdmin()
      ..errorList = [
        ErrorEntry(
          id: '1',
          deviceId: 'A1B2C3D4E5F6',
          source: 'alerts',
          code: 'SMS_FAILED',
          message: 'Semaphore HTTP 500',
          ts: testNow,
        ),
      ];
    await pumpAdmin(t, fake, const ErrorsScreen());
    expect(find.text('SMS_FAILED'), findsOneWidget);
    expect(find.text('Semaphore HTTP 500'), findsOneWidget);
  });

  testWidgets('hardware report with no report yet', (t) async {
    final fake = FakeAdmin();
    await pumpAdmin(t, fake, const HardwareReportScreen());
    expect(find.textContaining('No report yet'), findsOneWidget);
    await t.tap(find.text('Run report'));
    await t.pumpAndSettle();
    expect(fake.calls, ['report']);
  });

  testWidgets('rail on wide screens, drawer under 800 px', (t) async {
    final fake = FakeAdmin();
    Widget shell() =>
        const AdminShell(location: '/overview', child: SizedBox());
    await pumpAdmin(t, fake, shell());
    expect(find.byType(NavigationRail), findsOneWidget);
    await pumpAdmin(t, fake, shell(), size: const Size(700, 900));
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
  });

  test('the web build refuses non-admins', () {
    String? go(String? role) => redirectFor(
      location: '/overview',
      signedIn: true,
      roleLoaded: true,
      role: role,
      profileLoaded: true,
      mustChangePassword: false,
      requiredRole: 'admin',
      home: '/overview',
    );
    expect(go('admin'), isNull);
    expect(go('client'), '/login?refused=notadmin');
    expect(go(null), '/login?refused=notadmin');
  });
}
