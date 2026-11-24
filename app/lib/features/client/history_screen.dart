import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/config.dart';
import '../../core/file_save.dart';
import '../../data/admin_logic.dart' show problemsCsv;
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/history_logic.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import 'day_graph.dart';
import 'history_providers.dart';

/// Words, icon and colour per problem type; status colours as everywhere.
({String word, IconData icon, Color color}) problemStyle(ProblemType t) =>
    switch (t) {
      ProblemType.noFlow => (
        word: 'No water',
        icon: StatusStyle.of(StatusKind.noFlow).icon,
        color: StatusStyle.of(StatusKind.noFlow).strong,
      ),
      ProblemType.lowFlow => (
        word: 'Low flow',
        icon: StatusStyle.of(StatusKind.lowFlow).icon,
        color: StatusStyle.of(StatusKind.lowFlow).strong,
      ),
      ProblemType.offline => (
        word: 'Offline',
        icon: StatusStyle.of(StatusKind.offline).icon,
        color: StatusStyle.of(StatusKind.offline).strong,
      ),
      ProblemType.batteryLow => (
        word: 'Low battery',
        icon: StatusStyle.of(StatusKind.lowBattery).icon,
        color: StatusStyle.of(StatusKind.lowBattery).strong,
      ),
    };

/// "6:10 AM to 7:02 AM (52 min)", or "Since 6:10 AM · 42 min" while ongoing.
String problemTimeText(Problem p, DateTime now) {
  if (p.ongoing) {
    return 'Since ${clockTime(p.startedAt, now)} · '
        '${durationText(now.difference(p.startedAt))}';
  }
  return '${clockTime(p.startedAt, now)} to ${clockTime(p.endedAt!, now)} '
      '(${durationText(p.endedAt!.difference(p.startedAt))})';
}

