import '../core/config.dart';
import '../core/theme.dart';
import 'models.dart';

/// No Flow, Low Flow, Offline, then everything else; ties by nickname.
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

/// The home banner appears only for a live problem:
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

/// The Devices tab filter pills (shown from AppConfig.devicesFilterFrom devices).
enum DeviceFilter { all, problems, offline, notSetUp }

/// Keeps the devices that match [filter] and whose nickname contains [query].
List<DeviceView> filterDevices(
  Iterable<DeviceView> views,
  DeviceFilter filter,
  String query,
) {
  final q = query.trim().toLowerCase();
  return [
    for (final v in views)
      if ((q.isEmpty || v.nickname.toLowerCase().contains(q)) &&
          switch (filter) {
            DeviceFilter.all => true,
            DeviceFilter.problems => v.isProblem || v.lowBattery,
            DeviceFilter.offline => v.status == StatusKind.offline,
            DeviceFilter.notSetUp => v.status == StatusKind.notSetUp,
          })
        v,
  ];
}

/// Seconds of silence after which a device is Offline: the server's rule
/// (functions/src/lib/decisions.ts offlineAfterS).
int offlineAfterS(int? heartbeatS) {
  if (heartbeatS == null) return AppConfig.offlineAfterDefaultS;
  final s = AppConfig.offlineMissedHeartbeats * heartbeatS;
  return s < AppConfig.offlineAfterMinS ? AppConfig.offlineAfterMinS : s;
}

/// True when the device has been silent past [offlineAfterS], measured on the
/// server's clock ([serverNow] is phone time plus the database's offset), so a
/// wrong phone clock cannot mark it Offline.
bool silentTooLong(DateTime? lastSeen, int? heartbeatS, DateTime serverNow) =>
    lastSeen != null &&
    serverNow.difference(lastSeen).inSeconds >= offlineAfterS(heartbeatS);
