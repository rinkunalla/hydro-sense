import 'package:intl/intl.dart';

/// "12 s ago", "4 min ago", "2 h ago"; "just now" when the server clock is ahead
/// of the phone. The phone clock never decides Offline.
String relativeAge(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inSeconds < 5) return 'just now';
  if (d.inSeconds < 60) return '${d.inSeconds} s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// "12 s", "4 min", "2 h" for the Live cue on a card.
String shortAge(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inSeconds < 5) return 'now';
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) return '${d.inHours} h';
  return '${d.inDays} d';
}

/// "0917 123 4567" from 639171234567.
String displayPhone(String? p) {
  if (p == null || p.length != 12 || !p.startsWith('63')) return p ?? '-';
  final local = '0${p.substring(2)}';
  return '${local.substring(0, 4)} ${local.substring(4, 7)} ${local.substring(7)}';
}

/// "3:12 PM" today, "Nov 2, 3:12 PM" otherwise, in the phone's local zone.
String clockTime(DateTime t, DateTime now) {
  final local = t.toLocal();
  final n = now.toLocal();
  final sameDay =
      local.year == n.year && local.month == n.month && local.day == n.day;
  return sameDay
      ? DateFormat('h:mm a', 'en_US').format(local)
      : DateFormat('MMM d, h:mm a', 'en_US').format(local);
}

/// "9 min" / "42 min" / "1 h 5 min" for cooldown captions.
String waitText(Duration d) {
  final minutes = (d.inSeconds / 60).ceil();
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}
