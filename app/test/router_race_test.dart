// Signing in must never be refused while the role is still being read.
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/theme.dart';
import 'package:hydro_sense/data/models.dart';
import 'package:hydro_sense/data/providers.dart';
import 'package:hydro_sense/router.dart';

class FakeUser implements User {
  @override
  String get uid => 'u1';

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets('a slow role read after sign-in waits on Loading, not refusal', (
    t,
  ) async {
    final user = StreamController<User?>();
    addTearDown(user.close);
    final roleReady = Completer<String?>();
    final c = ProviderContainer(
      overrides: [
        userProvider.overrideWith((ref) => user.stream),
        // Like the real one: null while signed out, then the token's claim.
        roleProvider.overrideWith((ref) async {
          final u = ref.watch(userProvider).valueOrNull;
          if (u == null) return null;
          return roleReady.future;
        }),
        profileProvider.overrideWith(
          (ref) => Stream.value(const UserProfile(displayName: 'Ana')),
        ),
        fleetProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(c.dispose);
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: c.read(routerProvider),
        ),
      ),
    );
    user.add(null); // signed out: the role is "none"
    await t.pump();
    await t.pump();
    final router = c.read(routerProvider);
    expect(router.state.uri.path, '/login');

    user.add(FakeUser()); // signs in; the role is still being read
    await t.pump();
    await t.pump();
    expect(router.state.uri.queryParameters['refused'], isNull);
    expect(router.state.uri.path, '/loading');

    roleReady.complete('user');
    await t.pump();
    await t.pump();
    expect(router.state.uri.path, '/devices');
  });
}
