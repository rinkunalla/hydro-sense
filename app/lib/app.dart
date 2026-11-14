import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_router.dart';
import 'core/config.dart';
import 'core/errors.dart';
import 'core/theme.dart';
import 'data/providers.dart';
import 'data/push.dart';
import 'router.dart';

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Keeps text readable up to the 1.5x OS scale the layouts are tested at.
Widget clampTextScale(BuildContext context, Widget? child) {
  final mq = MediaQuery.of(context);
  return MediaQuery(
    data: mq.copyWith(
      textScaler: mq.textScaler.clamp(maxScaleFactor: AppConfig.maxTextScale),
    ),
    child: child ?? const SizedBox.shrink(),
  );
}

/// An expired or revoked session: the router returns to Login, and this adds
/// "Please sign in again." (docs/UI_UX_SPEC.md section 4.2).
void watchSession(WidgetRef ref) {
  ref.listen<AsyncValue<User?>>(userProvider, (prev, next) {
    if (prev?.valueOrNull == null || next.valueOrNull != null) return;
    final explicit = ref.read(explicitSignOutProvider);
    ref.read(explicitSignOutProvider.notifier).state = false;
    if (!explicit) {
      scaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text(Messages.signInAgain)),
      );
    }
  });
}

/// Phone app only: registers for push once a user is signed in (D27), and opens
/// the screen a tapped notification points to (D37).
final pushTapsProvider = StreamProvider<String>(
  (ref) => ref.watch(pushServiceProvider).taps(),
);

void watchPush(WidgetRef ref) {
  ref.listen<AsyncValue<String?>>(roleProvider, (prev, next) {
    final uid = ref.read(authProvider).currentUser?.uid;
    if (next.valueOrNull == 'user' &&
        prev?.valueOrNull != 'user' &&
        uid != null) {
      ref.read(pushServiceProvider).start(uid);
    }
  });
  ref.listen<AsyncValue<String>>(pushTapsProvider, (_, next) {
    final route = next.valueOrNull;
    if (route != null) ref.read(routerProvider).go(route);
  });
}

class HydroSenseApp extends ConsumerWidget {
  const HydroSenseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    watchSession(ref);
    watchPush(ref);
    return MaterialApp.router(
      title: 'Hydro Sense',
      theme: buildLightTheme(),
      routerConfig: ref.watch(routerProvider),
      scaffoldMessengerKey: scaffoldMessengerKey,
      builder: clampTextScale,
      debugShowCheckedModeBanner: false,
    );
  }
}

/// The web build is the admin website.
class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    watchSession(ref);
    return MaterialApp.router(
      title: 'Hydro Sense admin',
      theme: buildLightTheme(),
      routerConfig: ref.watch(adminRouterProvider),
      scaffoldMessengerKey: scaffoldMessengerKey,
      builder: clampTextScale,
      debugShowCheckedModeBanner: false,
    );
  }
}
