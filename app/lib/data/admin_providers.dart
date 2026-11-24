import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import 'admin_repository.dart';

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => FunctionsAdminRepository(
    FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion),
  ),
);

/// adminListStaff; screens invalidate it after a change.
final staffProvider = FutureProvider<List<StaffMember>>(
  (ref) => ref.watch(adminRepositoryProvider).staff(),
);

final adminsProvider =
    FutureProvider<({List<AdminInfo> admins, bool belowRecommended})>(
      (ref) => ref.watch(adminRepositoryProvider).admins(),
    );
