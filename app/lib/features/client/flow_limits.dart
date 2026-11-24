import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/providers.dart';

String _lpm(double v) => '${v.toStringAsFixed(1)} L/min';

/// "Flow limits" on Details: what counts as Normal, Low and No flow for
/// this device, where the limits come from, and a way to set your own.
class FlowLimitsCard extends StatelessWidget {
  const FlowLimitsCard({super.key, required this.device, required this.now});

  final Device device;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = device.limits;
    final source = device.ownLimit
        ? 'Set by you.'
        : device.calibratedAt == null
        ? 'Starting values. They adjust to this device\'s usual flow after a '
              'week of readings.'
        : 'Set automatically from this device\'s usual flow, every Sunday.';
    Widget row(StatusKind k, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            StatusStyle.all[k]!.icon,
            size: 20,
            color: StatusStyle.all[k]!.strong,
          ),
          const SizedBox(width: AppSpace.s),
          Expanded(child: Text(StatusStyle.all[k]!.word, style: AppText.body)),
          // Wraps at large text sizes instead of running past the card edge.
          Flexible(
            flex: 2,
            child: Text(value, style: AppText.strong, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Flow limits'),
          row(StatusKind.normal, 'above ${_lpm(l.normal)}'),
          row(
            StatusKind.lowFlow,
            '${l.low.toStringAsFixed(1)} to ${_lpm(l.normal)}',
          ),
          row(StatusKind.noFlow, 'below ${_lpm(l.low)}'),
          const SizedBox(height: AppSpace.s),
          Text(source, style: AppText.note),
          const SizedBox(height: AppSpace.m),
          Align(
            alignment: Alignment.centerLeft,
            child: SecondaryButton(
              label: 'Change limit',
              icon: Icons.tune_rounded,
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                useRootNavigator: true, // above the floating tab bar
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => FlowLimitSheet(device: device),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Picks "Low flow below X L/min" in 0.5 steps, or goes back to automatic.
class FlowLimitSheet extends ConsumerStatefulWidget {
  const FlowLimitSheet({super.key, required this.device});

  final Device device;

  @override
  ConsumerState<FlowLimitSheet> createState() => _FlowLimitSheetState();
}

class _FlowLimitSheetState extends ConsumerState<FlowLimitSheet> {
  late double _value;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final start = widget.device.ownLimit
        ? widget.device.userNormalCutoff!
        : widget.device.limits.normal;
    _value = _snap(start);
  }

  double _snap(double v) {
    const step = AppConfig.userCutoffStep;
    return ((v / step).round() * step).clamp(
      widget.device.sensorType.cutoffMin,
      widget.device.sensorType.cutoffMax,
    );
  }

  Future<void> _save(double? value) async {
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).setFlowLimit(widget.device.id, value);
      if (!mounted) return;
      Navigator.of(context).pop();
      showToast(
        context,
        value == null
            ? 'Back to automatic limits.'
            : 'Saved. The device uses it within about a minute.',
      );
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, "Couldn't save. Check your internet.");
      }
    }
  }

  Widget _step(IconData icon, String label, double delta) {
    final next = _value + delta;
    final ok =
        !_busy &&
        next >= widget.device.sensorType.cutoffMin &&
        next <= widget.device.sensorType.cutoffMax;
    return IconButton.filledTonal(
      tooltip: label,
      iconSize: 28,
      onPressed: ok ? () => setState(() => _value = _snap(next)) : null,
      icon: Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.m),
        child: GlassPanel(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Low flow below', style: AppText.title(20)),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Flow under this counts as Low flow and sends an alert. '
                'Pick a little under what this area normally gets.',
                style: AppText.note,
              ),
              const SizedBox(height: AppSpace.l),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _step(
                    Icons.remove_rounded,
                    'Lower',
                    -AppConfig.userCutoffStep,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(_lpm(_value), style: AppText.reading(34)),
                    ),
                  ),
                  _step(Icons.add_rounded, 'Higher', AppConfig.userCutoffStep),
                ],
              ),
              const SizedBox(height: AppSpace.s),
              Text(
                'Between ${widget.device.sensorType.cutoffMin.toStringAsFixed(0)} and '
                '${widget.device.sensorType.cutoffMax.toStringAsFixed(0)} L/min. Below '
                '${widget.device.sensorType.starterLow} L/min always counts as No flow.',
                textAlign: TextAlign.center,
                style: AppText.note,
              ),
              const SizedBox(height: AppSpace.l),
              PrimaryButton(
                label: 'Save',
                busy: _busy,
                onPressed: () => _save(_value),
              ),
              if (widget.device.ownLimit)
                TextButton(
                  onPressed: _busy ? null : () => _save(null),
                  child: const Text('Use automatic limits'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
