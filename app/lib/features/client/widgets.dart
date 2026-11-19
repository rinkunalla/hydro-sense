import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/models.dart';

/// Status is never colour alone: icon in its colour + ink word on a near-white
/// pill.
class StatusChip extends StatelessWidget {
  const StatusChip(this.kind, {super.key, this.large = false});

  final StatusKind kind;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(kind);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 12 : 10,
        vertical: large ? 6 : 4,
      ),
      decoration: BoxDecoration(
        color: s.soft,
        borderRadius: BorderRadius.circular(AppSpace.pill),
        border: Border.all(color: const Color(0xFFFFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.icon, size: large ? 20 : 16, color: s.strong),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              s.word,
              overflow: TextOverflow.ellipsis,
              style: AppText.strong.copyWith(fontSize: large ? 15 : 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// "● Live 12 s" / "○ Late 4 min"; nothing when Offline (the chip says it).
class LiveCue extends StatefulWidget {
  const LiveCue({super.key, required this.view, required this.now});

  final DeviceView view;
  final DateTime now;

  @override
  State<LiveCue> createState() => _LiveCueState();
}

class _LiveCueState extends State<LiveCue> with SingleTickerProviderStateMixin {
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _ripple.stop();
    } else if (!_ripple.isAnimating) {
      _ripple.repeat();
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.view.freshnessAt(widget.now);
    final seen = widget.view.health?.lastSeen;
    if (f == Freshness.none || f == Freshness.offline || seen == null) {
      return const SizedBox.shrink();
    }
    final age = relativeAge(seen, widget.now);
    return Semantics(
      label: 'Live, updated $age',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: AnimatedBuilder(
              animation: _ripple,
              builder: (_, _) => CustomPaint(
                painter: _DotPainter(reduceMotion(context) ? 0 : _ripple.value),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Calm: no seconds counter that resets at every heartbeat.
          Text('Live', style: AppText.strong.copyWith(fontSize: 13)),
        ],
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (t > 0) {
      canvas.drawCircle(
        c,
        4 + 3 * t,
        Paint()..color = AppColors.deepCyan.withValues(alpha: 0.35 * (1 - t)),
      );
    }
    canvas.drawCircle(c, 4, Paint()..color = AppColors.deepCyan);
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.t != t;
}

/// "Since 6:10 AM · 42 min" under the chip of a problem or Offline card.
class SinceLine extends StatelessWidget {
  const SinceLine({super.key, required this.view, required this.now});

  final DeviceView view;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final since = view.since;
    if (since == null) return const SizedBox.shrink();
    final s = StatusStyle.of(view.status);
    final text = view.status == StatusKind.offline
        ? 'Offline since ${clockTime(since, now)}'
        : 'Since ${clockTime(since, now)} · ${waitText(now.difference(since))}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: 16, color: s.strong),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: AppText.body.copyWith(fontSize: 14))),
      ],
    );
  }
}

/// Battery: gauge with percent; charging bolt; amber "low"; fault wording.
class BatteryGauge extends StatelessWidget {
  const BatteryGauge(
    this.view, {
    super.key,
    this.showTrend = false,
    this.compact = false,
  });

  final DeviceView view;

  /// The card's top-right corner: the icon and "77%" only; charging,
  /// low and last-seen show as the icon and colour, and in the spoken label.
  final bool compact;

  /// Details shows the trend sentence ("Charging from solar").
  final bool showTrend;

  static String trendWord(String? charging) => switch (charging) {
    'Charging' => 'Charging from solar',
    'Full' => 'Full',
    'Discharging' => 'Discharging',
    _ => 'Steady',
  };

  @override
  Widget build(BuildContext context) {
    final h = view.health;
    if (h == null || (h.batteryPercent == null && !h.batteryFault)) {
      return const SizedBox.shrink();
    }
    if (h.batteryFault) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.battery_unknown_rounded,
            size: 18,
            color: AppColors.steel,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              compact ? '–' : 'Battery reading unavailable',
              style: AppText.note,
              semanticsLabel: 'Battery reading unavailable',
            ),
          ),
        ],
      );
    }
    final pct = h.batteryPercent!;
    // Offline: the reading is the last one sent, so it is greyed and says so,
    // with no charging or trend claim about a device that is not reporting.
    final stale = view.status == StatusKind.offline;
    final low = !stale && view.lowBattery;
    final charging =
        !stale &&
        (h.chargingStatus == 'Charging' || h.chargingStatus == 'Full');
    final color = stale
        ? AppColors.steel
        : low
        ? StatusStyle.of(StatusKind.lowBattery).strong
        : AppColors.deepCyan;
    final words = stale
        ? '$pct% when last seen'
        : low
        ? '$pct% low'
        : charging
        ? '$pct% charging'
        : '$pct%';
    final withTrend = showTrend && !stale;
    return Semantics(
      label:
          'Battery $words${withTrend ? ', ${trendWord(h.chargingStatus)}' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 16,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: AppColors.steel, width: 1.2),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: (pct.clamp(4, 100)) / 100,
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          if (low) ...[
            const SizedBox(width: 4),
            Icon(Icons.battery_alert_rounded, size: 16, color: color),
          ] else if (charging) ...[
            const SizedBox(width: 4),
            const Icon(Icons.bolt_rounded, size: 16, color: AppColors.deepCyan),
          ],
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              compact
                  ? '$pct%'
                  : withTrend
                  ? '$words · ${trendWord(h.chargingStatus)}'
                  : words,
              style: AppText.note.copyWith(
                color: stale ? AppColors.steel : AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The glass pipe with flowing water: full for
/// Normal, thin for Low, empty with a red break for No flow, grey and still when
/// Offline. Under reduce motion the water is a still stream of the same thickness.
class PipeView extends StatefulWidget {
  const PipeView({super.key, required this.kind, this.height = 56});

  final StatusKind kind;
  final double height;

  @override
  State<PipeView> createState() => _PipeViewState();
}

class _PipeViewState extends State<PipeView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  bool get _moving =>
      widget.kind == StatusKind.normal || widget.kind == StatusKind.lowFlow;

  void _sync() {
    if (!mounted) return;
    if (_moving && !reduceMotion(context)) {
      if (!_flow.isAnimating) _flow.repeat();
    } else {
      _flow.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PipeView old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: switch (widget.kind) {
      StatusKind.normal => 'Pipe: water flowing',
      StatusKind.lowFlow => 'Pipe: thin flow',
      StatusKind.noFlow => 'Pipe: no water',
      _ => 'Pipe: no reading',
    },
    excludeSemantics: true,
    child: SizedBox(
      height: widget.height,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _flow,
        builder: (_, _) =>
            CustomPaint(painter: PipePainter(widget.kind, _flow.value)),
      ),
    ),
  );
}

class PipePainter extends CustomPainter {
  PipePainter(this.kind, this.phase);

  final StatusKind kind;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final tube = RRect.fromRectAndRadius(
      Offset(0, size.height * 0.2) & Size(size.width, size.height * 0.6),
      Radius.circular(size.height * 0.3),
    );
    canvas.drawRRect(tube, Paint()..color = const Color(0x8CFFFFFF));
    canvas.drawRRect(
      tube,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xE6FFFFFF),
    );

    final fill = switch (kind) {
      StatusKind.normal => 0.78,
      StatusKind.lowFlow => 0.3,
      StatusKind.offline => 0.5,
      _ => 0.0,
    };
    if (fill > 0) {
      final h = tube.height * fill;
      final water = RRect.fromRectAndRadius(
        Rect.fromCenter(center: tube.center, width: tube.width - 8, height: h),
        Radius.circular(h / 2),
      );
      final grey = kind == StatusKind.offline;
      canvas.drawRRect(
        water,
        Paint()..color = grey ? const Color(0xFFB8C2CF) : AppColors.water,
      );
      if (!grey) {
        // Light streaks moving along the stream.
        final streak = Paint()..color = const Color(0x8CFFFFFF);
        const gap = 46.0;
        canvas.save();
        canvas.clipRRect(water);
        for (var x = -gap + phase * gap; x < size.width; x += gap) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, water.center.dy - h * 0.12, 18, h * 0.24),
              const Radius.circular(4),
            ),
            streak,
          );
        }
        canvas.restore();
      }
    }
    if (kind == StatusKind.noFlow) {
      final mid = size.width / 2;
      final red = Paint()
        ..color = StatusStyle.of(StatusKind.noFlow).strong
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(mid - 7, tube.top + 4),
        Offset(mid + 3, tube.bottom - 4),
        red,
      );
      canvas.drawLine(
        Offset(mid + 3, tube.top + 4),
        Offset(mid + 13, tube.bottom - 4),
        red,
      );
    }
  }

  @override
  bool shouldRepaint(PipePainter old) => old.kind != kind || old.phase != phase;
}

