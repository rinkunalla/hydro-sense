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
final pushTapsProvider = StreamProvider<Map<String, dynamic>>(
  (ref) => ref.watch(pushServiceProvider).taps(),
);

final pushForegroundProvider = StreamProvider<ForegroundAlert>(
  (ref) => ref.watch(pushServiceProvider).foreground(),
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
  ref.listen<AsyncValue<Map<String, dynamic>>>(pushTapsProvider, (_, next) {
    final data = next.valueOrNull;
    if (data == null) return;
    final hasPipeline = ref.read(pipelineProvider).valueOrNull != null;
    ref.read(routerProvider).go(routeForPush(data, hasPipeline: hasPipeline));
  });
  // An alert while the app is open: Android shows nothing, so show it here,
  // with Open going where a tapped notification would (D37).
  ref.listen<AsyncValue<ForegroundAlert>>(pushForegroundProvider, (_, next) {
    final a = next.valueOrNull;
    if (a == null) return;
    final hasPipeline = ref.read(pipelineProvider).valueOrNull != null;
    scaffoldMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: AppConfig.foregroundAlertS),
          content: Text(a.body.isEmpty ? a.title : '${a.title}: ${a.body}'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => ref
                .read(routerProvider)
                .go(routeForPush(a.data, hasPipeline: hasPipeline)),
          ),
        ),
      );
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
