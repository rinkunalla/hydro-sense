import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
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

/// "Until I resume" stays an hour inside the 7-day rule, so a phone clock that runs
/// a little fast is not refused by the server.
DateTime pauseUntil(Duration? choice, DateTime now) => now.add(
  choice ??
      const Duration(days: AppConfig.pauseMaxDays) - const Duration(hours: 1),
);

/// Signal strength word and bars (1-4) from RSSI.
({int bars, String word}) signalOf(int rssi) {
  if (rssi >= -60) return (bars: 4, word: 'Strong');
  if (rssi >= -70) return (bars: 3, word: 'Good');
  if (rssi >= -80) return (bars: 2, word: 'Fair');
  return (bars: 1, word: 'Weak');
}

class DeviceDetailScreen extends ConsumerStatefulWidget {
  const DeviceDetailScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  bool _leaving = false;

  @override
  Widget build(BuildContext context) {
    final fleet = ref.watch(fleetProvider).valueOrNull;
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    DeviceView? view;
    for (final v in fleet?.views ?? const <DeviceView>[]) {
      if (v.id == widget.deviceId) view = v;
    }

    if (fleet != null && view == null) {
      if (!_leaving) {
        _leaving = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text(Messages.deviceRemoved)));
          Navigator.of(context).maybePop();
        });
      }
      return const Scaffold(body: SizedBox.shrink());
    }
    if (view == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final v = view;
    final h = v.health;
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted);
    final offline = v.status == StatusKind.offline;
    final rate = v.device.flowRate;

    return Scaffold(
      appBar: AppBar(title: Text(v.nickname, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: StatusChip(v.status, large: true),
          ),
          const SizedBox(height: AppSpace.m),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: offline || rate == null ? '-' : rate.toStringAsFixed(1),
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: offline ? AppColors.textMuted : AppColors.text,
                  ),
                ),
                const TextSpan(text: ' L/min'),
              ],
            ),
          ),
          if (h?.lastSeen != null)
            Text(
              offline
                  ? 'Last seen ${clockTime(h!.lastSeen!, now)}'
                  : 'Updated ${relativeAge(h!.lastSeen!, now)}',
              style: muted,
            ),
          const SizedBox(height: AppSpace.l),
          _NameCard(view: v),
          const SizedBox(height: AppSpace.m),
          _PauseCard(view: v, now: now),
          const SizedBox(height: AppSpace.m),
          Card(
            child: ListTile(
              leading: const Icon(Icons.tune),
              title: Text(
                'Low flow below ${v.device.normalFlowCutoff.toStringAsFixed(1)} L/min, '
                'no flow below ${v.device.lowFlowCutoff.toStringAsFixed(1)} L/min',
              ),
              subtitle: Text(
                // Cutoffs reach the device only through its next upload (CLAUDE.md section 3).
                v.device.calibratedAt != null
                    ? 'Calibrated ${clockTime(v.device.calibratedAt!, now)}. '
                          "Applied on the device's next update."
                    : 'Using starter limits',
              ),
            ),
          ),
          const SizedBox(height: AppSpace.m),
          _HardwareCard(view: v),
          const SizedBox(height: AppSpace.m),
          _RecentChanges(deviceId: v.id, now: now),
        ],
      ),
    );
  }
}

class _NameCard extends ConsumerStatefulWidget {
  const _NameCard({required this.view});

  final DeviceView view;

  @override
  ConsumerState<_NameCard> createState() => _NameCardState();
}

class _NameCardState extends ConsumerState<_NameCard> {
  bool _editing = false;
  bool _saving = false;
  String? _error;
  late final TextEditingController _c = TextEditingController(
    text: widget.view.nickname,
  );

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
      if (mounted) setState(() => _editing = false);
    } catch (_) {
      if (mounted) setState(() => _error = Messages.renameFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.label_outline),
          title: const Text('Name'),
          subtitle: Text(widget.view.nickname),
          trailing: IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit),
            onPressed: () => setState(() {
              _c.text = widget.view.nickname;
              _editing = true;
            }),
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _c,
              autofocus: true,
              enabled: !_saving,
              maxLength: AppConfig.nicknameMax,
              decoration: InputDecoration(labelText: 'Name', errorText: _error),
              onSubmitted: (_) => _save(),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _editing = false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PauseCard extends ConsumerStatefulWidget {
  const _PauseCard({required this.view, required this.now});

  final DeviceView view;
  final DateTime now;

  @override
  ConsumerState<_PauseCard> createState() => _PauseCardState();
}

