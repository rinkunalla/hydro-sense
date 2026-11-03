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

/// The summary banner that answers "is water flowing to every area?" first.
BannerInfo bannerFor(List<DeviceView> views) {
  if (views.isEmpty) {
    return const BannerInfo(StatusKind.waiting, 'No devices yet.');
  }
  final sorted = sortForHome(views);
  final problems = sorted.where((v) => v.isProblem).toList();
  if (problems.isNotEmpty) {
    final worst = problems.first;
    final word = StatusStyle.of(worst.status).word;
    final n = problems.length;
    final text = n == 1
        ? '1 area needs attention: ${worst.nickname} ($word)'
        : '$n areas need attention, including ${worst.nickname} ($word)';
    return BannerInfo(worst.status, text);
  }
  final reporting = views.where((v) => v.status != StatusKind.offline).toList();
  if (reporting.isEmpty) {
    return const BannerInfo(
      StatusKind.offline,
      'No device is reporting right now.',
    );
  }
  final normal = views.where((v) => v.status == StatusKind.normal).length;
  final offline = views.length - reporting.length;
  if (offline > 0) {
    return BannerInfo(
      StatusKind.offline,
      '$offline ${offline == 1 ? 'area is' : 'areas are'} offline. $normal with normal flow.',
    );
  }
  if (normal == views.length) {
    return BannerInfo(
      StatusKind.normal,
      views.length == 1
          ? 'The area has normal flow.'
          : 'All ${views.length} areas have normal flow.',
    );
  }
  return const BannerInfo(
    StatusKind.waiting,
    'Waiting for the first readings.',
  );
}

/// The AI summary is stale when any device changed status after it was written.
bool summaryIsStale(Summary? s, List<DeviceView> views) {
  final updated = s?.lastUpdated;
  if (updated == null) return false;
  return views.any((v) {
    final changed = v.device.statusChangedAt;
    return changed != null && changed.isAfter(updated);
  });
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