/// How fast the device's rotor turns for a flow rate: faster flow, faster
/// spin, like the sensor's own water wheel. 0 when no water moves.
double rotorTurnsPerSecond(double? lpm) {
  if (lpm == null || lpm <= 0) return 0;
  return (lpm / 4).clamp(0.4, 3.0);
}

/// The device drawing with a status-coloured ring (cards and the empty state).
/// Its rotor spins while water flows, at a speed that follows the flow, and
/// stands still under reduce motion, with no flow, or offline.
class DeviceIllustration extends StatefulWidget {
  const DeviceIllustration({
    super.key,
    required this.ring,
    this.size = 56,
    this.turnsPerSecond = 0,
  });

  final Color ring;
  final double size;

  /// Rotor speed (0 = still); see [rotorTurnsPerSecond].
  final double turnsPerSecond;

  @override
  State<DeviceIllustration> createState() => _DeviceIllustrationState();
}

class _DeviceIllustrationState extends State<DeviceIllustration>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  double _angle = 0;

  bool get _spin => widget.turnsPerSecond > 0 && !reduceMotion(context);

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    setState(() => _angle += dt * widget.turnsPerSecond * 2 * math.pi);
  }

  void _sync() {
    if (_spin && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!_spin && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(DeviceIllustration old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _DevicePainter(
          widget.ring,
          _angle,
          spinning: widget.turnsPerSecond > 0,
        ),
      ),
    ),
  );
}

