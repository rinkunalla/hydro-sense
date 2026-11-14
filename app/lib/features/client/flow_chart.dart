import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models.dart';

/// Gap longer than this between two rows means the device was silent: the line
/// breaks there (rows come every 5 min at most, docs/UI_UX_SPEC.md 4.2).
const _gapBreak = Duration(minutes: 12);

/// Flow, last 24 hours: L/min line, a dashed "Low below" reference, No Flow
/// stretches shaded red, offline gaps left empty (docs/UI_UX_SPEC.md 4.2).
class FlowChart extends StatelessWidget {
  const FlowChart({
    super.key,
    required this.points,
    required this.now,
    required this.lowBelow,
    this.window = const Duration(hours: 24),
  });

  final List<FlowPoint> points;
  final DateTime now;

  /// normalFlowCutoff: below it the flow counts as Low.
  final double lowBelow;
  final Duration window;

  String _summary() {
    final rates = points.map((p) => p.flowRate).toList();
    final avg = rates.reduce((a, b) => a + b) / rates.length;
    final noFlow = points.where((p) => p.flowStatus == 'No Flow').length;
    return 'Flow over the last 24 hours: average ${avg.toStringAsFixed(1)}, '
        'lowest ${rates.reduce(math.min).toStringAsFixed(1)}, highest '
        '${rates.reduce(math.max).toStringAsFixed(1)} litres per minute'
        '${noFlow > 0 ? '; no flow at $noFlow readings' : ''}.';
  }

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.l),
        child: Text('No readings in the last 24 hours.', style: AppText.note),
      );
    }
    return Semantics(
      label: _summary(),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 160,
            child: CustomPaint(
              painter: FlowChartPainter(
                points: points,
                start: now.subtract(window),
                end: now,
                lowBelow: lowBelow,
                labelStyle: AppText.note.copyWith(fontSize: 11),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Yesterday', style: AppText.note),
              Text('Now', style: AppText.note),
            ],
          ),
        ],
      ),
    );
  }
}

class FlowChartPainter extends CustomPainter {
  FlowChartPainter({
    required this.points,
    required this.start,
    required this.end,
    required this.lowBelow,
    required this.labelStyle,
  });

  final List<FlowPoint> points;
  final DateTime start;
  final DateTime end;
  final double lowBelow;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 28.0;
    final plot = Rect.fromLTRB(left, 6, size.width, size.height - 4);
    final top = math.max(
      lowBelow * 1.6,
      points.map((p) => p.flowRate).fold<double>(0, math.max) * 1.15,
    );
    final span = end.difference(start).inMilliseconds.toDouble();
    double x(DateTime t) =>
        plot.left +
        plot.width *
            (t.difference(start).inMilliseconds / span).clamp(0.0, 1.0);
    double y(double v) => plot.bottom - plot.height * (v / top).clamp(0.0, 1.0);

    // Axis labels: 0 and the top value.
    void label(String text, double atY) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, atY - tp.height / 2));
    }

    label('0', plot.bottom);
    label(top.toStringAsFixed(0), plot.top + 6);

    // No Flow stretches shaded red (until the next row or a silent gap).
    final shade = Paint()
      ..color = StatusStyle.of(
        StatusKind.noFlow,
      ).strong.withValues(alpha: 0.14);
    for (var i = 0; i < points.length; i++) {
      if (points[i].flowStatus != 'No Flow') continue;
      final next = i + 1 < points.length ? points[i + 1].at : end;
      final until = next.difference(points[i].at) > _gapBreak
          ? points[i].at.add(_gapBreak)
          : next;
      canvas.drawRect(
        Rect.fromLTRB(x(points[i].at), plot.top, x(until), plot.bottom),
        shade,
      );
    }

    // Dashed "Low below" reference line.
    final refY = y(lowBelow);
    final dash = Paint()
      ..color = AppColors.steel
      ..strokeWidth = 1;
    for (var dx = plot.left; dx < plot.right; dx += 8) {
      canvas.drawLine(
        Offset(dx, refY),
        Offset(math.min(dx + 4, plot.right), refY),
        dash,
      );
    }
    final ref = TextPainter(
      text: TextSpan(
        text: 'Low below ${lowBelow.toStringAsFixed(1)}',
        style: labelStyle,
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    ref.paint(canvas, Offset(plot.right - ref.width, refY - ref.height - 2));

    // The flow line, broken across silent gaps.
    final line = Paint()
      ..color = AppColors.deepCyan
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    var path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = Offset(x(points[i].at), y(points[i].flowRate));
      final gap =
          i > 0 && points[i].at.difference(points[i - 1].at) > _gapBreak;
      if (i == 0 || gap) {
        if (i > 0) canvas.drawPath(path, line);
        path = Path()..moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(FlowChartPainter old) =>
      old.points != points || old.end != end || old.lowBelow != lowBelow;
}
