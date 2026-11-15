// Show/hide on every password (NIST SP 800-63B) and sign-in wording (OWASP).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/errors.dart';
import 'package:hydro_sense/core/password_field.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/features/auth/login_screen.dart';

void main() {
  test('tips: only the length is required, the rest are suggestions', () {
    List<bool> met(String p) => [for (final t in passwordTips(p)) t.met];
    expect(met(''), [false, false, false, false, false]);
    expect(met('abcdefgh'), [true, false, true, false, false]);
    expect(met('Abcdef1!'), [true, true, true, true, true]);
    expect(met('ABC 123'), [false, true, false, true, false]);
    expect(
      [for (final t in passwordTips('')) t.required],
      [true, false, false, false, false],
    );
  });

  testWidgets('a new password shows live tips', (t) async {
    final c = TextEditingController();
    await t.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: PasswordField(
            controller: c,
            label: 'New password',
            showTips: true,
          ),
        ),
      ),
    );
    expect(find.text('Stronger with:'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    await t.enterText(find.byType(TextField), 'Abcdef1!');
    await t.pump();
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(5));
  });

  testWidgets('the eye shows and hides the password', (t) async {
    final c = TextEditingController(text: 'secret-12');
    await t.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: PasswordField(controller: c, label: 'Password'),
        ),
      ),
    );
    TextField field() => t.widget<TextField>(find.byType(TextField));
    expect(field().obscureText, isTrue);
    await t.tap(find.byTooltip('Show password'));
    await t.pump();
    expect(field().obscureText, isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await t.tap(find.byTooltip('Hide password'));
    await t.pump();
    expect(field().obscureText, isTrue);
  });

  testWidgets('sign-in asks for both fields before trying', (t) async {
    t.view.physicalSize = const Size(360 * 3, 780 * 3);
    t.view.devicePixelRatio = 3;
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: buildLightTheme(), home: const LoginScreen()),
      ),
    );
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(find.text(Messages.enterBoth), findsOneWidget);
    // Every password box on the screen has the eye.
    expect(find.byTooltip('Show password'), findsOneWidget);
  });
}
