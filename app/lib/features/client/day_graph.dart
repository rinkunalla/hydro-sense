import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import 'readout.dart';

/// A small line graph of one day's flow: a point per [slots] of the
/// day (96 for 15-minute readings, 1440 for today's per-minute series), a gap
/// where the device sent nothing, a dashed "Low below" line, a tick for every
/// hour with labels at 12 AM, 6 AM, 12 PM and 6 PM, and (on today's graph) the
/// live reading as a dot that glides up and down to each new value.
class DayGraph extends StatelessWidget {
  const DayGraph({
    super.key,
    required this.rates,
    this.slots = 96,
    this.lowBelow,
    this.height = 90,
    this.live,
    this.compact = false,
    this.endSlot,
  });

  /// The last slot the line reaches: now for today, the end of the day for a
  /// past day (null). Slots after it are the future and stay empty.
  final int? endSlot;

  /// Slot of the day to L/min.
  final Map<int, double> rates;

  /// Slots in a day: 96 (15 minutes each) or 1440 (one a minute).
  final int slots;

  /// The device's Low flow limit, drawn as a dashed line when known.
  final double? lowBelow;
  final double height;

  /// Today's live reading (slot, L/min), drawn at the end of the line.
  final (int, double)? live;

  /// Card size: no scale label above the graph.
  final bool compact;

  String _summary() {
    final v = [...rates.values, ?live?.$2];
    if (v.isEmpty) return 'No readings for this day.';
    final avg = v.reduce((a, b) => a + b) / v.length;
    return 'Flow this day: average ${avg.toStringAsFixed(1)}, highest '
        '${v.reduce(math.max).toStringAsFixed(1)} litres per minute, '
        '${rates.length} of $slots readings'
        '${live == null ? '' : ', now ${live!.$2.toStringAsFixed(1)}'}.';
  }