/// History: one calendar for the whole account, with filters, the day's
/// problems, notes and delete. Opened from Devices, or from a device's
/// Details already filtered to that device.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, this.deviceId});

  final String? deviceId;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  late DateTime _month;
  late DateTime _day;
  late HistoryFilter _filter;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _day = dayStart(now);
    _filter = HistoryFilter(
      deviceIds: widget.deviceId == null ? const {} : {widget.deviceId!},
    );
  }

  void _back() => context.canPop() ? context.pop() : context.go('/devices');

  void _moveMonth(int by) {
    final m = DateTime(_month.year, _month.month + by);
    setState(() {
      _month = m;
      final now = DateTime.now();
      _day = m.year == now.year && m.month == now.month ? dayStart(now) : m;
    });
  }

  /// Shows [day]'s month with that day selected.
  void _goTo(DateTime day) => setState(() {
    _month = DateTime(day.year, day.month);
    _day = dayStart(day);
  });

  /// The oldest day History can still hold (records are kept a year).
  DateTime get _oldest => dayStart(
    DateTime.now().subtract(const Duration(days: AppConfig.problemKeepDays)),
  );

  /// The Year, Month or Day dropdown changed: shows that day, kept inside
  /// History's year of records and never in the future.
  void _select({int? year, int? month, int? day}) {
    // Let go of the dropdown, so it is not left highlighted after a choice.
    FocusManager.instance.primaryFocus?.unfocus();
    final y = year ?? _day.year;
    final m = month ?? _day.month;
    final last = DateTime(y, m + 1, 0).day; // Feb 30 becomes Feb 28 or 29
    final d = (day ?? _day.day).clamp(1, last);
    var picked = DateTime(y, m, d);
    final today = dayStart(DateTime.now());
    if (picked.isAfter(today)) picked = today;
    if (picked.isBefore(_oldest)) picked = _oldest;
    _goTo(picked);
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(clockProvider).valueOrNull ?? DateTime.now();
    final views = ref.watch(fleetProvider).valueOrNull?.views ?? const [];
    final names = {for (final v in views) v.id: v.nickname};
    final isAdmin = ref.watch(isAdminProvider);
    final all = ref.watch(monthProblemsProvider(_month));
    final thisMonth = DateTime(now.year, now.month);

    // Unknown before the first of the shown devices registered.
    DateTime? knownFrom;
    for (final v in views) {
      if (_filter.deviceIds.isNotEmpty && !_filter.deviceIds.contains(v.id)) {
        continue;
      }
      final r = v.health?.registeredAt;
      if (r != null && (knownFrom == null || r.isBefore(knownFrom))) {
        knownFrom = r;
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: all.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(child: Text(Messages.generic)),
          data: (list) {
            final shown = list.where(_filter.keeps).toList();
            final marks = monthMarks(_month, shown, now, knownFrom: knownFrom);
            final summary = monthSummary(_month, shown, now);
            final dayEnd = DateTime(_day.year, _day.month, _day.day + 1);
            final ofDay =
                shown.where((p) => p.overlaps(_day, dayEnd, now)).toList()
                  ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
            return ListView(
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
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text('History', style: AppText.title(24)),
                      ),
                    ),
                    if (isAdmin)
                      PopupMenuButton<int>(
                        tooltip: 'More',
                        icon: const Icon(Icons.more_vert_rounded),
                        onSelected: (v) => v == 1
                            ? saveTextFile(
                                'hydro-sense-history-${DateFormat('yyyy-MM').format(_month)}.csv',
                                problemsCsv(shown, names),
                              )
                            : _clearOlder(),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 1,
                            child: Text('Download CSV (shown records)'),
                          ),
                          PopupMenuItem(
                            value: 0,
                            child: Text('Clear older records'),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.s),
                _Filters(
                  filter: _filter,
                  names: names,
                  onChanged: (f) => setState(() => _filter = f),
                ),
                const SizedBox(height: AppSpace.m),
                GlassPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Previous month',
                            icon: const Icon(Icons.chevron_left_rounded),
                            onPressed: () => _moveMonth(-1),
                          ),
                          // Pick a month, day and year straight from dropdowns.
                          Expanded(
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: AppSpace.s,
                              children: [
                                DropdownButton<int>(
                                  value: _day.month,
                                  underline: const SizedBox.shrink(),
                                  items: [
                                    for (var m = 1; m <= 12; m++)
                                      DropdownMenuItem(
                                        value: m,
                                        enabled:
                                            !DateTime(
                                              _day.year,
                                              m,
                                            ).isAfter(thisMonth) &&
                                            !DateTime(
                                              _day.year,
                                              m + 1,
                                            ).isBefore(
                                              _oldest.add(
                                                const Duration(days: 1),
                                              ),
                                            ),
                                        child: Text(
                                          DateFormat(
                                            'MMMM',
                                            'en_US',
                                          ).format(DateTime(2026, m)),
                                        ),
                                      ),
                                  ],
                                  onChanged: (m) => _select(month: m),
                                ),
                                DropdownButton<int>(
                                  value: _day.day,
                                  underline: const SizedBox.shrink(),
                                  items: [
                                    for (
                                      var d = 1;
                                      d <=
                                          DateTime(
                                            _day.year,
                                            _day.month + 1,
                                            0,
                                          ).day;
                                      d++
                                    )
                                      DropdownMenuItem(
                                        value: d,
                                        enabled: !DateTime(
                                          _day.year,
                                          _day.month,
                                          d,
                                        ).isAfter(dayStart(now)),
                                        child: Text('$d'),
                                      ),
                                  ],
                                  onChanged: (d) => _select(day: d),
                                ),
                                DropdownButton<int>(
                                  value: _day.year,
                                  underline: const SizedBox.shrink(),
                                  items: [
                                    for (
                                      var y = now.year;
                                      y >=
                                          math.max(
                                            _oldest.year,
                                            AppConfig.firstRecordYear,
                                          );
                                      y--
                                    )
                                      DropdownMenuItem(
                                        value: y,
                                        child: Text('$y'),
                                      ),
                                  ],
                                  onChanged: (y) => _select(year: y),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Next month',
                            icon: const Icon(Icons.chevron_right_rounded),
                            onPressed: _month.isBefore(thisMonth)
                                ? () => _moveMonth(1)
                                : null,
                          ),
                        ],
                      ),
                      Center(
                        child: TextButton.icon(
                          onPressed: () => _goTo(DateTime.now()),
                          icon: const Icon(Icons.today_rounded, size: 18),
                          label: const Text('Today'),
                        ),
                      ),
                      Text(
                        summary.count == 0
                            ? 'No problems this month'
                            : '${summary.count} problem${summary.count == 1 ? '' : 's'}'
                                  '${summary.noWater > Duration.zero ? ' · ${durationText(summary.noWater)} without water' : ''}',
                        textAlign: TextAlign.center,
                        style: AppText.note,
                      ),
                      const SizedBox(height: AppSpace.m),
                      _MonthGrid(
                        month: _month,
                        marks: marks,
                        selected: _day,
                        now: now,
                        ongoing: shown.any((p) => p.ongoing),
                        onPick: (d) => setState(() => _day = d),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.l),
                Row(
                  children: [
                    Expanded(
                      child: SectionLabel(
                        DateFormat('EEE, MMM d', 'en_US').format(_day),
                      ),
                    ),
                    if (isAdmin && ofDay.any((p) => !p.ongoing))
                      TextButton(
                        onPressed: () => _deleteMany(
                          ofDay.where((p) => !p.ongoing).toList(),
                          'this day',
                        ),
                        child: const Text('Delete this day'),
                      ),
                  ],
                ),
                // The day's flow, one small graph per shown device.
                for (final v in views)
                  if (_filter.deviceIds.isEmpty ||
                      _filter.deviceIds.contains(v.id))
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.s),
                      child: _DayGraphCard(
                        view: v,
                        day: DateFormat('yyyy-MM-dd', 'en_US').format(_day),
                      ),
                    ),
                if (ofDay.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      marks[_day]?.clean ?? false
                          ? 'No problems on ${DateFormat('MMM d', 'en_US').format(_day)}.'
                          : 'No record for this day.',
                      style: AppText.body,
                    ),
                  ),
                for (final p in ofDay)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.s),
                    child: _ProblemTile(
                      problem: p,
                      deviceName: names[p.deviceId] ?? p.deviceId,
                      now: now,
                      onTap: () => _openProblem(p, names[p.deviceId]),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteMany(List<Problem> list, String what) async {
    final n = list.length;
    final ok = await _confirm(
      'Delete $n record${n == 1 ? '' : 's'} from $what?',
      'This can\'t be undone. Problems still going on are kept.',
      'Delete',
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(repositoryProvider).deleteProblems([
        for (final p in list) p.id,
      ]);
      if (mounted) showToast(context, 'Deleted $n record${n == 1 ? '' : 's'}');
    } catch (_) {
      if (mounted) showToast(context, Messages.saveFailed);
    }
  }

  Future<void> _clearOlder() async {
    final months = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Clear older records'),
        children: [
          for (final m in AppConfig.historyClearMonths)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, m),
              child: Text('Older than $m months'),
            ),
        ],
      ),
    );
    if (months == null || !mounted) return;
    final ok = await _confirm(
      'Delete records older than $months months?',
      'Every ended problem before then is deleted for every device. '
          'This can\'t be undone.',
      'Delete',
    );
    if (!ok || !mounted) return;
    final now = DateTime.now();
    try {
      final n = await ref
          .read(repositoryProvider)
          .deleteProblemsBefore(
            DateTime(now.year, now.month - months, now.day),
          );
      if (mounted) {
        showToast(
          context,
          n == 0
              ? 'Nothing older than $months months'
              : 'Deleted $n record${n == 1 ? '' : 's'}',
        );
      }
    } catch (_) {
      if (mounted) showToast(context, Messages.saveFailed);
    }
  }

  Future<void> _openProblem(Problem p, String? deviceName) async {
    await showModalBottomSheet<void>(
      context: context,
      // Above the floating tab bar, which otherwise covers the sheet's bottom.
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => _ProblemSheet(
        problem: p,
        deviceName: deviceName ?? p.deviceId,
        onDelete: () async {
          Navigator.pop(c);
          await _deleteMany([p], 'History');
        },
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.filter,
    required this.names,
    required this.onChanged,
  });

  final HistoryFilter filter;
  final Map<String, String> names;
  final ValueChanged<HistoryFilter> onChanged;

  Future<void> _pickDevices(BuildContext context) async {
    final picked = {...filter.deviceIds};
    final done = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              CheckboxListTile(
                title: const Text('All devices'),
                value: picked.isEmpty,
                onChanged: (_) => set(picked.clear),
              ),
              for (final e in names.entries)
                CheckboxListTile(
                  title: Text(e.value),
                  value: picked.contains(e.key),
                  onChanged: (on) => set(
                    () => on == true ? picked.add(e.key) : picked.remove(e.key),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(AppSpace.l),
                child: FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Show'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (done == true) onChanged(filter.copyWith(deviceIds: picked));
  }

  @override
  Widget build(BuildContext context) {
    final ids = filter.deviceIds;
    final deviceLabel = ids.isEmpty
        ? 'All devices'
        : ids.length == 1
        ? (names[ids.first] ?? ids.first)
        : '${ids.length} devices';
    return Wrap(
      spacing: AppSpace.s,
      runSpacing: AppSpace.s,
      children: [
        // Always shown, so History looks the same from Devices and from a
        // device's Details (there it starts on that device).
        if (names.isNotEmpty || ids.isNotEmpty)
          ActionChip(
            avatar: const Icon(Icons.sensors_rounded, size: 18),
            label: Text('$deviceLabel ▾'),
            onPressed: () => _pickDevices(context),
          ),
        for (final t in ProblemType.values)
          FilterChip(
            label: Text(problemStyle(t).word),
            selected: filter.types.contains(t),
            onSelected: (on) {
              final next = {...filter.types};
              on ? next.add(t) : next.remove(t);
              onChanged(filter.copyWith(types: next));
            },
          ),
        for (final s in const [ProblemState.ongoing, ProblemState.resolved])
          ChoiceChip(
            label: Text(s == ProblemState.ongoing ? 'Ongoing' : 'Resolved'),
            selected: filter.state == s,
            onSelected: (on) =>
                onChanged(filter.copyWith(state: on ? s : ProblemState.all)),
          ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.marks,
    required this.selected,
    required this.now,
    required this.ongoing,
    required this.onPick,
  });

  final DateTime month;
  final Map<DateTime, DayMark> marks;
  final DateTime selected;
  final DateTime now;

  /// A problem is still going on: today gets a soft ring.
  final bool ongoing;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final lead = first.weekday % 7; // Sunday first
    final today = dayStart(now);
    const heads = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    final cells = <Widget>[
      for (final h in heads) Center(child: Text(h, style: AppText.label)),
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (var d = 1; d <= days; d++)
        _DayCell(
          day: DateTime(month.year, month.month, d),
          mark: marks[DateTime(month.year, month.month, d)] ?? const DayMark(),
          selected: DateTime(month.year, month.month, d) == selected,
          today: DateTime(month.year, month.month, d) == today,
          future: DateTime(month.year, month.month, d).isAfter(today),
          ongoingToday:
              ongoing && DateTime(month.year, month.month, d) == today,
          onTap: onPick,
        ),
    ];
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 0.82,
      children: cells,
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.mark,
    required this.selected,
    required this.today,
    required this.future,
    required this.ongoingToday,
    required this.onTap,
  });

  final DateTime day;
  final DayMark mark;
  final bool selected;
  final bool today;
  final bool future;
  final bool ongoingToday;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final words = [
      DateFormat('MMMM d', 'en_US').format(day),
      if (mark.types.isNotEmpty)
        mark.types.map((t) => problemStyle(t).word).join(', ')
      else if (mark.clean)
        'no problems',
    ].join(', ');
    return Semantics(
      button: !future,
      selected: selected,
      label: words,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: future ? null : () => onTap(day),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: selected
                    ? Border.all(color: AppColors.deepCyan, width: 2)
                    : ongoingToday
                    ? Border.all(
                        color: StatusStyle.of(
                          StatusKind.noFlow,
                        ).strong.withValues(alpha: 0.5),
                        width: 2,
                      )
                    : null,
              ),
              child: Text(
                '${day.day}',
                style: AppText.body.copyWith(
                  color: future
                      ? AppColors.steel.withValues(alpha: 0.5)
                      : AppColors.ink,
                  fontWeight: today ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              height: 6,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final t in ProblemType.values)
                    if (mark.types.contains(t))
                      _Dot(color: problemStyle(t).color),
                  if (mark.types.isEmpty && mark.clean)
                    _Dot(
                      color: StatusStyle.of(StatusKind.normal).strong,
                      size: 4,
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

class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.size = 6});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    margin: const EdgeInsets.symmetric(horizontal: 1.5),
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _ProblemTile extends StatelessWidget {
  const _ProblemTile({
    required this.problem,
    required this.deviceName,
    required this.now,
    required this.onTap,
  });

  final Problem problem;
  final String deviceName;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final st = problemStyle(problem.type);
    return GlassPanel(
      padding: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: Icon(st.icon, color: st.color),
        title: Text('${st.word} · $deviceName', style: AppText.strong),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(problemTimeText(problem, now), style: AppText.note)],
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

/// One problem: its times, and for an admin Delete once it ended (D63).
class _ProblemSheet extends ConsumerWidget {
  const _ProblemSheet({
    required this.problem,
    required this.deviceName,
    required this.onDelete,
  });

  final Problem problem;
  final String deviceName;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = problem;
    final st = problemStyle(p.type);
    final now = DateTime.now();
    final isAdmin = ref.watch(isAdminProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.l, 0, AppSpace.l, AppSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(st.icon, color: st.color),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Text(
                  '${st.word} · $deviceName',
                  style: AppText.title(18),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.s),
          Text(problemTimeText(p, now), style: AppText.body),
          if (isAdmin) ...[
            const SizedBox(height: AppSpace.l),
            if (p.ongoing)
              Text(
                'This problem is still going on, so it can\'t be deleted yet.',
                style: AppText.note,
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: SecondaryButton(
                  label: 'Delete',
                  icon: Icons.delete_outline_rounded,
                  destructive: true,
                  onPressed: onDelete,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// One device's flow for the selected day, read once (one record per day).
class _DayGraphCard extends ConsumerWidget {
  const _DayGraphCard({required this.view, required this.day});

  final DeviceView view;
  final String day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rates = ref.watch(dayReadingsProvider((view.id, day)));
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Flow · ${view.nickname}', style: AppText.strong),
          const SizedBox(height: AppSpace.s),
          rates.when(
            loading: () => const SizedBox(
              height: 90,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => Text(Messages.generic, style: AppText.note),
            data: (r) {
              // Today: the per-minute series too, like the device card.
              final today = day == dayKey(DateTime.now());
              if (!today) {
                return DayGraph(rates: r, lowBelow: view.device.limits.normal);
              }
              final series =
                  ref.watch(todaySeriesProvider((view.id, day))).valueOrNull ??
                  const <int, double>{};
              return DayGraph(
                rates: {
                  for (final e in r.entries)
                    e.key * AppConfig.readingSlotMin: e.value,
                  ...series,
                },
                slots: 1440,
                endSlot: dayMinute(DateTime.now()),
                lowBelow: view.device.limits.normal,
              );
            },
          ),
        ],
      ),
    );
  }
}
