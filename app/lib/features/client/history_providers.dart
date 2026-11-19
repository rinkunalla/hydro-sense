import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/live_db.dart';
import 'live_trend.dart' show TrendRange;

import '../../core/config.dart';
import '../../data/models.dart';
import '../../data/providers.dart';

/// One device's problems over the last 24 h, for the Details status strip.
final deviceProblemsProvider = StreamProvider.autoDispose
    .family<List<Problem>, String>((ref, deviceId) {
      final uid = ref.watch(uidProvider);
      if (uid == null) return Stream.value(const []);
      final since = DateTime.now().subtract(
        const Duration(hours: AppConfig.flowChartHours),
      );
      return ref.watch(repositoryProvider).deviceProblems(uid, deviceId, since);
    });

/// The account's problems touching one month (History). The key is the
/// first day of the month.
final monthProblemsProvider = StreamProvider.autoDispose
    .family<List<Problem>, DateTime>((ref, month) {
      final uid = ref.watch(uidProvider);
      if (uid == null) return Stream.value(const []);
      final first = DateTime(month.year, month.month);
      final next = DateTime(month.year, month.month + 1);
      return ref.watch(repositoryProvider).problems(uid, first, next);
    });

/// One device's day of 15-minute flow samples for the History graph.
/// The key is (device ID, "yyyy-MM-dd"); one read per device and day.
final dayReadingsProvider = FutureProvider.autoDispose
    .family<Map<int, double>, (String, String)>(
      (ref, key) => ref.watch(repositoryProvider).dayReadings(key.$1, key.$2),
    );

/// "yyyy-MM-dd" of [t] on the phone (the app is used in the Philippines, so
/// this is the Manila day the server files readings under).
String dayKey(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// The 15-minute slot of the day (0 to 95) that [t] falls in.
int daySlot(DateTime t) => (t.hour * 60 + t.minute) ~/ AppConfig.readingSlotMin;

/// "Today so far" on a device card: today's readings, read once and then
/// every 15 minutes while the card is on screen; a new day starts at midnight.
final todayReadingsProvider = StreamProvider.autoDispose
    .family<Map<int, double>, String>((ref, deviceId) async* {
      final repo = ref.watch(repositoryProvider);
      while (true) {
        yield await repo.dayReadings(deviceId, dayKey(DateTime.now()));
        await Future<void>.delayed(
          const Duration(minutes: AppConfig.todayRefreshMin),
        );
      }
    });

/// The minute of the day (0 to 1439) that [t] falls in.
int dayMinute(DateTime t) => t.hour * 60 + t.minute;

/// Today's per-minute flow for one device, live from the Realtime
/// Database: the server adds this minute's reading with every upload. The key
/// is (device ID, "yyyy-MM-dd"); a refused read (owner still being mirrored)
/// gives an empty day.
final todaySeriesProvider = StreamProvider.autoDispose
    .family<Map<int, double>, (String, String)>((ref, key) {
      return liveDatabase()
          .ref('series/${key.$1}/${key.$2}')
          .onValue
          .map((e) {
            final v = e.snapshot.value;
            final out = <int, double>{};
            if (v is Map) {
              for (final entry in v.entries) {
                final m = int.tryParse('${entry.key}');
                if (m != null && entry.value is num) {
                  out[m] = (entry.value as num).toDouble();
                }
              }
            } else if (v is List) {
              // The Realtime Database returns dense number keys as a list.
              for (var m = 0; m < v.length; m++) {
                if (v[m] is num) out[m] = (v[m] as num).toDouble();
              }
            }
            return out;
          })
          .handleError((Object _) {});
    });

const _trendKey = 'trend_range';

/// The card chart's range, 1 h, 2 h or 24 h, remembered on the phone.
class TrendRangeNotifier extends StateNotifier<TrendRange> {
  TrendRangeNotifier() : super(TrendRange.hour) {
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        _trendKey,
      );
      for (final r in TrendRange.values) {
        if (mounted && r.name == saved) state = r;
      }
    } catch (_) {}
  }

  Future<void> set(TrendRange r) async {
    state = r;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _trendKey,
        r.name,
      );
    } catch (_) {}
  }
}

final trendRangeProvider =
    StateNotifierProvider<TrendRangeNotifier, TrendRange>(
      (ref) => TrendRangeNotifier(),
    );