  @override
  Widget build(BuildContext context) {
    if (rates.isEmpty && live == null) {
      return Text(
        compact ? 'No readings yet today.' : 'No readings for this day.',
        style: AppText.note,
      );
    }
    final top = [...rates.values, ?live?.$2, ?lowBelow, 1.0].reduce(math.max);
    return Semantics(
      label: _summary(),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact)
            Text('${top.toStringAsFixed(1)} L/min', style: AppText.note),
          SizedBox(
            // The hour labels are drawn inside, under the line.
            height: height + 18,
            child: _AnimatedDay(
              rates: rates,
              slots: slots,
              top: top,
              lowBelow: lowBelow,
              live: live,
              endSlot: endSlot ?? slots - 1,
              labelStyle: AppText.note.copyWith(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

/// The graph's motion: the line draws itself in from 12 AM when it
/// first appears, the live dot breathes, and it glides to each new reading.
/// Still under reduce motion.
class _AnimatedDay extends StatefulWidget {
  const _AnimatedDay({
    required this.rates,
    required this.slots,
    required this.top,
    required this.lowBelow,
    required this.live,
    required this.endSlot,
    required this.labelStyle,
  });

  final Map<int, double> rates;
  final int slots;
  final double top;
  final double? lowBelow;
  final (int, double)? live;
  final int endSlot;
  final TextStyle labelStyle;

  @override
  State<_AnimatedDay> createState() => _AnimatedDayState();
}

class _AnimatedDayState extends State<_AnimatedDay>
    with TickerProviderStateMixin {
  late final _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  late final _glide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  /// The live value the glide starts from (the one shown before the update).
  double? _from;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _reveal.value = 1;
      _glide.value = 1;
      _pulse.stop();
    } else {
      if (_reveal.value == 0) _reveal.forward();
      _syncPulse();
    }
  }

  @override
  void didUpdateWidget(_AnimatedDay old) {
    super.didUpdateWidget(old);
    final was = old.live?.$2;
    final now = widget.live?.$2;
    if (was != null && now != null && was != now && !reduceMotion(context)) {
      _from = _shownLive ?? was;
      _glide.forward(from: 0);
    }
    _syncPulse();
  }

  /// The live value on screen right now (mid-glide or settled).
  double? get _shownLive {
    final to = widget.live?.$2;
    final from = _from;
    if (to == null) return null;
    if (from == null || _glide.isCompleted) return to;
    return from + (to - from) * Curves.easeOutCubic.transform(_glide.value);
  }

  void _syncPulse() {
    final want = widget.live != null && !reduceMotion(context);
    if (want && !_pulse.isAnimating) _pulse.repeat();
    if (!want && _pulse.isAnimating) _pulse.stop();
  }

  @override
  void dispose() {
    _reveal.dispose();
    _pulse.dispose();
    _glide.dispose();
    super.dispose();
  }

  // Tap or slide to read a time.
  @override
  Widget build(BuildContext context) => TouchReadout(
    builder: (_, touchX) => AnimatedBuilder(
      animation: Listenable.merge([_reveal, _pulse, _glide]),
      builder: (_, _) {
        final l = widget.live;
        return CustomPaint(
          size: Size.infinite,
          painter: _DayPainter(
            rates: widget.rates,
            slots: widget.slots,
            top: widget.top,
            lowBelow: widget.lowBelow,
            live: l == null ? null : (l.$1, _shownLive ?? l.$2),
            endSlot: widget.endSlot,
            labelStyle: widget.labelStyle,
            reveal: Curves.easeOutCubic.transform(_reveal.value),
            pulse: _pulse.value,
            touchX: touchX,
          ),
        );
      },
    ),
  );
}

class _DayPainter extends CustomPainter {
  _DayPainter({
    required this.rates,
    required this.slots,
    required this.top,
    required this.lowBelow,
    required this.live,
    required this.endSlot,
    required this.labelStyle,
    this.reveal = 1,
    this.pulse = 0,
    this.touchX,
  });

  /// Where a finger touches the graph, to show the reading there.
  final double? touchX;

  final Map<int, double> rates;
  final int slots;
  final double top;
  final double? lowBelow;
  final (int, double)? live;

  /// The last slot the line reaches (now for today).
  final int endSlot;
  final TextStyle labelStyle;

  /// 0 to 1: how much of the line is drawn so far (left to right).
  final double reveal;

  /// 0 to 1: the live dot's breathing halo.
  final double pulse;

  static const _labelBand = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height - _labelBand;
    double x(num slot) => size.width * (slot + 0.5) / slots;
    double y(double v) => h * (1 - v / top);
    // Points this close count as one line (a missed upload or two).
    final joinGap = slots >= 1440 ? 3 : 1;

    // Baseline, a tick every hour, labels every 6 hours.
    final grid = Paint()
      ..color = AppColors.glacier
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, h), Offset(size.width, h), grid);
    final tick = Paint()
      ..color = AppColors.steel.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var hour = 0; hour <= 24; hour++) {
      final tx = size.width * hour / 24;
      canvas.drawLine(
        Offset(tx, h),
        Offset(tx, h + (hour % 6 == 0 ? 5 : 3)),
        tick,
      );
    }
    const labels = {0: '12 AM', 6: '6 AM', 12: '12 PM', 18: '6 PM'};
    for (final e in labels.entries) {
      final tp = TextPainter(
        text: TextSpan(text: e.value, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final cx = size.width * e.key / 24;
      final left = (cx - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(left, h + 5));
    }

    final low = lowBelow;
    if (low != null && low < top) {
      final dash = Paint()
        ..color = StatusStyle.of(
          StatusKind.lowFlow,
        ).strong.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      for (var dx = 0.0; dx < size.width; dx += 8) {
        canvas.drawLine(Offset(dx, y(low)), Offset(dx + 4, y(low)), dash);
      }
    }

    // The points: the saved ones, then the live one at the end.
    final points = <(int, double)>[
      for (final k in (rates.keys.toList()..sort()))
        if (live == null || k < live!.$1) (k, rates[k]!),
      ?live,
    ];

    // One unbroken line from 12 AM to [endSlot]: a slot with no reading lies
    // on the baseline in grey (device off, not set up); up to [joinGap]
    // missing slots after a reading just join the points around them.
    final saved = {for (final p in points) p.$1: p.$2};
    final end = math.max(
      endSlot,
      saved.isEmpty ? 0 : saved.keys.reduce(math.max),
    );
    final all = <(int, double, bool)>[];
    int? lastKnown;
    for (var k = 0; k <= end; k++) {
      final v = saved[k];
      if (v != null) {
        all.add((k, v, true));
        lastKnown = k;
      } else if (lastKnown == null || k - lastKnown > joinGap) {
        all.add((k, 0, false));
      }
    }

    final line = Paint()
      ..color = AppColors.deepCyan
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final idle = Paint()
      ..color = AppColors.steel.withValues(alpha: 0.45)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = AppColors.water.withValues(alpha: 0.18);
    canvas
      ..save()
      ..clipRect(Rect.fromLTWH(0, 0, size.width * reveal, h + 1));
    for (var k = 0; k + 1 < all.length; k++) {
      final a = all[k], b = all[k + 1];
      final pa = Offset(x(a.$1), y(a.$2)), pb = Offset(x(b.$1), y(b.$2));
      if (a.$3 && b.$3) {
        canvas
          ..drawPath(
            Path()
              ..moveTo(pa.dx, h)
              ..lineTo(pa.dx, pa.dy)
              ..lineTo(pb.dx, pb.dy)
              ..lineTo(pb.dx, h)
              ..close(),
            fill,
          )
          ..drawLine(pa, pb, line);
      } else {
        // A rise from, or a drop to, the baseline is part of the reading.
        canvas.drawLine(pa, pb, a.$3 || b.$3 ? line : idle);
      }
    }
    if (all.length == 1 && all.first.$3) {
      canvas.drawCircle(
        Offset(x(all.first.$1), y(all.first.$2)),
        2.5,
        Paint()..color = AppColors.deepCyan,
      );
    }
    canvas.restore();

    // The live reading: a dot with a white ring and a breathing halo, shown
    // once the line has reached it.
    final l = live;
    if (l != null && reveal >= 1) {
      final at = Offset(x(l.$1), y(l.$2));
      canvas
        ..drawCircle(
          at,
          5 + 7 * pulse,
          Paint()
            ..color = AppColors.water.withValues(alpha: 0.35 * (1 - pulse)),
        )
        ..drawCircle(at, 5, Paint()..color = Colors.white)
        ..drawCircle(at, 3.5, Paint()..color = AppColors.deepCyan);
    }

    // The touched reading: the point nearest the finger, with its time.
    final tx = touchX;
    if (tx != null && points.isNotEmpty) {
      var best = points.first;
      for (final p in points) {
        if ((x(p.$1) - tx).abs() < (x(best.$1) - tx).abs()) best = p;
      }
      final minute = best.$1 * 1440 ~/ slots;
      final t = DateTime(2026, 1, 1, minute ~/ 60, minute % 60);
      final when = l != null && best.$1 == l.$1 ? 'Now' : _clock(t);
      paintReadout(
        canvas,
        Rect.fromLTRB(0, 0, size.width, h),
        Offset(x(best.$1), y(best.$2)),
        '$when · ${best.$2.toStringAsFixed(1)} L/min',
        AppColors.deepCyan,
        labelStyle,
      );
    }
  }

  static String _clock(DateTime t) {
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final ampm = t.hour < 12 ? 'AM' : 'PM';
    return '$hour:${t.minute.toString().padLeft(2, '0')} $ampm';
  }

  @override
  bool shouldRepaint(_DayPainter old) =>
      old.rates != rates ||
      old.slots != slots ||
      old.top != top ||
      old.lowBelow != lowBelow ||
      old.live != live ||
      old.endSlot != endSlot ||
      old.reveal != reveal ||
      old.pulse != pulse ||
      old.touchX != touchX;
}
