import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/history_logic.dart';
import '../../data/models.dart';

/// Colour and words for each part of the strip; status colours as everywhere.
({Color color, String word}) stripStyle(StripKind k) => switch (k) {
  StripKind.normal => (
    color: StatusStyle.of(StatusKind.normal).strong,
    word: 'Water flowing',
  ),
  StripKind.lowFlow => (
    color: StatusStyle.of(StatusKind.lowFlow).strong,
    word: 'Low flow',
  ),
  StripKind.noFlow => (
    color: StatusStyle.of(StatusKind.noFlow).strong,
    word: 'No water',
  ),
  StripKind.offline => (
    color: StatusStyle.of(StatusKind.offline).strong,
    word: 'Offline',
  ),
  StripKind.unknown => (color: AppColors.glacier, word: 'Not set up yet'),
};

/// The last 24 hours as one bar (D49): calm green, and a colour only where a
/// problem happened. Built from problem records, so a quiet day reads nothing.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.problems,
    required this.now,
    this.knownFrom,
    this.window = const Duration(hours: 24),
  });

  final List<Problem> problems;
  final DateTime now;

  /// When the device first registered; earlier time is drawn as unknown.
  final DateTime? knownFrom;
  final Duration window;

  String _summary(List<StripSegment> segs) {
    final bad = segs.where(
      (s) => s.kind != StripKind.normal && s.kind != StripKind.unknown,
    );
    if (bad.isEmpty) return 'Last 24 hours: water flowing the whole time.';
    final parts = bad.map(
      (s) =>
          '${stripStyle(s.kind).word} ${clockTime(s.from, now)} to '
          '${s.to == now ? 'now' : clockTime(s.to, now)}',
    );
    return 'Last 24 hours: ${parts.join('; ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final from = now.subtract(window);
    final segs = statusStrip(problems, from, now, now, knownFrom: knownFrom);
    final kinds = {for (final s in segs) s.kind};
    return Semantics(
      label: _summary(segs),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 22,
            child: CustomPaint(painter: _StripPainter(segs)),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('${window.inHours} h ago', style: AppText.note),
              const Spacer(),
              Text('Now', style: AppText.note),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              for (final k in StripKind.values)
                if (kinds.contains(k))
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: stripStyle(k).color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(stripStyle(k).word, style: AppText.note),
                    ],
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Paints the bar. Each part is its rectangle intersected with the rounded
/// bar, with no clip layer: a ClipRRect around coloured boxes did not paint
/// on some phones (seen on a Mi MIX 3), leaving the bar empty.
class _StripPainter extends CustomPainter {
  _StripPainter(this.segs);

  final List<StripSegment> segs;

  /// Minutes, at least 1 so a short problem still shows.
  static int _len(StripSegment s) =>
      s.to.difference(s.from).inMinutes.clamp(1, 1 << 20);

  @override
  void paint(Canvas canvas, Size size) {
    if (segs.isEmpty) return;
    final total = segs.fold<int>(0, (a, s) => a + _len(s));
    final bar = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      );
    var x = 0.0;
    for (final s in segs) {
      final w = size.width * _len(s) / total;
      // A hair of overlap so no seam shows between parts.
      final part = Path()..addRect(Rect.fromLTWH(x, 0, w + 0.5, size.height));
      canvas.drawPath(
        Path.combine(PathOperation.intersect, bar, part),
        Paint()..color = stripStyle(s.kind).color,
      );
      x += w;
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.segs != segs;
}
