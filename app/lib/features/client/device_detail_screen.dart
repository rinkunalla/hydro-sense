import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import 'flow_chart.dart';
import 'widgets.dart';

/// Trims and checks a new nickname (1 to 24 characters). Null when valid.
String? validateNickname(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return Messages.nameEmpty;
  if (name.length > AppConfig.nicknameMax) {
    return 'Use at most ${AppConfig.nicknameMax} characters.';
  }
  return null;
}

/// The 24 h chart rows, read once per device per session (CLAUDE.md section 8).
final flowHistoryProvider = FutureProvider.family<List<FlowPoint>, String>(
  (ref, id) => ref
      .watch(repositoryProvider)
      .flowHistory(
        id,
        DateTime.now().subtract(
          const Duration(hours: AppConfig.flowChartHours),
        ),
      ),
);

/// Device details (docs/UI_UX_SPEC.md 4.2).
class DeviceDetailScreen extends ConsumerStatefulWidget {
  const DeviceDetailScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  bool _leaving = false;

  void _back() => context.canPop() ? context.pop() : context.go('/devices');

  @override
  Widget build(BuildContext context) {
    final fleet = ref.watch(fleetProvider).valueOrNull;
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    DeviceView? view;
    for (final v in fleet?.views ?? const <DeviceView>[]) {
      if (v.id == widget.deviceId) view = v;
    }

    // Unassigned or removed while open: go back and say so (4.1).
    if (fleet != null && view == null) {
      if (!_leaving) {
        _leaving = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showToast(context, Messages.deviceGone);
          _back();
        });
      }
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: SizedBox.shrink(),
      );
    }
    if (view == null) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Padding(
          padding: EdgeInsets.all(AppSpace.l),
          child: SkeletonCard(height: 240),
        ),
      );
    }

    final v = view;
    final h = v.health;
    final offline = v.status == StatusKind.offline;
    final rate = v.device.flowRate;
    final history = ref.watch(flowHistoryProvider(v.id));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.l,
            AppSpace.s,
            AppSpace.l,
            AppSpace.xxl * 3,
          ),
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: AppColors.ink,
                  onPressed: _back,
                ),
                Expanded(child: _Nickname(view: v)),
              ],
            ),
            const SizedBox(height: AppSpace.s),
            Wrap(
              spacing: AppSpace.m,
              runSpacing: AppSpace.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusChip(v.status, large: true),
                if (v.since != null) SinceLine(view: v, now: now),
              ],
            ),
            const SizedBox(height: AppSpace.s),
            Wrap(
              spacing: AppSpace.m,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                LiveCue(view: v, now: now),
                if (h?.lastSeen != null)
                  Text(
                    offline
                        ? 'Last seen ${clockTime(h!.lastSeen!, now)}'
                        : 'Updated ${relativeAge(h!.lastSeen!, now)}',
                    style: AppText.note,
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.l),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: offline || rate == null
                        ? 'No current flow reading'
                        : '${rate.toStringAsFixed(1)} litres per minute',
                    excludeSemantics: true,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: offline || rate == null
                                ? '–'
                                : rate.toStringAsFixed(1),
                            style: AppText.reading(52).copyWith(
                              color: offline ? AppColors.steel : AppColors.ink,
                            ),
                          ),
                          TextSpan(text: ' L/min', style: AppText.strong),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.s),
                  PipeView(kind: v.status),
                ],
              ),
            ),
            if (h != null && (h.batteryPercent != null || h.batteryFault)) ...[
              const SizedBox(height: AppSpace.m),
              GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionLabel('Battery'),
                    BatteryGauge(v, showTrend: true),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpace.m),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionLabel('Flow, last 24 hours'),
                  history.when(
                    loading: () => const SizedBox(
                      height: 160,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (_, _) =>
                        Text(Messages.generic, style: AppText.note),
                    data: (points) => FlowChart(
                      points: points,
                      now: now,
                      lowBelow: v.device.normalFlowCutoff,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Nickname with an edit pencil; inline field, 1 to 24 characters, trimmed.
class _Nickname extends ConsumerStatefulWidget {
  const _Nickname({required this.view});

  final DeviceView view;

  @override
  ConsumerState<_Nickname> createState() => _NicknameState();
}

class _NicknameState extends ConsumerState<_Nickname> {
  final _c = TextEditingController();
  bool _editing = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = validateNickname(_c.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(repositoryProvider).rename(widget.view.id, _c.text.trim());
      if (mounted) {
        setState(() => _editing = false);
        showToast(context, 'Name saved');
      }
    } catch (_) {
      if (mounted) setState(() => _error = Messages.renameFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      return Row(
        children: [
          Flexible(
            child: Semantics(
              header: true,
              child: Text(
                widget.view.nickname,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.title(24),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_rounded, color: AppColors.deepCyan),
            onPressed: () => setState(() {
              _c.text = widget.view.nickname;
              _error = null;
              _editing = true;
            }),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _c,
            autofocus: true,
            enabled: !_saving,
            maxLength: AppConfig.nicknameMax,
            decoration: InputDecoration(labelText: 'Name', errorText: _error),
            onSubmitted: (_) => _save(),
          ),
        ),
        IconButton(
          tooltip: 'Save name',
          icon: const Icon(Icons.check_rounded, color: AppColors.deepCyan),
          onPressed: _saving ? null : _save,
        ),
        IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close_rounded, color: AppColors.steel),
          onPressed: _saving ? null : () => setState(() => _editing = false),
        ),
      ],
    );
  }
}
