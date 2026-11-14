import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/providers.dart';
import 'features/admin/admin_account_screen.dart';
import 'features/admin/admin_shell.dart';
import 'features/admin/devices_admin_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/reset_password_screen.dart';
import 'router.dart' show redirectFor;

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(userProvider, (_, _) => notifyListeners());
    ref.listen(roleProvider, (_, _) => notifyListeners());
  }
}

/// The web build: admin only (CLAUDE.md section 9).
final adminRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);
  GoRoute page(String path, Widget child) => GoRoute(
    path: path,
    pageBuilder: (_, _) => NoTransitionPage(child: child),
  );
  return GoRouter(
    initialLocation: '/devices',
    refreshListenable: refresh,
    redirect: (context, state) {
      final role = ref.read(roleProvider);
      return redirectFor(
        location: state.uri.toString(),
        signedIn: ref.read(userProvider).valueOrNull != null,
        roleLoaded: role.hasValue || role.hasError,
        role: role.valueOrNull,
        profileLoaded: true,
        requiredRole: 'admin',
        home: '/devices',
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
        path: '/loading',
        builder: (_, _) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      ShellRoute(
        builder: (_, state, child) =>
            AdminShell(location: state.uri.path, child: child),
        routes: [
          page('/devices', const DevicesAdminScreen()),
          page('/account', const AdminAccountScreen()),
        ],
      ),
    ],
    debugLogDiagnostics: kDebugMode,
  );
});
