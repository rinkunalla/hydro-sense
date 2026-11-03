import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import 'admin_logic.dart';
import 'admin_repository.dart';
import 'models.dart' show Health;

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => FirestoreAdminRepository(
    FirebaseFirestore.instance,
    FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion),
  ),
);

final healthListProvider = StreamProvider<List<Health>>(
  (ref) => ref.watch(adminRepositoryProvider).health(),
);

final allowedProvider = StreamProvider<List<AllowedEntry>>(
  (ref) => ref.watch(adminRepositoryProvider).allowed(),
);

final removedProvider = StreamProvider<List<RemovedEntry>>(
  (ref) => ref.watch(adminRepositoryProvider).removed(),
);

/// The newest errors, for each row's "last error" column.
final recentErrorsProvider = StreamProvider<List<ErrorEntry>>(
  (ref) => ref.watch(adminRepositoryProvider).errors(limit: 200),
);

final diagnosticsProvider = StreamProvider<Diagnostics?>(
  (ref) => ref.watch(adminRepositoryProvider).diagnostics(),
);

final clientInfoProvider = StreamProvider<ClientInfo?>(
  (ref) => ref.watch(adminRepositoryProvider).client(),
);

final batteryHistoryProvider =
    StreamProvider.family<List<BatteryPoint>, String>(
      (ref, id) => ref
          .watch(adminRepositoryProvider)
          .batteryHistory(
            id,
            const Duration(days: AppConfig.batteryHistoryDays),
          ),
    );

typedef ErrorFilter = ({String? deviceId, String? code, int pages});

final errorPageProvider = StreamProvider.family<List<ErrorEntry>, ErrorFilter>(
  (ref, f) => ref
      .watch(adminRepositoryProvider)
      .errors(
        deviceId: f.deviceId,
        code: f.code,
        limit: f.pages * AppConfig.errorLogsPageSize,
      ),
);

/// Table rows; loading until health, allowlist and removed list have all arrived.
final adminRowsProvider = Provider<AsyncValue<List<AdminRow>>>((ref) {
  final h = ref.watch(healthListProvider);
  final a = ref.watch(allowedProvider);
  final r = ref.watch(removedProvider);
  final e = ref.watch(recentErrorsProvider);
  for (final v in [h, a, r]) {
    if (v.hasError) {
      return AsyncValue.error(v.error!, v.stackTrace ?? StackTrace.empty);
    }
  }
  if (!h.hasValue || !a.hasValue || !r.hasValue) {
    return const AsyncValue.loading();
  }
  return AsyncValue.data(
    buildRows(h.value!, a.value!, r.value!, e.valueOrNull ?? const []),
  );
});