class _DevicePainter extends CustomPainter {
  _DevicePainter(this.ring, this.angle, {required this.spinning});

  final Color ring;
  final double angle;
  final bool spinning;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r - 1.5, Paint()..color = AppColors.tint);
    canvas.drawCircle(
      c,
      r - 1.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = ring,
    );
    // Enclosure with an antenna and a status light.
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: c.translate(0, r * 0.08),
        width: r * 0.95,
        height: r * 0.8,
      ),
      Radius.circular(r * 0.16),
    );
    canvas.drawRRect(body, Paint()..color = Colors.white);
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = AppColors.deepCyan,
    );
    canvas.drawLine(
      Offset(body.right - r * 0.2, body.top),
      Offset(body.right - r * 0.12, body.top - r * 0.28),
      Paint()
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = AppColors.deepCyan,
    );
    canvas.drawCircle(
      body.center.translate(-r * 0.2, 0),
      r * 0.09,
      Paint()..color = ring,
    );

    // The rotor: three blades around a hub, like the flow sensor's water
    // wheel. Water blue while it turns, grey while it stands still.
    final hub = body.center.translate(r * 0.17, 0);
    final blade = Paint()
      ..color = spinning
          ? AppColors.water
          : AppColors.steel.withValues(alpha: 0.5)
      ..strokeWidth = r * 0.07
      ..strokeCap = StrokeCap.round;
    final len = r * 0.24;
    for (var k = 0; k < 3; k++) {
      final a = angle + k * 2 * math.pi / 3;
      canvas.drawLine(
        hub,
        hub.translate(len * math.cos(a), len * math.sin(a)),
        blade,
      );
    }
    canvas.drawCircle(hub, r * 0.06, Paint()..color = AppColors.deepCyan);
  }

  @override
  bool shouldRepaint(_DevicePainter old) =>
      old.ring != ring || old.angle != angle || old.spinning != spinning;
}

