import 'package:intl/intl.dart';

import '../core/theme.dart';
import 'admin_repository.dart';
import 'models.dart';

/// "Nov 13" (admin tables and notes).
String dayMonth(DateTime d) => DateFormat('MMM d').format(d.toLocal());

/// "Nov 2, 2026" (Created / Admin since).
String dayMonthYear(DateTime d) =>
    DateFormat('MMM d, yyyy').format(d.toLocal());

bool _has(String? field, String q) => (field ?? '').toLowerCase().contains(q);

/// Staff page: a search over name, username, mobile and email.
bool staffMatches(StaffMember s, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final digits = q.replaceAll(RegExp(r'[^0-9]'), '');
  return _has(s.name, q) ||
      _has(s.username, q) ||
      _has(s.email, q) ||
      // "0917 123" finds 639171234567: compare from the 9 after 63 or 0.
      (digits.length >= 3 &&
          (s.phone ?? '').contains(
            digits.replaceFirst(RegExp(r'^(63|0)'), ''),
          ));
}

/// Staff table order: active by name, then disabled by name.
List<StaffMember> sortStaff(List<StaffMember> staff) =>
    [...staff]..sort((a, b) {
      if (a.disabled != b.disabled) return a.disabled ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

/// The Dashboard's counts (D67): how many devices are in each state now.
class StatusCounts {
  const StatusCounts({
    this.normal = 0,
    this.lowFlow = 0,
    this.noFlow = 0,
    this.offline = 0,
    this.other = 0,
  });

  final int normal;
  final int lowFlow;
  final int noFlow;
  final int offline;

  /// Not set up yet, or waiting for a first reading.
  final int other;

  int get total => normal + lowFlow + noFlow + offline + other;
}

StatusCounts countStatuses(Iterable<DeviceView> views) {
  var n = 0, low = 0, no = 0, off = 0, other = 0;
  for (final v in views) {
    switch (v.status) {
      case StatusKind.normal:
        n++;
      case StatusKind.lowFlow:
        low++;
      case StatusKind.noFlow:
        no++;
      case StatusKind.offline:
        off++;
      default:
        other++;
    }
  }
  return StatusCounts(
    normal: n,
    lowFlow: low,
    noFlow: no,
    offline: off,
    other: other,
  );
}

/// The devices that need attention now, worst first (No water, Low flow,
/// Offline), then by name: the Dashboard list and the website's banner.
List<DeviceView> needAttention(Iterable<DeviceView> views) {
  int rank(StatusKind k) => switch (k) {
    StatusKind.noFlow => 0,
    StatusKind.lowFlow => 1,
    StatusKind.offline => 2,
    _ => 9,
  };
  return views.where((v) => rank(v.status) < 9).toList()..sort((a, b) {
    final r = rank(a.status).compareTo(rank(b.status));
    return r != 0
        ? r
        : a.nickname.toLowerCase().compareTo(b.nickname.toLowerCase());
  });
}

/// History as a CSV file (Download CSV): one header row, then one row per
/// problem, with quotes doubled inside quoted fields.
String problemsCsv(List<Problem> problems, Map<String, String> names) {
  String cell(String? v) => '"${(v ?? '').replaceAll('"', '""')}"';
  String time(DateTime? t) =>
      t == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(t.toLocal());
  final rows = <String>['"Device","Device ID","Problem","Started","Ended"'];
  for (final p in problems) {
    rows.add(
      [
        cell(names[p.deviceId] ?? p.deviceId),
        cell(p.deviceId),
        cell(switch (p.type) {
          ProblemType.noFlow => 'No water',
          ProblemType.lowFlow => 'Low flow',
          ProblemType.offline => 'Offline',
          ProblemType.batteryLow => 'Low battery',
        }),
        cell(time(p.startedAt)),
        cell(p.ongoing ? 'Ongoing' : time(p.endedAt)),
      ].join(','),
    );
  }
  return rows.join('\r\n');
}
