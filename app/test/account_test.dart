// Reset by SMS (5.2) and Account (4.6) with fake repositories.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/app.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/account_repository.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/data/repository.dart';
import 'package:hydro_sense/features/auth/sms_reset_screen.dart';
import 'package:hydro_sense/features/client/account_screen.dart';

import 'test_data.dart';

class FakeAccount implements AccountRepository {
  final calls = <String>[];
  Object? verifyError;

  @override
  Future<int> requestResetCode(String address, {bool byEmail = false}) async {
    calls.add('code ${byEmail ? 'email ' : ''}$address');
    return 60;
  }

  @override
  Future<String> verifyResetCode(
    String address,
    String code, {
    bool byEmail = false,
  }) async {
    calls.add('verify $code');
    if (verifyError != null) throw verifyError!;
    return 'uid.token';
  }

  @override
  Future<void> setPasswordAndSignIn(
    String resetToken,
    String newPassword,
  ) async => calls.add('set $resetToken');

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeClient implements ClientRepository {
  final saved = <AlertPrefs>[];
  bool fail = false;

  @override
  Future<void> setAlertPrefs(String uid, AlertPrefs prefs) async {
    if (fail) throw Exception('offline');
    saved.add(prefs);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<void> phone(WidgetTester t, {double height = 780}) async {
  t.view.physicalSize = Size(360 * 3, height * 3);
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void main() {
  testWidgets('reset: 3 steps, masked number, tries left, then saved', (
    t,
  ) async {
    await phone(t);
    final account = FakeAccount()
      ..verifyError = FirebaseFunctionsException(
        code: 'invalid-argument',
        message: 'x',
        details: {'code': 'RESET_CODE_INVALID', 'triesLeft': 4},
      );
    await t.pumpWidget(
      ProviderScope(
        overrides: [accountRepositoryProvider.overrideWithValue(account)],
        child: MaterialApp(
          theme: buildLightTheme(),
          builder: clampTextScale,
          home: SmsResetScreen(now: () => testNow),
        ),
      ),
    );
    expect(find.text('STEP 1 OF 3'), findsOneWidget);
    expect(find.text('Your email'), findsOneWidget); // email first
    await t.tap(find.text('Use my mobile number instead'));
    await t.pump();
    await t.enterText(find.byType(TextField), '0917 12');
    await t.tap(find.text('Send the code'));
    await t.pump();
    expect(
      find.text('Enter a Philippine mobile number, for example 0917 123 4567.'),
      findsOneWidget,
    );
    await t.enterText(find.byType(TextField), '0917 123 4567');
    await t.tap(find.text('Send the code'));
    await t.pump();
    expect(account.calls, ['code 639171234567']);
    expect(find.text('STEP 2 OF 3'), findsOneWidget);
    expect(
      find.text(
        'If 0917 ••• 4567 has an account, a 6-digit code is on its way. '
        'It can take a minute.',
      ),
      findsOneWidget,
    );
    expect(find.text('Code expires in 5:00'), findsOneWidget);
    expect(find.text('Send again in 1:00'), findsOneWidget);

    await t.enterText(find.byType(TextField), '123456');
    await t.pump();
    await t.tap(find.text('Continue'));
    await t.pump();
    expect(find.text('That code is not right. 4 tries left.'), findsOneWidget);

    account.verifyError = null;
    await t.tap(find.text('Continue'));
    await t.pump();
    expect(find.text('STEP 3 OF 3'), findsOneWidget);
    await t.enterText(
      find.widgetWithText(TextField, 'New password'),
      'secret-12',
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Type it again'),
      'secret-13',
    );
    await t.tap(find.text('Save password'));
    await t.pump();
    expect(find.text("Passwords don't match."), findsOneWidget);
    await t.enterText(
      find.widgetWithText(TextField, 'Type it again'),
      'secret-12',
    );
    await t.tap(find.text('Save password'));
    await t.pump();
    expect(account.calls.last, 'set uid.token');
  });

  testWidgets(
    'reset by email code: masked address, then the same 3 steps',
    (t) async {
      await phone(t);
      final account = FakeAccount();
      await t.pumpWidget(
        ProviderScope(
          overrides: [accountRepositoryProvider.overrideWithValue(account)],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: SmsResetScreen(now: () => testNow),
          ),
        ),
      );
      expect(find.text('Your email'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'nobody');
      await t.tap(find.text('Send the code'));
      await t.pump();
      expect(find.text('Enter the email on your account.'), findsOneWidget);
      await t.enterText(find.byType(TextField), ' Ana@Example.com ');
      await t.tap(find.text('Send the code'));
      await t.pump();
      expect(account.calls, ['code email ana@example.com']);
      // Same words for any address (no account enumeration), and no link.
      expect(
        find.text(
          'If a•••@example.com has an account, a 6-digit code is on its way. '
          'It can take a minute.',
        ),
        findsOneWidget,
      );
      expect(find.text('Not in your inbox? Check spam.'), findsOneWidget);
      await t.tap(find.text('Wrong email? Go back and try again.'));
      await t.pump();
      expect(find.text('Your email'), findsOneWidget);
    },
  );

  Widget accountHarness(FakeClient client) => ProviderScope(
    overrides: [
      uidProvider.overrideWithValue('u1'),
      userProvider.overrideWith((_) => Stream.value(null)),
      repositoryProvider.overrideWithValue(client),
      accountRepositoryProvider.overrideWithValue(FakeAccount()),
      profileProvider.overrideWith(
        (_) => Stream.value(
          const UserProfile(
            displayName: 'Juan Dela Cruz',
            phone: '639171234567',
            email: 'juan@example.com',
            deviceCount: 5,
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

  testWidgets('account: profile rows and the alert defaults', (t) async {
    await phone(t);
    await t.pumpWidget(accountHarness(FakeClient()));
    await t.pumpAndSettle();
    expect(find.text('JD'), findsOneWidget);
    expect(find.text('5 devices'), findsOneWidget);
    expect(find.text('0917 123 4567'), findsOneWidget);
    expect(find.text('Change'), findsNWidgets(4));
    final sms = t.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'SMS'),
    );
    expect(sms.value, isTrue);
    final email = t.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Email'),
    );
    expect(email.value, isFalse);
  });

  testWidgets(
    'account: a switch saves; a failed save flips back with a toast',
    (t) async {
      await phone(
        t,
        height: 1600,
      ); // the whole page, so every switch is on screen
      final client = FakeClient();
      await t.pumpWidget(accountHarness(client));
      await t.pumpAndSettle();
      final email = find.widgetWithText(SwitchListTile, 'Email');
      await t.tap(email);
      await t.pumpAndSettle();
      expect(client.saved.single.toMap(), {
        'push': true,
        'sms': true,
        'email': true,
      });

      client.fail = true;
      await t.tap(find.widgetWithText(SwitchListTile, 'SMS'));
      await t.pump();
      await t.pump();
      expect(find.text("Couldn't save. Check your internet."), findsOneWidget);
      // The profile stream still says SMS on, so the switch shows on again.
      expect(
        t
            .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'SMS'))
            .value,
        isTrue,
      );
    },
  );
}
