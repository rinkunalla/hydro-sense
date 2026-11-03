import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models.dart';

/// Status is never color alone: color + icon + word (docs/UI_UX_SPEC.md section 1).
class StatusChip extends StatelessWidget {
  const StatusChip(this.kind, {super.key, this.large = false});

  final StatusKind kind;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(kind);
    final size = large ? 20.0 : 16.0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 12 : 8,
        vertical: large ? 6 : 3,
      ),
      decoration: BoxDecoration(
        color: s.soft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.icon, size: size, color: s.strong),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              s.word,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: s.chipText,
                fontWeight: FontWeight.w700,
                fontSize: large ? 16 : 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Battery icon + percent, amber "Low battery" below 20 %, or the fault wording.
class BatteryLine extends StatelessWidget {
  const BatteryLine(this.view, {super.key});

  final DeviceView view;

  @override
  Widget build(BuildContext context) {
    final h = view.health;
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted);
    if (h == null || (h.batteryPercent == null && !h.batteryFault)) {
      return const SizedBox.shrink();
    }
    if (h.batteryFault) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.battery_unknown,
            size: 16,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 4),
          Flexible(child: Text('Battery reading unavailable', style: muted)),
        ],
      );
    }
    if (view.lowBattery) {
      final s = StatusStyle.of(StatusKind.lowBattery);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.icon, size: 16, color: s.strong),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '${h.batteryPercent}% Low battery',
              style: muted?.copyWith(
                color: s.chipText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.battery_std, size: 16, color: AppColors.textMuted),
        const SizedBox(width: 4),
        Text('${h.batteryPercent}%', style: muted),
      ],
    );
  }
}

/// Animates children to their new positions when the order changes ("FLIP"),
/// so cards glide instead of jumping while the person is tapping.
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

class _FlipColumnState extends State<FlipColumn>
    with SingleTickerProviderStateMixin {
  final _keys = <Key, GlobalKey>{};
  final _offsets = <Key, double>{};
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final out = <Widget>[];
    for (final child in widget.children) {
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
