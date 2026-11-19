import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Touch to read a graph: tap or slide a finger across it to show the
/// reading at that time; it hides 2 seconds after the finger lifts.
class TouchReadout extends StatefulWidget {
  const TouchReadout({super.key, required this.builder});

  /// Builds the graph with the finger's x position (null when not touched).
  final Widget Function(BuildContext context, double? touchX) builder;

  @override
  State<TouchReadout> createState() => _TouchReadoutState();
}

class _TouchReadoutState extends State<TouchReadout> {
  double? _x;
  Timer? _hide;

  void _at(Offset local) {
    _hide?.cancel();
    setState(() => _x = local.dx);
  }

  void _release() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _x = null);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (d) => _at(d.localPosition),
    onTapUp: (_) => _release(),
    onHorizontalDragStart: (d) => _at(d.localPosition),
    onHorizontalDragUpdate: (d) => _at(d.localPosition),
    onHorizontalDragEnd: (_) => _release(),
    onHorizontalDragCancel: _release,
    child: widget.builder(context, _x),
  );
}

/// Draws the touched reading: a guide line, a ringed dot, and a label such as
/// "2:41 PM · 8.2 L/min" kept inside [plot].
void paintReadout(
  Canvas canvas,
  Rect plot,
  Offset at,
  String text,
  Color color,
  TextStyle style,
) {
  canvas
    ..drawLine(
      Offset(at.dx, plot.top),
      Offset(at.dx, plot.bottom),
      Paint()
        ..color = AppColors.ink.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    )
    ..drawCircle(at, 5.5, Paint()..color = Colors.white)
    ..drawCircle(at, 4, Paint()..color = color);
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: style.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  const padX = 7.0, padY = 4.0;
  final w = tp.width + padX * 2;
  final h = tp.height + padY * 2;
  final left = (at.dx - w / 2).clamp(plot.left, plot.right - w);
  final top = at.dy - h - 10 < plot.top ? at.dy + 10 : at.dy - h - 10;
  final box = RRect.fromRectAndRadius(
    Rect.fromLTWH(left, top, w, h),
    const Radius.circular(8),
  );
  canvas.drawRRect(box, Paint()..color = AppColors.ink.withValues(alpha: 0.88));
  tp.paint(canvas, Offset(left + padX, top + padY));
}
