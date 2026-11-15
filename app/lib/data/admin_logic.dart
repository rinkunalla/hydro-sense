import 'package:intl/intl.dart';

import 'admin_repository.dart';

/// The only statuses the admin sees (D24): no flow, GPS or battery.
enum AdminState { online, offline, notSetUp, removed }

AdminState stateOf(AdminDevice d) {
  if (d.removed) return AdminState.removed;
  if (!d.registered) return AdminState.notSetUp;
  return d.online ? AdminState.online : AdminState.offline;
}

/// Sort key for the devices table; `column` matches the table's column order.
Comparable<Object> sortKey(AdminDevice d, int column) => switch (column) {
  0 => d.id,
  1 => (d.label ?? '').toLowerCase(),
  2 => (d.ownerName ?? '').toLowerCase(),
  _ => stateOf(d).index,
};

/// "Nov 13" (admin tables and notes).
String dayMonth(DateTime d) => DateFormat('MMM d').format(d.toLocal());

/// "Nov 2, 2026" (Created / Admin since).
String dayMonthYear(DateTime d) =>
    DateFormat('MMM d, yyyy').format(d.toLocal());

/// Users page filter.
enum UserFilter { all, suspended }

/// Users table order: active by name, then suspended (soonest purge first).
List<AdminUser> sortUsers(List<AdminUser> users) => [...users]
  ..sort((a, b) {
    if (a.suspended != b.suspended) return a.suspended ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
