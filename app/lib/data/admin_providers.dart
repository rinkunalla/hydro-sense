import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import 'admin_repository.dart';

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => FunctionsAdminRepository(
    FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion),
  ),
);

/// adminListDevices now and every ADMIN_DEVICES_REFRESH_S after (a callable has
/// no live stream). Screens call ref.invalidate after an action to refresh at once.
final adminDevicesProvider = StreamProvider<List<AdminDevice>>((ref) async* {
  final repo = ref.watch(adminRepositoryProvider);
  yield await repo.devices();
  yield* Stream.periodic(
    const Duration(seconds: AppConfig.adminDevicesRefreshS),
  ).asyncMap((_) => repo.devices());
});

/// adminListUsers; screens invalidate it after a change.
final adminUsersProvider = FutureProvider<List<AdminUser>>(
  (ref) => ref.watch(adminRepositoryProvider).users(),
);

final adminsProvider =
    FutureProvider<({List<AdminInfo> admins, bool belowRecommended})>(
      (ref) => ref.watch(adminRepositoryProvider).admins(),
    );

final adminAuditProvider = FutureProvider<List<AuditEntry>>(
  (ref) => ref.watch(adminRepositoryProvider).audit(),
);
