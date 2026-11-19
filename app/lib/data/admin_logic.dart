import 'package:intl/intl.dart';

import 'admin_repository.dart';

/// The only statuses the admin sees: no flow, GPS or battery.
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

/// Users page filter pills.
enum UserFilter { all, noPassword, deletionRequested, suspended }

bool _has(String? field, String q) => (field ?? '').toLowerCase().contains(q);

/// Users page: the pill and a search over name, mobile and email.
bool userMatches(AdminUser u, UserFilter f, String query) {
  final q = query.trim().toLowerCase();
  final digits = q.replaceAll(RegExp(r'[^0-9]'), '');
  final found =
      q.isEmpty ||
      _has(u.name, q) ||
      _has(u.email, q) ||
      // "0917 123" finds 639171234567: compare from the 9 after 63 or 0.
      (digits.length >= 3 &&
          u.phone.contains(digits.replaceFirst(RegExp(r'^(63|0)'), '')));
  return found &&
      switch (f) {
        UserFilter.all => true,
        UserFilter.noPassword => !u.passwordSet && !u.suspended,
        UserFilter.deletionRequested =>
          u.deletionRequestedAt != null && !u.suspended,
        UserFilter.suspended => u.suspended,
      };
}

/// Devices page: a search over the device ID, label and owner name.
bool deviceMatches(AdminDevice d, String query) {
  final q = query.trim().toLowerCase().replaceAll(RegExp(r'[\s:-]'), '');
  return q.isEmpty ||
      d.id.toLowerCase().contains(q) ||
      _has(d.label?.replaceAll(' ', ''), q) ||
      _has(d.ownerName?.replaceAll(' ', ''), q);
}

/// Activity log groups: the log itself is never edited or deleted.
enum AuditGroup { all, users, devices, admins, requests }

bool auditMatches(AuditEntry e, AuditGroup g, String? adminEmail) {
  final group = switch (g) {
    AuditGroup.all => true,
    AuditGroup.users => e.action.startsWith('user_'),
    AuditGroup.devices => e.action.startsWith('device_'),
    AuditGroup.admins => e.action.startsWith('admin_'),
    AuditGroup.requests => e.action == 'deletion_requested',
  };
  return group && (adminEmail == null || e.adminEmail == adminEmail);
}

/// Users table order: active by name, then suspended (soonest purge first).
List<AdminUser> sortUsers(List<AdminUser> users) => [...users]
  ..sort((a, b) {
    if (a.suspended != b.suspended) return a.suspended ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

/// One activity entry in words, as the Activity page and panels show it.
String auditSentence(AuditEntry e) {
  final who = e.adminEmail ?? 'An admin';
  final what = e.targetName ?? e.targetId ?? '';
  return switch (e.action) {
    'user_deleted' => '$who deleted the user $what',
    'user_restored' => '$who restored the user $what',
    'device_removed' => '$who removed $what',
    'device_restored' => '$who restored $what',
    'device_reassigned' => '$who reassigned $what',
    'admin_removed' => '$who removed the admin $what',
    'deletion_requested' => '$what asked to delete their account',
    _ => '$who: ${e.action} $what',
  };
}

/// Search over what the entry says: names, IDs and the admin's email.
bool auditSearch(AuditEntry e, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return [
    auditSentence(e),
    e.targetId,
    e.adminEmail,
  ].any((s) => (s ?? '').toLowerCase().contains(q));
}

/// Keeps entries from [from] (inclusive) to [to] (exclusive); null = open end.
bool auditInRange(AuditEntry e, DateTime? from, DateTime? to) {
  final at = e.at;
  if (at == null) return from == null && to == null;
  return (from == null || !at.isBefore(from)) &&
      (to == null || at.isBefore(to));
}

/// The shown entries as a CSV file (Download CSV): one header row, then one
/// row per entry, with quotes doubled inside quoted fields.
String auditCsv(List<AuditEntry> entries) {
  String cell(String? v) => '"${(v ?? '').replaceAll('"', '""')}"';
  final rows = <String>[
    '"When","Admin","Action","Target","Target ID","What happened"',
  ];
  for (final e in entries) {
    rows.add(
      [
        cell(
          e.at == null
              ? ''
              : DateFormat('yyyy-MM-dd HH:mm').format(e.at!.toLocal()),
        ),
        cell(e.adminEmail),
        cell(e.action),
        cell(e.targetName),
        cell(e.targetId),
        cell(auditSentence(e)),
      ].join(','),
    );
  }
  return '${rows.join('\r\n')}\r\n';
}

/// The Activity date dropdowns: a year, optionally a month (1 to 12),
/// optionally a day of that month. Returns [from, to) in local time.
({DateTime from, DateTime to}) calendarWindow(int year, int? month, int? day) {
  if (month == null) return (from: DateTime(year), to: DateTime(year + 1));
  if (day == null) {
    return (from: DateTime(year, month), to: DateTime(year, month + 1));
  }
  return (from: DateTime(year, month, day), to: DateTime(year, month, day + 1));
}

/// Days in [month] of [year] (for the Day dropdown).
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;
