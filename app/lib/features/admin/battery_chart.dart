import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/config.dart';
import '../../core/theme.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_repository.dart';

const _line = AppColors.primary; // single series: the title names it, no legend
const _grid = AppColors.surfaceAlt; // recessive hairlines, solid
const _lowColor = Color(0xFFA86F00); // status: low battery
const _sleepColor = Color(0xFF6B7682);
const _gap = Duration(
  hours: 1,
); // longer gaps break the line instead of bridging them

/// 7-day pack-voltage line with dashed low-battery and sleep reference lines,
/// a hover crosshair and tooltip (dataviz: 2 px line, hairline grid, text in text tokens).
class BatteryChart extends StatefulWidget {
  const BatteryChart({
    super.key,
    required this.points,
    required this.now,
    this.days = 7,
  });

  final List<BatteryPoint> points;
  final DateTime now;
  final int days;

  @override
  State<BatteryChart> createState() => _BatteryChartState();
}

class _BatteryChartState extends State<BatteryChart> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final lowV = packVoltageAtPercent(AppConfig.lowBatteryPercent);
    return LayoutBuilder(
      builder: (context, c) {
        final geo = _Geometry(
          widget.points,
          widget.now,
          widget.days,
          Size(c.maxWidth, 280),
          lowV,
        );
        return MouseRegion(
          onHover: (e) =>
              setState(() => _hover = geo.nearest(e.localPosition.dx)),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            onTapDown: (e) =>
                setState(() => _hover = geo.nearest(e.localPosition.dx)),
            child: Semantics(
              label:
                  'Battery voltage over the last ${widget.days} days. '
                  '${widget.points.length} readings. Use the table view for values.',
              child: CustomPaint(
                size: Size(c.maxWidth, 280),
                painter: _ChartPainter(geo, _hover, lowV),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Geometry {
  _Geometry(this.points, this.now, this.days, this.size, double lowV) {
    final volts = points.map((p) => p.voltage);
    final lo =
        math.min(
          lowVoltageSleepPackV,
          volts.isEmpty ? lowVoltageSleepPackV : volts.reduce(math.min),
        ) -
        0.2;
    final hi =
        math.max(8.4, volts.isEmpty ? 8.4 : volts.reduce(math.max)) + 0.1;
    yMin = (lo * 5).floorToDouble() / 5; // clean 0.2 V ticks
    yMax = (hi * 5).ceilToDouble() / 5;
    start = now.subtract(Duration(days: days));
  }

  static const left = 44.0, right = 104.0, top = 12.0, bottom = 28.0;

  final List<BatteryPoint> points;
  final DateTime now;
  final int days;
  final Size size;
  late final double yMin, yMax;
  late final DateTime start;

  double get plotW => size.width - left - right;
  double get plotH => size.height - top - bottom;

  double x(DateTime t) =>
      left +
      plotW * t.difference(start).inSeconds / now.difference(start).inSeconds;
  double y(double v) => top + plotH * (1 - (v - yMin) / (yMax - yMin));

  int? nearest(double px) {
    if (points.isEmpty) return null;
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final d = (x(points[i].at) - px).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.g, this.hover, this.lowV);

  final _Geometry g;
  final int? hover;
  final double lowV;

  static const _label = TextStyle(color: AppColors.textMuted, fontSize: 12);

  void _text(
    Canvas c,
    String s,
    Offset at, {
    TextStyle style = _label,
    bool alignRight = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      c,
      alignRight
          ? at - Offset(tp.width, tp.height / 2)
          : at - Offset(0, tp.height / 2),
    );
  }

  void _dashed(Canvas c, double y, Color color) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    for (var x = _Geometry.left; x < _Geometry.left + g.plotW; x += 9) {
      c.drawLine(
        Offset(x, y),
        Offset(math.min(x + 5, _Geometry.left + g.plotW), y),
        p,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _grid
      ..strokeWidth = 1;

    // Y gridlines and ticks every 0.2 V.
    for (var v = g.yMin; v <= g.yMax + 1e-9; v += 0.2) {
      final y = g.y(v);
      canvas.drawLine(
        Offset(_Geometry.left, y),
        Offset(_Geometry.left + g.plotW, y),
        grid,
      );
      _text(
        canvas,
        v.toStringAsFixed(1),
        Offset(_Geometry.left - 6, y),
        alignRight: true,
      );
    }
    // X ticks: one per day.
    final fmt = DateFormat('MMM d', 'en_US');
    for (var d = 0; d <= g.days; d++) {
      final t = DateTime(g.start.year, g.start.month, g.start.day + d);
      if (t.isBefore(g.start) || t.isAfter(g.now)) continue;
      final x = g.x(t);
      canvas.drawLine(
        Offset(x, _Geometry.top + g.plotH),
        Offset(x, _Geometry.top + g.plotH + 4),
        grid,
      );
      _text(
        canvas,
        fmt.format(t),
        Offset(x - 16, _Geometry.top + g.plotH + 16),
      );
    }

    // Reference lines, labeled in text ink at the right edge.
    final lowY = g.y(lowV);
    final sleepY = g.y(lowVoltageSleepPackV);
    _dashed(canvas, lowY, _lowColor);
    _dashed(canvas, sleepY, _sleepColor);
    final labelX = _Geometry.left + g.plotW + 8;
    final apart = (lowY - sleepY).abs() < 14;
    _text(
      canvas,
      'Low battery ${AppConfig.lowBatteryPercent}%',
      Offset(labelX, apart ? lowY - 7 : lowY),
    );
    _text(
      canvas,
      'Sleep ${lowVoltageSleepPackV.toStringAsFixed(1)} V',
      Offset(labelX, apart ? sleepY + 7 : sleepY),
    );

    // The series: 2 px, round joins; break the line across gaps.
    final line = Paint()
      ..color = _line
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (var i = 0; i < g.points.length; i++) {
      final p = g.points[i];
      final o = Offset(g.x(p.at), g.y(p.voltage));
      final newRun = i == 0 || p.at.difference(g.points[i - 1].at) > _gap;
      newRun ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, line);

    // Latest value as the line's direct label.
    if (g.points.isNotEmpty) {
      final last = g.points.last;
      final o = Offset(g.x(last.at), g.y(last.voltage));
      canvas.drawCircle(o, 4, Paint()..color = AppColors.surface);
      canvas.drawCircle(o, 3, Paint()..color = _line);
    }

    // Hover: crosshair snapped to the nearest reading, ringed marker, tooltip.
    final h = hover;
    if (h != null && h < g.points.length) {
      final p = g.points[h];
      final o = Offset(g.x(p.at), g.y(p.voltage));
      canvas.drawLine(
        Offset(o.dx, _Geometry.top),
        Offset(o.dx, _Geometry.top + g.plotH),
        Paint()
          ..color = AppColors.textMuted
          ..strokeWidth = 1,
      );
      canvas.drawCircle(o, 6, Paint()..color = AppColors.surface);
      canvas.drawCircle(o, 4, Paint()..color = _line);
      final tip =
          '${DateFormat('MMM d, h:mm a', 'en_US').format(p.at.toLocal())}\n'
          '${p.voltage.toStringAsFixed(2)} V${p.percent == null ? '' : ' · ${p.percent}%'}'
          '${p.sleep ? ' · sleep' : ''}';
      final tp = TextPainter(
        text: TextSpan(
          text: tip,
          style: const TextStyle(color: AppColors.text, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = tp.width + 16, ht = tp.height + 12;
      var bx = o.dx + 10;
      if (bx + w > size.width) bx = o.dx - 10 - w;
      final by = (o.dy - ht - 10).clamp(0.0, size.height - ht);
      final box = RRect.fromRectAndRadius(
        Rect.fromLTWH(bx, by, w, ht),
        const Radius.circular(8),
      );
      canvas.drawRRect(box, Paint()..color = AppColors.surface);
      canvas.drawRRect(
        box,
        Paint()
          ..color = AppColors.outline
          ..style = PaintingStyle.stroke,
      );
      tp.paint(canvas, Offset(bx + 8, by + 6));
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.hover != hover || old.g.points != g.points;
}
