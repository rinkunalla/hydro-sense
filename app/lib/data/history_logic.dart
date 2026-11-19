// Pure logic for the Details status strip and the History calendar.
import 'models.dart';

/// What a stretch of the status strip shows.
enum StripKind { normal, lowFlow, noFlow, offline, unknown }

class StripSegment {
  const StripSegment(this.kind, this.from, this.to);

  final StripKind kind;
  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) =>
      other is StripSegment &&
      other.kind == kind &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(kind, from, to);

  @override
  String toString() => 'StripSegment($kind, $from, $to)';
}

/// Higher wins where problems overlap: Offline hides the flow state.
int _rank(StripKind k) => switch (k) {
  StripKind.offline => 4,
  StripKind.noFlow => 3,
  StripKind.lowFlow => 2,
  StripKind.unknown => 1,
  StripKind.normal => 0,
};

StripKind? _stripKind(ProblemType t) => switch (t) {
  ProblemType.noFlow => StripKind.noFlow,
  ProblemType.lowFlow => StripKind.lowFlow,
  ProblemType.offline => StripKind.offline,
  ProblemType.batteryLow => null, // battery has its own panel
};

/// The status strip from [from] to [to]: Normal everywhere no problem covers,
/// Unknown before [knownFrom] (before the device first registered).
List<StripSegment> statusStrip(
  List<Problem> problems,
  DateTime from,
  DateTime to,
  DateTime now, {
  DateTime? knownFrom,
}) {
  if (!to.isAfter(from)) return const [];
  DateTime clip(DateTime t) =>
      t.isBefore(from) ? from : (t.isAfter(to) ? to : t);

  final covers = <(StripKind, DateTime, DateTime)>[];
  for (final p in problems) {
    final k = _stripKind(p.type);
    if (k == null) continue;
    final a = clip(p.startedAt);
    final b = clip(p.endOr(now));
    if (b.isAfter(a)) covers.add((k, a, b));
  }
  final known = knownFrom == null ? to : clip(knownFrom);
  if (known.isAfter(from)) covers.add((StripKind.unknown, from, known));

  final cuts = <DateTime>{from, to};
  for (final (_, a, b) in covers) {
    cuts
      ..add(a)
      ..add(b);
  }
  final sorted = cuts.toList()..sort();

  final out = <StripSegment>[];
  for (var i = 0; i + 1 < sorted.length; i++) {
    final a = sorted[i];
    final b = sorted[i + 1];
    var kind = StripKind.normal;
    for (final (k, ca, cb) in covers) {
      if (!ca.isAfter(a) && !cb.isBefore(b) && _rank(k) > _rank(kind)) {
        kind = k;
      }
    }
    if (out.isNotEmpty && out.last.kind == kind) {
      out[out.length - 1] = StripSegment(kind, out.last.from, b);
    } else {
      out.add(StripSegment(kind, a, b));
    }
  }
  return out;
}

/// What the History filters keep. Empty sets mean "all".
enum ProblemState { all, ongoing, resolved }

class HistoryFilter {
  const HistoryFilter({
    this.deviceIds = const {},
    this.types = const {},
    this.state = ProblemState.all,
  });

  final Set<String> deviceIds;
  final Set<ProblemType> types;
  final ProblemState state;

  bool get isDefault =>
      deviceIds.isEmpty && types.isEmpty && state == ProblemState.all;

  bool keeps(Problem p) =>
      (deviceIds.isEmpty || deviceIds.contains(p.deviceId)) &&
      (types.isEmpty || types.contains(p.type)) &&
      switch (state) {
        ProblemState.all => true,
        ProblemState.ongoing => p.ongoing,
        ProblemState.resolved => !p.ongoing,
      };

  HistoryFilter copyWith({
    Set<String>? deviceIds,
    Set<ProblemType>? types,
    ProblemState? state,
  }) => HistoryFilter(
    deviceIds: deviceIds ?? this.deviceIds,
    types: types ?? this.types,
    state: state ?? this.state,
  );
}

/// How one calendar day is drawn.
class DayMark {
  const DayMark({this.types = const {}, this.clean = false});

  /// Problem types that touched the day (a dot each).
  final Set<ProblemType> types;

  /// No problem, and at least one device was reporting that day: a small
  /// green dot. False for unknown days (before setup, in the future).
  final bool clean;
}

DateTime dayStart(DateTime t) => DateTime(t.year, t.month, t.day);

/// Day marks for every day of [month] (any date inside it).
Map<DateTime, DayMark> monthMarks(
  DateTime month,
  List<Problem> problems,
  DateTime now, {
  DateTime? knownFrom,
}) {
  final first = DateTime(month.year, month.month);
  final next = DateTime(month.year, month.month + 1);
  final out = <DateTime, DayMark>{};
  for (
    var d = first;
    d.isBefore(next);
    d = DateTime(d.year, d.month, d.day + 1)
  ) {
    final end = DateTime(d.year, d.month, d.day + 1);
    final types = {
      for (final p in problems)
        if (p.overlaps(d, end, now)) p.type,
    };
    final started = !d.isAfter(now);
    final known = knownFrom != null && knownFrom.isBefore(end);
    out[d] = DayMark(types: types, clean: types.isEmpty && started && known);
  }
  return out;
}

/// The month summary: how many problems, and how long without water.
({int count, Duration noWater}) monthSummary(
  DateTime month,
  List<Problem> problems,
  DateTime now,
) {
  final first = DateTime(month.year, month.month);
  final next = DateTime(month.year, month.month + 1);
  var noWater = Duration.zero;
  var count = 0;
  for (final p in problems) {
    if (!p.overlaps(first, next, now)) continue;
    count++;
    if (p.type != ProblemType.noFlow) continue;
    final a = p.startedAt.isBefore(first) ? first : p.startedAt;
    final e = p.endOr(now);
    final b = e.isAfter(next) ? next : e;
    if (b.isAfter(a)) noWater += b.difference(a);
  }
  return (count: count, noWater: noWater);
}

/// "2 h 10 min", "45 min", "under 1 min".
String durationText(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0 && m == 0) return 'under 1 min';
  if (h == 0) return '$m min';
  if (m == 0) return '$h h';
  return '$h h $m min';
}
