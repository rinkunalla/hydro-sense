import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/reset_password_screen.dart';
import 'features/auth/set_password_screen.dart';
import 'features/client/account_screen.dart';
import 'features/client/device_detail_screen.dart';
import 'features/client/devices_screen.dart';
import 'features/client/home_shell.dart';
import 'features/client/map_screen.dart';

/// Where the person should be, given auth state (pure, unit-tested).
/// Android is client-only (CLAUDE.md section 9): other roles go back to Login.
String? redirectFor({
  required String location,
  required bool signedIn,
  required bool roleLoaded,
  required String? role,
  required bool profileLoaded,
  required bool mustChangePassword,
}) {
  final onAuthPage = location == '/login' || location == '/reset';
  if (!signedIn) return onAuthPage ? null : '/login';
  if (!roleLoaded) return location == '/loading' ? null : '/loading';
  if (role != 'client') {
    final target = '/login?refused=${role == 'admin' ? 'admin' : 'other'}';
    return location.startsWith('/login') ? null : target;
  }
  if (!profileLoaded) return location == '/loading' ? null : '/loading';
  if (mustChangePassword) {
    return location == '/set-password' ? null : '/set-password';
  }
  if (onAuthPage || location == '/loading' || location == '/set-password') {
    return '/devices';
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
        mustChangePassword: profile.valueOrNull?.mustChangePassword ?? false,
      );
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, s) =>
            LoginScreen(refused: s.uri.queryParameters['refused']),
      ),
      GoRoute(path: '/reset', builder: (_, _) => const ResetPasswordScreen()),
      GoRoute(
        path: '/set-password',
        builder: (_, _) => const SetPasswordScreen(),
      ),
      GoRoute(
        path: '/loading',
        builder: (_, _) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
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
              GoRoute(path: '/map', builder: (_, _) => const MapScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/account',
                builder: (_, _) => const AccountScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
    debugLogDiagnostics: kDebugMode,
  );
});
