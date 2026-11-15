import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/providers.dart';
import 'features/admin/admin_account_screen.dart';
import 'features/admin/admin_setup_screen.dart';
import 'features/admin/admin_shell.dart';
import 'features/admin/devices_admin_screen.dart';
import 'features/admin/users_screen.dart';
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
    initialLocation: '/users',
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
        home: '/users',
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
          page('/users', const UsersScreen()),
          page('/devices', const DevicesAdminScreen()),
          page('/account', const AdminAccountScreen()),
        ],
      ),
    ],
    debugLogDiagnostics: kDebugMode,
  );
});
