import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/glass.dart';
import 'data/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/client/account_screen.dart';
import 'features/client/device_detail_screen.dart';
import 'features/client/devices_screen.dart';
import 'features/client/history_screen.dart';
import 'features/client/home_shell.dart';
import 'features/client/edit_pipeline_screen.dart';
import 'features/client/map_screen.dart';

/// Where the person should be, given auth state (pure, unit-tested).
/// Android is user-only and the web build admin-only:
/// any other role goes back to Login with `refused` set. The phone signs out
/// on every fresh start, so a screen asked for while signed out (a
/// tapped alert) rides along as `next` and opens after the sign-in.
String? redirectFor({
  required String location,
  required bool signedIn,
  required bool roleLoaded,
  required String? role,
  required bool profileLoaded,
  String requiredRole = 'user',
  String home = '/devices',
}) {
  final uri = Uri.parse(location);
  final path = uri.path;
  // /reset and /setup are the admin website's (emailed reset link, first-time
  // setup); the phone app has neither route (staff ask the admin, D64).
  final onAuthPage =
      path == '/login' || path == '/reset' || path.startsWith('/setup');
  final carried = uri.queryParameters['next'];
  final next =
      carried != null &&
          carried.startsWith('/') &&
          !carried.startsWith('//') &&
          !carried.startsWith('/login') &&
          !carried.startsWith('/loading')
      ? carried
      : null;
  // The page to come back to after Loading: one already carried, else the
  // page asked for (a reload of /devices stays on /devices).
  final back = next ?? (onAuthPage || path == '/loading' ? null : location);
  String withNext(String to) =>
      back == null ? to : '$to?next=${Uri.encodeComponent(back)}';

  if (!signedIn) {
    if (onAuthPage) return null;
    final keep = path != '/loading' && location != home;
    return keep ? '/login?next=${Uri.encodeComponent(location)}' : '/login';
  }
  if (!roleLoaded) return path == '/loading' ? null : withNext('/loading');
  if (role != requiredRole) {
    final reason = requiredRole == 'admin'
        ? 'notadmin'
        : (role == 'admin' ? 'admin' : 'other');
    return path == '/login' && uri.queryParameters['refused'] != null
        ? null
        : '/login?refused=$reason';
  }
  if (requiredRole == 'user' && !profileLoaded) {
    return path == '/loading' ? null : withNext('/loading');
  }
  if (onAuthPage || path == '/loading') return next ?? home;
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
        // Not while it reloads: after a sign-in the role briefly still holds
        // the signed-out "none", which would refuse the account.
        roleLoaded: !role.isLoading && (role.hasValue || role.hasError),
        role: role.valueOrNull,
        profileLoaded:
            !profile.isLoading && (profile.hasValue || profile.hasError),
      );
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, s) =>
            // Keyed by the reason, so a refusal on this same page still shows.
            LoginScreen(
              key: ValueKey(s.uri.queryParameters['refused']),
              refused: s.uri.queryParameters['refused'],
            ),
      ),
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
                  // Before ':id', so /devices/history is not read as a device ID.
                  GoRoute(
                    path: 'history',
                    builder: (_, s) => HistoryScreen(
                      deviceId: s.uri.queryParameters['device'],
                    ),
                  ),
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
                  focusDevice: s.uri.queryParameters['device'],
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
              ),
            ],
          ),
        ],
      ),
    ],
    debugLogDiagnostics: kDebugMode,
  );
});
