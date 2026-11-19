import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/glass.dart';
import '../../core/theme.dart';
import 'readout.dart';

/// The ranges a device card's chart can show.
enum TrendRange {
  hour(60, '1 h'),
  twoHours(120, '2 h'),
  day(1440, '24 h');

  const TrendRange(this.minutes, this.label);
  final int minutes;
  final String label;

  /// Minutes per point: one a minute up to 2 h; 10-minute averages for 24 h
  /// so the line stays readable.
  int get bucket => minutes > 120 ? 10 : 1;
}

/// A rounded step for a scale: 1, 2, 2.5 or 5 times a power of ten, at
/// least [raw] ("0, 5, 10, 15, 20" instead of "0, 4.83, 9.66 …").
double niceStep(double raw) {
  if (raw <= 0) return 1;
  final p = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * p >= raw - 1e-9) return m * p;
  }
  return 10 * p;
}

/// Which way the flow is going at "Now".
enum Trend { rising, falling, steady }

/// Less change than this over the last few points counts as steady.
const double steadyLpm = 0.2;

/// Rising, falling or steady from the last few points (oldest first).
Trend trendOf(List<double> values) {
  if (values.length < 2) return Trend.steady;
  final back = values[math.max(0, values.length - 4)];
  final d = values.last - back;
  if (d > steadyLpm) return Trend.rising;
  if (d < -steadyLpm) return Trend.falling;
  return Trend.steady;
}

/// A missing minute this close after a reading keeps that reading: an online
/// device writes at least every 30 s, so one empty minute is timing, not an
/// outage.
const int bridgeMinutes = 2;

/// Every point of [range], oldest first: (minutes before now, L/min, known).
/// A stretch with no readings (device off, not set up, before it first
/// sent) is a point at 0 with `known` false, drawn grey, so the line runs
/// unbroken across the whole range. [byMinute] keys are minutes from today's
/// midnight (negative for yesterday).
List<(int, double, bool)> trendPoints(
  Map<int, double> byMinute,
  int nowMinute,
  TrendRange range,
) {
  final out = <(int, double, bool)>[];
  final b = range.bucket;
  // Carry in the last reading from just before the window, so a line that
  // was at 3 L/min goes on at 3 instead of starting from 0.
  final start = nowMinute - range.minutes;
  double? last;
  var missing = 0;
  for (var m = start - 1; m >= start - bridgeMinutes; m--) {
    final v = byMinute[m];
    if (v != null) {
      last = v;
      missing = start - 1 - m;
      break;
    }
  }
  for (var back = range.minutes; back >= b; back -= b) {
    final values = <double>[
      for (var k = 0; k < b; k++) ?byMinute[nowMinute - back + k],
    ];
    if (values.isNotEmpty) {
      last = values.reduce((a, c) => a + c) / values.length;
      missing = 0;
      out.add((back, last, true));
    } else {
      missing += b;
      out.add(
        last != null && missing <= bridgeMinutes
            ? (back, last, true)
            : (back, 0, false),
      );
    }
  }
  return out;
}

/// The device card's live chart, drawn like a stability or battery
/// usage graph: a grid, two axes, one thick line from a hollow start circle to
/// an arrowhead at "Now". The arrow points up while the flow rises, down
/// while it falls and flat while it is steady, and glides to each new reading;
/// the chart slides left as each minute passes. Green while the flow is at or
/// above the device's normal limit (even while falling), red below it, grey
/// offline. Still under reduce motion.
class LiveTrend extends StatefulWidget {
  const LiveTrend({
    super.key,
    required this.byMinute,
    required this.nowMinute,
    required this.now,
    required this.range,
    required this.normalAbove,
    this.live,
    this.offline = false,
    this.height = 128,
  });

  /// Minutes from today's midnight (negative for yesterday) to L/min.
  final Map<int, double> byMinute;
  final int nowMinute;
  final DateTime now;
  final TrendRange range;

  /// The device's normal limit: at or above it the line is green.
  final double normalAbove;

  /// The latest reading, drawn as the arrow's tip; null while offline.
  final double? live;
  final bool offline;
  final double height;

  @override
  State<LiveTrend> createState() => _LiveTrendState();
}

class _LiveTrendState extends State<LiveTrend> with TickerProviderStateMixin {
  // Made in initState, not lazily: a card with no readings yet would first
  // touch them in dispose, when looking up the ticker mode is unsafe.
  late final AnimationController _glide; // a new reading: the tip flows to it
  double? _from;

  /// Seconds into the current minute: the chart drifts left with real time,
  /// re-drawn once a second, like a live monitor (cheap on the battery).
  int _sec = DateTime.now().second;
  Timer? _drift;

  /// The phone's reduce-motion setting, kept here: the card can be moved in
  /// the list (FlipColumn) while it updates, when looking it up is unsafe.
  bool _still = false;

