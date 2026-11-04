import '../core/config.dart';
import 'admin_repository.dart';
import 'models.dart' show Health;

enum AdminState { online, offline, sleeping, waiting }

/// One row of the admin devices table: a registered device's health, or an
/// allowlisted ID that has not registered yet.
class AdminRow {
  const AdminRow(this.id, this.health, {this.lastError});

  final String id;
  final Health? health;
  final ErrorEntry? lastError;

  AdminState get state {
    final h = health;
    if (h == null) return AdminState.waiting;
    if (h.online) return AdminState.online;
    if (h.lowVoltageSleep) return AdminState.sleeping;
    return h.lastSeen == null ? AdminState.waiting : AdminState.offline;
  }

  bool get lowBattery {
    final h = health;
    return h != null &&
        !h.batteryFault &&
        h.batteryPercent != null &&
        h.batteryPercent! < AppConfig.lowBatteryPercent;
  }
}

/// Registered devices plus allowlisted IDs not yet registered (UI_UX_SPEC section 5).
List<AdminRow> buildRows(
  List<Health> health,
  List<AllowedEntry> allowed,
  List<RemovedEntry> removed,
  List<ErrorEntry> recentErrors,
) {
  final removedIds = {for (final r in removed) r.id};
  final latestError = <String, ErrorEntry>{};
  for (final e in recentErrors) {
    final id = e.deviceId;
    if (id == null) continue;
    final cur = latestError[id];
    if (cur == null ||
        (e.ts != null && cur.ts != null && e.ts!.isAfter(cur.ts!))) {
      latestError[id] = e;
    }
  }
  final ids = {for (final h in health) h.id};
  return [
    for (final h in health) AdminRow(h.id, h, lastError: latestError[h.id]),
    for (final a in allowed)
      if (!ids.contains(a.id) && !removedIds.contains(a.id))
        AdminRow(a.id, null),
  ];
}

class AdminCounters {
  const AdminCounters({
    required this.registered,
    required this.online,
    required this.offline,
    required this.lowBattery,
  });

  final int registered;
  final int online;
  final int offline;
  final int lowBattery;
}

AdminCounters countersFor(List<AdminRow> rows) {
  final registered = rows.where((r) => r.health != null).toList();
  return AdminCounters(
    registered: registered.length,
    online: registered.where((r) => r.state == AdminState.online).length,
    offline: registered
        .where(
          (r) =>
              r.state == AdminState.offline || r.state == AdminState.sleeping,
        )
        .length,
    lowBattery: registered.where((r) => r.lowBattery).length,
  );
}

/// Sort key for the devices table; `column` matches the table's column order.
Comparable<Object> sortKey(AdminRow r, int column) => switch (column) {
  0 => r.id,
  1 => r.state.index,
  2 => r.health?.lastSeen?.millisecondsSinceEpoch ?? 0,
  3 => r.health?.batteryPercent ?? -1,
  4 => r.health?.chargingStatus ?? '',
  5 => r.health?.firmware ?? '',
  _ => r.lastError?.code ?? '',
};

/// Pack voltage at a battery percent (inverse of the D2 formula).
double packVoltageAtPercent(
  int percent, {
  int cells = AppConfig.batterySeriesCells,
}) => cells * (3.3 + 0.9 * percent / 100);

/// The firmware's low-voltage sleep level for the whole pack.
double get lowVoltageSleepPackV =>
    AppConfig.lowVoltageSleepCellV * AppConfig.batterySeriesCells;
