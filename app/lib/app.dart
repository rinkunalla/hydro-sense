import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_router.dart';
import 'core/config.dart';
import 'core/theme.dart';
import 'router.dart';

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

class HydroSenseApp extends ConsumerWidget {
  const HydroSenseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Hydro Sense',
      theme: buildLightTheme(),
      routerConfig: ref.watch(routerProvider),
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
    return MaterialApp.router(
      title: 'Hydro Sense admin',
      theme: buildLightTheme(),
      routerConfig: ref.watch(adminRouterProvider),
      builder: clampTextScale,
      debugShowCheckedModeBanner: false,
    );
  }
}
