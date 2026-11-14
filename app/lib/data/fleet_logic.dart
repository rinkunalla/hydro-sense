import '../core/theme.dart';
import 'models.dart';

/// No Flow, Low Flow, Offline, then everything else; ties by nickname
/// (docs/UI_UX_SPEC.md section 4.2).
List<DeviceView> sortForHome(Iterable<DeviceView> views) {
  int rank(StatusKind s) => switch (s) {
    StatusKind.noFlow => 0,
    StatusKind.lowFlow => 1,
    StatusKind.offline => 2,
    _ => 3,
  };
  final list = views.toList();
  list.sort((a, b) {
    final r = rank(a.status).compareTo(rank(b.status));
    return r != 0
        ? r
        : a.nickname.toLowerCase().compareTo(b.nickname.toLowerCase());
  });
  return list;
}

class BannerInfo {
  const BannerInfo(this.kind, this.text);

  final StatusKind kind;
  final String text;
}

/// The home banner appears only for a live problem (docs/UI_UX_SPEC.md 4.1):
/// it names the worst one, how long ago it started, and "+k more". Null when
/// nothing is wrong.
BannerInfo? problemBanner(List<DeviceView> views, DateTime now) {
  final problems = sortForHome(views).where((v) => v.isProblem).toList();
  if (problems.isEmpty) return null;
  final worst = problems.first;
  final since = worst.since;
  final ago = since == null ? null : agoText(now.difference(since));
  final head = worst.status == StatusKind.noFlow
      ? 'No water on ${worst.nickname}'
      : 'Low water flow on ${worst.nickname}';
  final tail = ago == null
      ? ''
      : worst.status == StatusKind.noFlow
      ? ' · It stopped $ago ago'
      : ' · It started $ago ago';
  final more = problems.length > 1 ? ' · +${problems.length - 1} more' : '';
  return BannerInfo(worst.status, '$head$tail$more');
}

/// "6 minutes", "1 minute", "2 hours" for the banner sentence.
String agoText(Duration d) {
  if (d.inMinutes < 1) return 'less than a minute';
  if (d.inMinutes < 60) {
    return d.inMinutes == 1 ? '1 minute' : '${d.inMinutes} minutes';
  }
  return d.inHours == 1 ? '1 hour' : '${d.inHours} hours';
}

/// Polite screen-reader announcements for cards that newly entered No Flow.
List<String> newlyNoFlow(List<DeviceView> before, List<DeviceView> after) {
  final was = {for (final v in before) v.id: v.status};
  return [
    for (final v in after)
      if (v.status == StatusKind.noFlow &&
          was.containsKey(v.id) &&
          was[v.id] != StatusKind.noFlow)
        '${v.nickname}, no flow',
  ];
}
