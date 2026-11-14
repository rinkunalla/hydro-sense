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