  @override
  void initState() {
    super.initState();
    // Slow in, slow out over 1.5 s: between readings (every 5 to 30 s) the tip
    // flows to the new value instead of jumping.
    _glide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
      value: 1,
    );
    _drift = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_still) setState(() => _sec = DateTime.now().second);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = reduceMotion(context);
  }

  @override
  void didUpdateWidget(LiveTrend old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range) {
      _glide.value = 1;
      return;
    }
    final was = old.live;
    final now = widget.live;
    if (was != null && now != null && was != now && !_still) {
      _from = _shown ?? was;
      _glide.forward(from: 0);
    }
  }

  double? get _shown {
    final to = widget.live;
    final from = _from;
    if (to == null) return null;
    if (from == null || _glide.isCompleted) return to;
    return from + (to - from) * Curves.easeInOutCubic.transform(_glide.value);
  }

  @override
  void dispose() {
    _drift?.cancel();
    _glide.dispose();
    super.dispose();
  }

  List<(int, double, bool)> _points() {
    final pts = trendPoints(widget.byMinute, widget.nowMinute, widget.range);
    final tip = _shown ?? widget.byMinute[widget.nowMinute];
    pts.add(tip != null ? (0, tip, true) : (0, 0, false));
    return pts;
  }

  Color _color(double? last) {
    if (widget.offline || last == null) return AppColors.steel;
    return last >= widget.normalAbove
        ? StatusStyle.of(StatusKind.normal).strong
        : StatusStyle.of(StatusKind.noFlow).strong;
  }

  @override
  Widget build(BuildContext context) {
    final pts = _points();
    final trend = trendOf([for (final p in pts) p.$2]);
    final word = switch (trend) {
      Trend.rising => 'rising',
      Trend.falling => 'falling',
      Trend.steady => 'steady',
    };
    final summary = !pts.any((p) => p.$3)
        ? 'No readings in the last ${widget.range.label}.'
        : !pts.last.$3
        ? 'Last ${widget.range.label}: no reading now.'
        : 'Last ${widget.range.label}: $word, now '
              '${pts.last.$2.toStringAsFixed(1)} litres per minute.';
    return Semantics(
      label: summary,
      excludeSemantics: true,
      child: SizedBox(
        height: widget.height,
        // Tap or slide to read a time.
        child: TouchReadout(
          builder: (_, touchX) => AnimatedBuilder(
            animation: _glide,
            builder: (_, _) {
              final points = _points();
              return CustomPaint(
                size: Size.infinite,
                painter: _TrendPainter(
                  points: points,
                  range: widget.range,
                  now: widget.now,
                  color: _color(points.last.$3 ? points.last.$2 : null),
                  normalAbove: widget.normalAbove,
                  trend: trendOf([for (final p in points) p.$2]),
                  drift: _still ? 0 : _sec / 60,
                  labelStyle: AppText.note.copyWith(fontSize: 10.5),
                  touchX: touchX,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.range,
    required this.now,
    required this.color,
    required this.normalAbove,
    required this.trend,
    required this.drift,
    required this.labelStyle,
    this.touchX,
  });

  /// Where a finger touches the chart, to show the reading there.
  final double? touchX;

  final List<(int, double, bool)> points;
  final TrendRange range;
  final DateTime now;

  /// The colour of "Now" (the arrowhead): the current status.
  final Color color;

  /// Each reading is green at or above this, red below it.
  final double normalAbove;
  final Trend trend;

  static final Color _idle = AppColors.steel.withValues(alpha: 0.5);

  /// One point's own colour: grey without a reading, else green or red by
  /// its own value, so a past 4 L/min stays green while the flow is 0 now.
  Color _at((int, double, bool) p) => !p.$3
      ? _idle
      : p.$2 >= normalAbove
      ? StatusStyle.of(StatusKind.normal).strong
      : StatusStyle.of(StatusKind.noFlow).strong;

  /// 0 to 1: how far into the current minute; older points drift left.
  final double drift;
  final TextStyle labelStyle;

  TextPainter _text(String s) => TextPainter(
    text: TextSpan(text: s, style: labelStyle),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    // A rounded scale up the left side: 4 equal steps of 1, 2, 2.5 or 5
    // times a power of ten, from 0 to just above the highest reading.
    final peak = math.max(1.0, points.map((p) => p.$2).reduce(math.max));
    final stepV = niceStep(peak * 1.1 / 4);
    final top = stepV * 4;
    String fmt(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    final scale = [for (var r = 0; r <= 4; r++) _text(fmt(stepV * r))];
    final unit = _text('L/min');
    final left =
        math.max(unit.width, scale.map((t) => t.width).reduce(math.max)) + 6;
    // Room on the right so the arrowhead is never cut off.
    const bottomBand = 16.0, right = 22.0, topPad = 16.0;
    final plot = Rect.fromLTRB(
      left,
      topPad,
      size.width - right,
      size.height - bottomBand,
    );
    final step = plot.width / range.minutes;
    // The tip sits at Now; every older point drifts left with real time.
    double x(int back) =>
        back == 0 ? plot.right : plot.right - (back + drift) * step;
    double y(double v) => plot.bottom - plot.height * (v / top);

    // Graph paper: 12 columns and 4 rows.
    final grid = Paint()
      ..color = AppColors.steel.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (var c = 1; c < 12; c++) {
      final gx = plot.left + plot.width * c / 12;
      canvas.drawLine(Offset(gx, plot.top), Offset(gx, plot.bottom), grid);
    }
    for (var r = 0; r < 4; r++) {
      final gy = plot.top + plot.height * r / 4;
      canvas.drawLine(Offset(plot.left, gy), Offset(plot.right, gy), grid);
    }
    // The two axes.
    final axis = Paint()
      ..color = AppColors.ink
      ..strokeWidth = 1.6;
    canvas
      ..drawLine(plot.topLeft, plot.bottomLeft, axis)
      ..drawLine(plot.bottomLeft, plot.bottomRight, axis);

    // Left: the flow at each grid line, with the unit above the axis.
    unit.paint(canvas, Offset(0, 0));
    for (var r = 0; r <= 4; r++) {
      final t = scale[r];
      t.paint(canvas, Offset(left - t.width - 6, y(stepV * r) - t.height / 2));
    }
    // Under it: the time at each quarter of the range, then Now.
    final clock = DateFormat(range == TrendRange.day ? 'ha' : 'h:mm', 'en_US');
    for (var q = 0; q <= 4; q++) {
      final tx = plot.left + plot.width * q / 4;
      final s = q == 4
          ? 'Now'
          : clock.format(
              now.subtract(Duration(minutes: range.minutes * (4 - q) ~/ 4)),
            );
      final tp = _text(s);
      final lx = (tx - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(lx, plot.bottom + 3));
    }

    // One unbroken line across the whole range: grey along 0 where there
    // was no reading; green or red by each reading's own value.
    canvas
      ..save()
      ..clipRect(plot.inflate(2));
    Paint pen(Color c) => Paint()
      ..color = c
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final pts = [for (final p in points) Offset(x(p.$1), y(p.$2))];
    // A smooth wave: piece k runs from the midpoint before point k to the
    // midpoint after it, bending through point k, in point k's colour.
    Offset from(int k) =>
        k == 0 ? pts[0] : Offset.lerp(pts[k - 1], pts[k], .5)!;
    Offset to(int k) =>
        k == pts.length - 1 ? pts[k] : Offset.lerp(pts[k], pts[k + 1], .5)!;
    var k = 0;
    while (k < pts.length) {
      final c = _at(points[k]);
      final s = from(k);
      final path = Path()..moveTo(s.dx, s.dy);
      while (k < pts.length && _at(points[k]) == c) {
        final e = to(k);
        path.quadraticBezierTo(pts[k].dx, pts[k].dy, e.dx, e.dy);
        k++;
      }
      canvas.drawPath(path, pen(c));
    }
    canvas.restore();

    // A hollow circle where the line starts.
    final first = points.first;
    final startAt = Offset(
      x(first.$1).clamp(plot.left, plot.right),
      y(first.$2),
    );
    final startColor = _at(first);
    canvas
      ..drawCircle(startAt, 5, Paint()..color = Colors.white)
      ..drawCircle(
        startAt,
        5,
        Paint()
          ..color = startColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

    // The arrowhead at "Now": up, down or flat with the trend.
    final tip = Offset(x(points.last.$1), y(points.last.$2));
    final angle = switch (trend) {
      Trend.rising => -math.pi / 4,
      Trend.falling => math.pi / 4,
      Trend.steady => 0.0,
    };
    const len = 12.0, spread = 0.55;
    final head = Path()
      ..moveTo(tip.dx + 3 * math.cos(angle), tip.dy + 3 * math.sin(angle))
      ..lineTo(
        tip.dx - len * math.cos(angle - spread),
        tip.dy - len * math.sin(angle - spread),
      )
      ..lineTo(
        tip.dx - len * math.cos(angle + spread),
        tip.dy - len * math.sin(angle + spread),
      )
      ..close();
    canvas.drawPath(head, Paint()..color = color);

    // The touched reading: the point nearest the finger.
    final tx = touchX;
    if (tx != null) {
      var best = points.first;
      for (final p in points) {
        if ((x(p.$1) - tx).abs() < (x(best.$1) - tx).abs()) best = p;
      }
      // A 10-minute average sits at the middle of its 10 minutes.
      final mid = best.$1 - (best.$1 == 0 ? 0 : range.bucket ~/ 2);
      final at = now.subtract(Duration(minutes: mid));
      final when = best.$1 == 0
          ? 'Now'
          : DateFormat('h:mm a', 'en_US').format(at);
      paintReadout(
        canvas,
        plot,
        Offset(x(best.$1), y(best.$2)),
        best.$3
            ? '$when · ${best.$2.toStringAsFixed(1)} L/min'
            : '$when · no reading',
        _at(best),
        labelStyle,
      );
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.points != points ||
      old.color != color ||
      old.normalAbove != normalAbove ||
      old.trend != trend ||
      old.drift != drift ||
      old.range != range ||
      old.touchX != touchX;
}
