// Staff sign in (5.1) and Account (4.6) with fakes (D64).
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/app.dart';
import 'package:hydro_sense/core/errors.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/repository.dart';
import 'package:hydro_sense/features/auth/login_screen.dart';
import 'package:hydro_sense/features/client/account_screen.dart';

/// Records the address each sign-in used; [error] makes it fail.
class FakeAuth implements FirebaseAuth {
  final tried = <String>[];
  Object? error;
  int signOuts = 0;

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    tried.add(email);
    if (error != null) throw error!;
    return _Credential();
  }

  @override
  User? get currentUser => null;

  @override
  Future<void> signOut() async => signOuts++;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Credential implements UserCredential {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeClient implements ClientRepository {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<void> phone(WidgetTester t, {double textScale = 1.0}) async {
  t.view.physicalSize = const Size(360 * 3, 780 * 3);
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.textScaleFactorTestValue = textScale;
  t.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

Widget signInHarness(FakeAuth auth, {String? refused}) => ProviderScope(
  overrides: [authProvider.overrideWithValue(auth)],
  child: MaterialApp(
    theme: buildLightTheme(),
    builder: clampTextScale,
    home: LoginScreen(refused: refused),
  ),
);

void main() {
  testWidgets('staff sign in with a username, never an email (D64)', (t) async {
    await phone(t);
    final auth = FakeAuth();
    await t.pumpWidget(signInHarness(auth));
    expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Email'), findsNothing);
    await t.enterText(find.widgetWithText(TextField, 'Username'), ' Juan.DC ');
    await t.enterText(find.widgetWithText(TextField, 'Password'), 'secret-12');
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(auth.tried, ['juan.dc@staff.hydrosense.invalid']);
  });

  testWidgets('staff have no reset: the admin sets a new password', (t) async {
    await phone(t);
    await t.pumpWidget(signInHarness(FakeAuth()));
    expect(find.text('Forgot password?'), findsNothing);
    expect(
      find.text('Accounts and passwords are provided by your admin.'),
      findsOneWidget,
    );
  });

  testWidgets('a wrong username or password gets one reply', (t) async {
    await phone(t);
    final auth = FakeAuth()
      ..error = FirebaseAuthException(code: 'invalid-credential');
    await t.pumpWidget(signInHarness(auth));
    await t.enterText(find.widgetWithText(TextField, 'Username'), 'nobody');
    await t.enterText(find.widgetWithText(TextField, 'Password'), 'x');
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(find.text(Messages.staffWrongCredentials), findsOneWidget);

    auth.error = FirebaseAuthException(code: 'user-disabled');
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(find.text(Messages.suspended), findsOneWidget);

    auth.error = FirebaseAuthException(code: 'too-many-requests');
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(find.text(Messages.staffTooManyAttempts), findsOneWidget);
  });

  testWidgets('an admin account is refused on the app and signed out', (
    t,
  ) async {
    await phone(t);
    final auth = FakeAuth();
    await t.pumpWidget(signInHarness(auth, refused: 'admin'));
    await t.pump();
    expect(find.text(Messages.adminOnPhone), findsOneWidget);
    expect(auth.signOuts, 1);
  });

  testWidgets('the logo stays a 64 px square on any width', (t) async {
    await phone(t);
    await t.pumpWidget(signInHarness(FakeAuth()));
    expect(
      t.getSize(find.byKey(const ValueKey('app-logo'))),
      const Size(64, 64),
    );
    t.view.physicalSize = const Size(1100 * 3, 760 * 3);
    await t.pumpWidget(signInHarness(FakeAuth()));
    await t.pump();
    expect(
      t.getSize(find.byKey(const ValueKey('app-logo'))),
      const Size(64, 64),
    );
  });

  testWidgets('sign in fits a 360 dp phone at 1.5x text', (t) async {
    await phone(t, textScale: 1.5);
    await t.pumpWidget(signInHarness(FakeAuth()));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  Widget accountHarness() => ProviderScope(
    overrides: [
      uidProvider.overrideWithValue('u1'),
      userProvider.overrideWith((_) => Stream.value(null)),
      repositoryProvider.overrideWithValue(FakeClient()),
      profileProvider.overrideWith(
        (_) => Stream.value(
          const UserProfile(
            displayName: 'Juan Dela Cruz',
            phone: '639171234567',
            email: 'juan@example.com',
            username: 'juan.dc',
          ),
        ),
      ),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      builder: clampTextScale,
      home: const AccountScreen(),
    ),
  );

  testWidgets('account: read-only details, no switches (D64, D65)', (t) async {
    await phone(t);
    await t.pumpWidget(accountHarness());
    await t.pumpAndSettle();
    expect(find.text('JD'), findsOneWidget);
    expect(find.text('juan.dc'), findsOneWidget);
    expect(find.text('0917 123 4567'), findsOneWidget);
    expect(find.text('juan@example.com'), findsOneWidget);
    // Staff change nothing: no Change buttons, no alert switches, no deletion.
    expect(find.text('Change'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, 'SMS'), findsNothing);
    expect(find.textContaining('account deletion'), findsNothing);
    expect(
      find.text(
        'Alerts go to this phone and the contacts above. Your admin can change them.',
      ),
      findsOneWidget,
    );
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('account fits a 360 dp phone at 1.5x text', (t) async {
    await phone(t, textScale: 1.5);
    await t.pumpWidget(accountHarness());
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
