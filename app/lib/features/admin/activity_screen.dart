import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/config.dart';
import '../../core/file_save.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../core/time_format.dart';
import '../../data/admin_logic.dart';
import '../../data/admin_providers.dart';
import '../../data/admin_repository.dart';
import 'admin_widgets.dart';

/// Date range choices on the Activity page.
enum _Range { week, month, all, calendar }

/// Activity: every admin action and each deletion request, newest
/// first, on its own page. Search, filters by group, admin and dates, Restore
/// where it still applies, more on request, and Download CSV. Nobody can edit
/// or delete an entry.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  static const _page = 100;

  final _search = TextEditingController();
  final List<AuditEntry> _entries = [];
  bool _loading = true;
  bool _more = false;
  String? _error;

  AuditGroup _group = AuditGroup.all;
  String? _admin;
  _Range _range = _Range.all;

  // The date dropdowns: a year, then optionally a month and a day.
  int _year = DateTime.now().year;
  int? _month;
  int? _day;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final before = reset || _entries.isEmpty ? null : _entries.last.at;
      final page = await ref
          .read(adminRepositoryProvider)
          .audit(limit: _page, before: before);
      if (!mounted) return;
      setState(() {
        if (reset) _entries.clear();
        _entries.addAll(page);
        _more = page.length == _page;
      });
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  ({DateTime? from, DateTime? to}) get _window {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      _Range.week => (from: today.subtract(const Duration(days: 6)), to: null),
      _Range.month => (
        from: today.subtract(const Duration(days: 29)),
        to: null,
      ),
      _Range.all => (from: null, to: null),
      _Range.calendar => calendarWindow(_year, _month, _day),
    };
  }

  /// Any dropdown change switches the dates to that year, month or day.
  void _pick({
    int? year,
    int? month,
    int? day,
    bool clearMonth = false,
    bool clearDay = false,
  }) {
    // Let go of the dropdown, so it is not left highlighted after a choice.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _range = _Range.calendar;
      if (year != null) _year = year;
      if (clearMonth) {
        _month = null;
        _day = null;
      } else if (month != null) {
        _month = month;
      }
      if (clearDay) _day = null;
      if (day != null) _day = day;
      // A day that does not exist in the new month (Feb 30) is dropped.
      if (_month != null &&
          _day != null &&
          _day! > daysInMonth(_year, _month!)) {
        _day = null;
      }
    });
  }

  Future<void> _restore(AuditEntry e) async {
    final repo = ref.read(adminRepositoryProvider);
    try {
      if (e.action == 'user_deleted') {
        await repo.restoreUser(e.targetId!);
      } else {
        await repo.restoreDevice(e.targetId!);
      }
      ref.invalidate(adminUsersProvider);
      ref.invalidate(adminDevicesProvider);
      await _load(reset: true);
      if (mounted) showToast(context, 'Restored.');
    } catch (err) {
      if (mounted) showToast(context, adminErrorText(err));
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final w = _window;
    final shown = [
      for (final e in _entries)
        if (auditMatches(e, _group, _admin) &&
            auditSearch(e, _search.text) &&
            auditInRange(e, w.from, w.to))
          e,
    ];
    final admins = {
      for (final e in _entries)
        if (e.adminEmail != null) e.adminEmail!,
    }.toList()..sort();
    const groups = {
      AuditGroup.all: 'All',
      AuditGroup.users: 'Users',
      AuditGroup.devices: 'Devices',
      AuditGroup.admins: 'Admins',
      AuditGroup.requests: 'Deletion requests',
    };
    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
        AdminPageHeader(
          title: 'Activity',
          actions: [
            SecondaryButton(
              label: 'Refresh',
              icon: Icons.refresh_rounded,
              onPressed: _loading ? null : () => _load(reset: true),
            ),
            SecondaryButton(
              label: 'Download CSV',
              icon: Icons.download_rounded,
              onPressed: shown.isEmpty
                  ? null
                  : () => saveTextFile(
                      'hydro-sense-activity-${DateFormat('yyyy-MM-dd').format(now)}.csv',
                      auditCsv(shown),
                    ),
            ),
          ],
        ),
        Text(
          "Deletes, removals, reassignments and deletion requests by any "
          "admin. Entries can't be changed or deleted.",
          style: AppText.note,
        ),
        const SizedBox(height: AppSpace.m),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Search by name, ID or admin email',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
        const SizedBox(height: AppSpace.s),
        Wrap(
          spacing: AppSpace.s,
          runSpacing: AppSpace.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final g in AuditGroup.values)
              FilterPill(
                label: groups[g]!,
                selected: _group == g,
                onTap: () => setState(() => _group = g),
              ),
            if (admins.length > 1)
              DropdownButton<String?>(
                value: _admin,
                hint: const Text('Any admin'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Any admin')),
                  for (final a in admins)
                    DropdownMenuItem(value: a, child: Text(a)),
                ],
                onChanged: (v) {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => _admin = v);
                },
              ),
          ],
        ),
        const SizedBox(height: AppSpace.s),
        Wrap(
          spacing: AppSpace.s,
          runSpacing: AppSpace.s,
          children: [
            FilterPill(
              label: 'Last 7 days',
              selected: _range == _Range.week,
              onTap: () => setState(() => _range = _Range.week),
            ),
            FilterPill(
              label: 'Last 30 days',
              selected: _range == _Range.month,
              onTap: () => setState(() => _range = _Range.month),
            ),
            FilterPill(
              label: 'All dates',
              selected: _range == _Range.all,
              onTap: () => setState(() => _range = _Range.all),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.s),
        // Or a year, month and day straight from dropdowns.
        Wrap(
          spacing: AppSpace.m,
          runSpacing: AppSpace.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Dates:',
              style: AppText.strong.copyWith(
                color: _range == _Range.calendar ? AppColors.deepCyan : null,
              ),
            ),
            DropdownButton<int>(
              value: _range == _Range.calendar ? _year : null,
              hint: const Text('Year'),
              items: [
                for (
                  var y = now.year;
                  y >= math.max(now.year - 1, AppConfig.firstRecordYear);
                  y--
                )
                  DropdownMenuItem(value: y, child: Text('$y')),
              ],
              onChanged: (y) => _pick(year: y),
            ),
            DropdownButton<int?>(
              value: _range == _Range.calendar ? _month : null,
              hint: const Text('Month'),
              items: [
                const DropdownMenuItem(value: null, child: Text('All months')),
                for (var m = 1; m <= 12; m++)
                  DropdownMenuItem(
                    value: m,
                    enabled: DateTime(
                      _year,
                      m,
                    ).isBefore(DateTime(now.year, now.month + 1)),
                    child: Text(
                      DateFormat('MMMM', 'en_US').format(DateTime(2026, m)),
                    ),
                  ),
              ],
              onChanged: (m) =>
                  m == null ? _pick(clearMonth: true) : _pick(month: m),
            ),
            DropdownButton<int?>(
              value: _range == _Range.calendar ? _day : null,
              hint: const Text('Day'),
              items: _month == null || _range != _Range.calendar
                  ? null
                  : [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('All days'),
                      ),
                      for (var d = 1; d <= daysInMonth(_year, _month!); d++)
                        DropdownMenuItem(value: d, child: Text('$d')),
                    ],
              onChanged: (d) =>
                  d == null ? _pick(clearDay: true) : _pick(day: d),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.m),
        if (_error != null) ErrorLine(_error!),
        GlassPanel(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (shown.isEmpty && !_loading)
                Padding(
                  padding: const EdgeInsets.all(AppSpace.l),
                  child: Text(
                    _entries.isEmpty ? 'Nothing yet.' : 'Nothing matches.',
                    style: AppText.body,
                  ),
                ),
              for (final (i, e) in shown.indexed) ...[
                if (i > 0) const Divider(height: 1, thickness: 0.5),
                ListTile(
                  title: Text(auditSentence(e), style: AppText.body),
                  subtitle: e.at == null
                      ? null
                      : Text(
                          '${dayMonthYear(e.at!)} · ${clockTime(e.at!, now)}',
                          style: AppText.note,
                        ),
                  trailing:
                      (e.action == 'user_deleted' ||
                              e.action == 'device_removed') &&
                          e.targetId != null
                      ? TextButton(
                          onPressed: () => _restore(e),
                          child: const Text('Restore'),
                        )
                      : null,
                ),
              ],
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(AppSpace.m),
                  child: LinearProgressIndicator(),
                ),
              if (_more && !_loading)
                Center(
                  child: TextButton(
                    onPressed: () => _load(),
                    child: const Text('Show older'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A user's or device's own recent activity, inside its side panel.
class TargetActivity extends ConsumerWidget {
  const TargetActivity({super.key, required this.targetId});

  final String targetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(targetAuditProvider(targetId));
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Activity', style: AppText.strong),
        const SizedBox(height: AppSpace.s),
        log.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => ErrorLine(adminErrorText(e)),
          data: (entries) => entries.isEmpty
              ? Text('No activity yet.', style: AppText.note)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${auditSentence(e)}'
                          '${e.at == null ? '' : ' · ${clockTime(e.at!, now)}'}',
                          style: AppText.note.copyWith(color: AppColors.ink),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
