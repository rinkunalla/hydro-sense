import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config.dart';
import 'data/providers.dart';
import 'features/admin/admin_account_screen.dart';
import 'features/admin/admin_setup_screen.dart';
import 'features/admin/admin_shell.dart';
import 'features/admin/dashboard_screen.dart';
import 'features/admin/staff_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/client/device_detail_screen.dart';
import 'features/client/devices_screen.dart';
import 'features/client/edit_pipeline_screen.dart';
import 'features/client/history_screen.dart';
import 'features/auth/reset_password_screen.dart';
import 'router.dart' show redirectFor;

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(userProvider, (_, _) => notifyListeners());
    ref.listen(roleProvider, (_, _) => notifyListeners());
  }
}

/// The app's History calendar was laid out for a phone; on a wide screen its
/// day cells stretch into a very tall grid, so the website keeps it narrow.
Widget _readable(Widget child) => Align(
  alignment: Alignment.topCenter,
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: AppConfig.adminReadableWidth),
    child: child,
  ),
);

/// The web build: admin only (D63, D67). The monitoring pages are the app's
/// own screens on the same paths (/devices, /devices/:id, /devices/history,
/// /map/edit; /map opens the dashboard's map), so their links work unchanged
/// inside the admin shell.
final adminRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);
  GoRoute page(String path, Widget child) => GoRoute(
    path: path,
    pageBuilder: (_, _) => NoTransitionPage(child: child),
  );
  return GoRouter(
    initialLocation: '/dashboard',
    refreshListenable: refresh,
    redirect: (context, state) {
      final role = ref.read(roleProvider);
      return redirectFor(
        location: state.uri.toString(),
        signedIn: ref.read(userProvider).valueOrNull != null,
        // Not while it reloads: after a sign-in the role briefly still holds
        // the signed-out "none", which would refuse the account.
        roleLoaded: !role.isLoading && (role.hasValue || role.hasError),
        role: role.valueOrNull,
        profileLoaded: true,
        requiredRole: 'admin',
        home: '/dashboard',
      );
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, s) => LoginScreen(
          key: ValueKey(s.uri.queryParameters['refused']),
          refused: s.uri.queryParameters['refused'],
          admin: true,
        ),
      ),
      GoRoute(path: '/reset', builder: (_, _) => const ResetPasswordScreen()),
      // The emailed setup link carries ?token=; without it, ask for a link.
      GoRoute(
        path: '/setup',
        builder: (_, s) {
          final token = s.uri.queryParameters['token'];
          return token == null || token.isEmpty
              ? const AdminSetupRequestScreen()
              : AdminSetPasswordScreen(token: token);
        },
      ),
      GoRoute(
        path: '/loading',
        builder: (_, _) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      ShellRoute(
        builder: (_, state, child) =>
            AdminShell(location: state.uri.path, child: child),
        routes: [
          // The map is the dashboard (2026-11-25): /dashboard?device=ID or
          // ?focus=problem centres it, as /map did.
          GoRoute(
            path: '/dashboard',
            pageBuilder: (_, s) => NoTransitionPage(
              key: ValueKey(s.uri.query),
              child: DashboardScreen(
                focusProblem: s.uri.queryParameters['focus'] == 'problem',
                focusDevice: s.uri.queryParameters['device'],
              ),
            ),
          ),
          // The app's screens still link to /map ("Show on map", leaving the
          // pipeline editor); on the website that is the dashboard. The
          // editor keeps its own page.
          GoRoute(
            path: '/map',
            redirect: (_, s) => s.uri.path == '/map'
                ? '/dashboard${s.uri.hasQuery ? '?${s.uri.query}' : ''}'
                : null,
            routes: [
              GoRoute(
                path: 'edit',
                builder: (_, _) => const EditPipelineScreen(),
              ),
            ],
          ),
          GoRoute(
            path: '/devices',
            pageBuilder: (_, _) =>
                const NoTransitionPage(child: DevicesScreen()),
            routes: [
              // Before ':id', so /devices/history is not read as a device ID.
              GoRoute(
                path: 'history',
                builder: (_, s) => _readable(
                  HistoryScreen(deviceId: s.uri.queryParameters['device']),
                ),
              ),
              GoRoute(
                path: ':id',
                builder: (_, s) =>
                    DeviceDetailScreen(deviceId: s.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/history',
            pageBuilder: (_, s) => NoTransitionPage(
              child: _readable(
                HistoryScreen(deviceId: s.uri.queryParameters['device']),
              ),
            ),
          ),
          page('/staff', const StaffScreen()),
          page('/account', const AdminAccountScreen()),
        ],
      ),
    ],
    debugLogDiagnostics: kDebugMode,
  );
});
