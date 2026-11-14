import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/glass.dart';
import 'data/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/sms_reset_screen.dart';
import 'features/client/phone_change_screen.dart';
import 'features/client/account_screen.dart';
import 'features/client/device_detail_screen.dart';
import 'features/client/devices_screen.dart';
import 'features/client/home_shell.dart';
import 'features/client/edit_pipeline_screen.dart';
import 'features/client/map_screen.dart';

/// Where the person should be, given auth state (pure, unit-tested).
/// Android is user-only and the web build admin-only (CLAUDE.md D21):
/// any other role goes back to Login with `refused` set.
String? redirectFor({
  required String location,
  required bool signedIn,
  required bool roleLoaded,
  required String? role,
  required bool profileLoaded,
  String requiredRole = 'user',
  String home = '/devices',
}) {
  final onAuthPage = location == '/login' || location == '/reset';
  if (!signedIn) return onAuthPage ? null : '/login';
  if (!roleLoaded) return location == '/loading' ? null : '/loading';
  if (role != requiredRole) {
    final reason = requiredRole == 'admin'
        ? 'notadmin'
        : (role == 'admin' ? 'admin' : 'other');
    return location.startsWith('/login') ? null : '/login?refused=$reason';
  }
  if (requiredRole == 'user' && !profileLoaded) {
    return location == '/loading' ? null : '/loading';
  }
  if (onAuthPage || location == '/loading') {
    return home;
  }
  return null;
}

/// Re-runs the redirect when auth, role or profile changes.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(userProvider, (_, _) => notifyListeners());
    ref.listen(roleProvider, (_, _) => notifyListeners());
    ref.listen(profileProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/devices',
    refreshListenable: refresh,
    redirect: (context, state) {
      final user = ref.read(userProvider);
      final role = ref.read(roleProvider);
      final profile = ref.read(profileProvider);
      return redirectFor(
        location: state.uri.toString(),
        signedIn: user.valueOrNull != null,
        roleLoaded: role.hasValue || role.hasError,
        role: role.valueOrNull,
        profileLoaded: profile.hasValue || profile.hasError,
      );
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, s) =>
            LoginScreen(refused: s.uri.queryParameters['refused']),
      ),
      GoRoute(path: '/reset', builder: (_, _) => const SmsResetScreen()),
      GoRoute(
        path: '/loading',
        builder: (_, _) => const AppBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/devices',
                builder: (_, _) => const DevicesScreen(),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (_, s) =>
                        DeviceDetailScreen(deviceId: s.pathParameters['id']!),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/map',
                builder: (_, s) => MapScreen(
                  focusProblem: s.uri.queryParameters['focus'] == 'problem',
                ),
                routes: [
                  GoRoute(
                    path: 'edit',
                    builder: (_, _) => const EditPipelineScreen(),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/account',
                builder: (_, _) => const AccountScreen(),
                routes: [
                  GoRoute(
                    path: 'phone',
                    builder: (_, _) => const PhoneChangeScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
    debugLogDiagnostics: kDebugMode,
  );
});