class _PauseCardState extends ConsumerState<_PauseCard> {
  bool _saving = false;

  Future<void> _set(DateTime? until) async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).setPause(widget.view.id, until);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text(Messages.saveFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paused = widget.view.pausedAt(widget.now);
    if (paused) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.notifications_paused),
          title: Text(
            'Alerts paused until ${clockTime(widget.view.device.pausedUntil!, widget.now)}',
          ),
          trailing: TextButton(
            onPressed: _saving ? null : () => _set(null),
            child: const Text('Resume'),
          ),
        ),
      );
    }
    return Card(
      child: ListTile(
        leading: const Icon(Icons.notifications_active_outlined),
        title: const Text('Alerts'),
        subtitle: const Text('Pause during repairs or a planned shutoff'),
        trailing: PopupMenuButton<Duration?>(
          enabled: !_saving,
          tooltip: 'Pause alerts',
          onSelected: (d) => _set(pauseUntil(d, DateTime.now())),
          itemBuilder: (_) => [
            for (final d in AppConfig.pauseOptions)
              PopupMenuItem(
                value: d,
                child: Text(d.inHours == 1 ? '1 hour' : '${d.inHours} hours'),
              ),
            const PopupMenuItem(
              value: null,
              child: Text('Until I resume (max 7 days)'),
            ),
          ],
          child: const Padding(
            padding: EdgeInsets.all(AppSpace.s),
            child: Text(
              'Pause alerts',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HardwareCard extends StatelessWidget {
  const _HardwareCard({required this.view});

  final DeviceView view;

  @override
  Widget build(BuildContext context) {
    final h = view.health;
    final pct = h?.batteryPercent;
    final rssi = h?.rssi;
    final signal = rssi == null ? null : signalOf(rssi);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: BatteryLine(view)),
                if (h?.chargingStatus != null && !(h?.batteryFault ?? false))
                  Text(h!.chargingStatus!),
              ],
            ),
            if (pct != null && !(h?.batteryFault ?? false)) ...[
              const SizedBox(height: AppSpace.s),
              Semantics(
                label: 'Battery $pct percent',
                child: LinearProgressIndicator(
                  value: pct / 100,
                  minHeight: 8,
                  color: view.lowBattery
                      ? StatusStyle.of(StatusKind.lowBattery).strong
                      : AppColors.primary,
                  backgroundColor: AppColors.surfaceAlt,
                ),
              ),
            ],
            if (signal != null) ...[
              const SizedBox(height: AppSpace.m),
              Semantics(
                label: 'Signal ${signal.word.toLowerCase()}',
                child: Row(
                  children: [
                    for (var i = 1; i <= 4; i++)
                      Container(
                        width: 6,
                        height: 6.0 + i * 4,
                        margin: const EdgeInsets.only(right: 3),
                        color: i <= signal.bars
                            ? AppColors.primary
                            : AppColors.outline,
                      ),
                    const SizedBox(width: AppSpace.s),
                    ExcludeSemantics(child: Text('Signal: ${signal.word}')),
                  ],
                ),
              ),
            ],
            if (h?.firmware != null) ...[
              const SizedBox(height: AppSpace.m),
              Text(
                'Firmware ${h!.firmware}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecentChanges extends ConsumerWidget {
  const _RecentChanges({required this.deviceId, required this.now});

  final String deviceId;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changes =
        ref.watch(statusChangesProvider(deviceId)).valueOrNull ?? const [];
    StatusKind kindOf(String s) => switch (s) {
      'Normal Flow' => StatusKind.normal,
      'Low Flow' => StatusKind.lowFlow,
      'No Flow' => StatusKind.noFlow,
      _ => StatusKind.waiting,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent status changes',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpace.s),
            if (changes.isEmpty) const Text('No changes in the last 7 days.'),
            for (final c in changes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                child: Row(
                  children: [
                    StatusChip(kindOf(c.flowStatus)),
                    const SizedBox(width: AppSpace.m),
                    Text(clockTime(c.at, now)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