/// Animates children to their new positions when the order changes ("FLIP"),
/// so cards glide instead of jumping while the person is tapping; a removed
/// child fades and collapses instead of vanishing.
class FlipColumn extends StatefulWidget {
  const FlipColumn({
    super.key,
    required this.children,
    this.spacing = AppSpace.m,
  });

  /// Each child must have a unique ValueKey.
  final List<Widget> children;
  final double spacing;

  @override
  State<FlipColumn> createState() => _FlipColumnState();
}

class _FlipColumnState extends State<FlipColumn> with TickerProviderStateMixin {
  final _keys = <Key, GlobalKey>{};
  final _offsets = <Key, double>{};
  final _leaving = <Key, ({int index, Widget child})>{};
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  double? _top(Key k) {
    final box = _keys[k]?.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.hasSize
        ? box.localToGlobal(Offset.zero).dy
        : null;
  }

  @override
  void didUpdateWidget(FlipColumn old) {
    super.didUpdateWidget(old);
    final oldOrder = old.children.map((c) => c.key).toList();
    final newOrder = widget.children.map((c) => c.key).toList();
    if (_sameOrder(oldOrder, newOrder)) return;

    final kept = newOrder.toSet();
    _leaving.removeWhere((k, _) => kept.contains(k));
    for (var i = 0; i < old.children.length; i++) {
      final k = old.children[i].key;
      if (k != null && !kept.contains(k)) {
        _leaving[k] = (index: i, child: old.children[i]);
      }
    }
    if (_leaving.isNotEmpty) {
      _fade.forward(from: 0).whenCompleteOrCancel(() {
        if (mounted) setState(_leaving.clear);
      });
    }
    final before = {for (final k in oldOrder) ?k: _top(k)};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _offsets.clear();
      for (final k in newOrder) {
        final was = before[k];
        final now = k == null ? null : _top(k);
        if (k != null && was != null && now != null && was != now) {
          _offsets[k] = was - now;
        }
      }
      if (_offsets.isNotEmpty) _anim.forward(from: 0);
    });
  }

  bool _sameOrder(List<Key?> a, List<Key?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _anim.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final children = [...widget.children];
    final going = _leaving.entries.toList()
      ..sort((a, b) => a.value.index.compareTo(b.value.index));
    final vanish = ReverseAnimation(
      CurvedAnimation(parent: _fade, curve: Curves.easeOut),
    );
    for (final e in going) {
      children.insert(
        e.value.index.clamp(0, children.length),
        KeyedSubtree(
          key: ValueKey(('leaving', e.key)),
          child: SizeTransition(
            sizeFactor: vanish,
            child: FadeTransition(
              opacity: vanish,
              child: IgnorePointer(child: e.value.child),
            ),
          ),
        ),
      );
    }

    final out = <Widget>[];
    for (final child in children) {
      final k = child.key!;
      final gk = _keys.putIfAbsent(k, GlobalKey.new);
      if (out.isNotEmpty) out.add(SizedBox(height: widget.spacing));
      out.add(
        AnimatedBuilder(
          key: k,
          animation: _anim,
          builder: (_, c) {
            final dy =
                (_offsets[k] ?? 0) *
                (1 - Curves.easeOutCubic.transform(_anim.value));
            return Transform.translate(offset: Offset(0, dy), child: c);
          },
          child: KeyedSubtree(key: gk, child: child),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: out,
    );
  }
}
