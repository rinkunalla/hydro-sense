import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' hide Pipeline;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart';

import '../core/config.dart';
import 'fleet_logic.dart';
import 'models.dart';
import 'pipeline.dart';

/// Everything the app and the website read about the organization's devices
/// (v3: every active member reads every device, D62), and the admin's device
/// changes (D63). Widget tests use a fake.
abstract class ClientRepository {
  /// Every device (Firestore) joined with its live node (Realtime Database).
  Stream<Fleet> fleet();

  /// A staff member's own record; null for an admin (no users doc).
  Stream<UserProfile?> profile(String uid);

  /// Every problem that overlaps [from, to), newest first (History).
  Stream<List<Problem>> problems(DateTime from, DateTime to);

  /// One device's problems overlapping the time since [since], newest first
  /// (the Details status strip).
  Stream<List<Problem>> deviceProblems(String deviceId, DateTime since);

  /// One day of 15-minute flow samples for the History graph: slot
  /// (0 to 95) to L/min. Empty when the day has no record.
  Future<Map<int, double>> dayReadings(String deviceId, String day);

  /// Admin: deletes ended problems by ID (the rules refuse an ongoing one).
  Future<void> deleteProblems(List<String> problemIds);

  /// Admin: deletes every problem that ended before [before]; returns how many.
  Future<int> deleteProblemsBefore(DateTime before);

  /// Admin: the device's name.
  Future<void> rename(String deviceId, String name);

  /// Admin: sets or (with nulls) clears the manual pin, which overrides GPS.
  Future<void> setManualPin(String deviceId, double? lat, double? lng);

  /// Admin: the own Low flow limit, or (null) back to automatic. The device
  /// gets it in its next upload's reply, within about 30 s.
  Future<void> setFlowLimit(String deviceId, double? normalCutoff);

  /// Admin: the flow sensor fitted to the device (D69). The limits start over
  /// from that sensor's starter values.
  Future<void> setSensorType(String deviceId, SensorType type);

  /// The organization's one pipeline, or null before the first save.
  Stream<Pipeline?> pipeline();

  /// Admin: saves the pipeline (the rules allow only admins).
  Future<void> savePipeline(Pipeline pipeline);
}

DateTime? _time(Object? v) => v is Timestamp ? v.toDate() : null;
DateTime? _ms(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
double? _num(Object? v) => v is num ? v.toDouble() : null;

/// A GPS coordinate, or null while device GPS is switched off.
double? _gps(Object? v) => AppConfig.deviceGpsEnabled ? _num(v) : null;

typedef _Raw = Map<Object?, Object?>;

class FirestoreClientRepository implements ClientRepository {
  FirestoreClientRepository(this._db, [this._live, this._functions]);

  final FirebaseFirestore _db;

  /// The live channel; null only where nothing reads it.
  final FirebaseDatabase? _live;

  /// The admin callables; null only where nothing changes a device.
  final FirebaseFunctions? _functions;

  static const _pipelineDoc = 'pipelines/main';

  Future<void> _updateDevice(String deviceId, Map<String, Object?> fields) =>
      _functions!.httpsCallable('updateDevice').call<Object?>({
        'deviceId': deviceId,
        ...fields,
      });

  static Device _device(DocumentSnapshot<Map<String, dynamic>> d, _Raw live) {
    final m = d.data() ?? const {};
    return Device(
      id: d.id,
      nickname: (m['nickname'] as String?) ?? d.id,
      sensorType: SensorType.fromWire(m['sensorType']),
      flowStatus: live['flowStatus'] as String?,
      flowRate: _num(live['flowRate']),
      // Effective location: the user's manual pin, else the GPS fix
      // (only while device GPS is in use).
      lat: _num(m['manualLat']) ?? _gps(m['gpsLat']),
      lng: _num(m['manualLat']) == null
          ? _gps(m['gpsLng'])
          : _num(m['manualLng']),
      gpsLat: _gps(m['gpsLat']),
      gpsLng: _gps(m['gpsLng']),
      manualPin: _num(m['manualLat']) != null && _num(m['manualLng']) != null,
      lowFlowCutoff: _num(m['lowFlowCutoff']) ?? 0.2,
      normalFlowCutoff: _num(m['normalFlowCutoff']) ?? 2.0,
      userNormalCutoff: _num(m['userNormalCutoff']),
      calibratedAt: _time(m['calibratedAt']),
      statusChangedAt: _ms(live['statusChangedAt']),
      abnormalSince: _ms(live['abnormalSince']),
    );
  }

  /// Registration and firmware from Firestore; everything live from /live.
  /// Offline as soon as the device is silent past the server's limit, on the
  /// server's clock, without waiting for the server's once-a-minute check.
  static Health _health(
    String id,
    DocumentSnapshot<Map<String, dynamic>>? d,
    _Raw live,
    DateTime serverNow,
  ) {
    final m = d?.data() ?? const {};
    final lastSeen = _ms(live['lastSeen']);
    final hb = (live['heartbeatS'] as num?)?.toInt();
    return Health(
      id: id,
      online: live['online'] == true && !silentTooLong(lastSeen, hb, serverNow),
      lastSeen: lastSeen,
      batteryPercent: (live['batteryPercent'] as num?)?.toInt(),
      batteryFault: live['batteryFault'] == true,
      chargingStatus: live['chargingStatus'] as String?,
      lowVoltageSleep: live['lowVoltageSleep'] == true,
      firmware: m['firmware'] as String?,
      registeredAt: _time(m['registeredAt']),
    );
  }

  static Problem? _problem(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const {};
    final type = ProblemType.fromWire(m['type'] as String?);
    final started = _time(m['startedAt']);
    if (type == null || started == null) return null;
    return Problem(
      id: d.id,
      deviceId: (m['deviceId'] as String?) ?? '',
      type: type,
      startedAt: started,
      endedAt: _time(m['endedAt']),
    );
  }

  @override
  Stream<Fleet> fleet() {
    final devices = _db
        .collection('devices')
        .snapshots(includeMetadataChanges: true);
    // Only registration and firmware are read here; they change rarely.
    final health = _db
        .collection('device_health')
        .snapshots(includeMetadataChanges: true);

    late StreamController<Fleet> out;
    QuerySnapshot<Map<String, dynamic>>? d;
    QuerySnapshot<Map<String, dynamic>>? h;
    final live = <String, _Raw>{};
    final liveSubs = <String, StreamSubscription<DatabaseEvent>>{};
    final subs = <StreamSubscription<Object?>>[];

    // Phone clock minus server clock, from the Realtime Database.
    var offsetMs = 0;
    Timer? tick;

    void emit() {
      if (d == null || h == null) return;
      final serverNow = DateTime.now().add(Duration(milliseconds: offsetMs));
      final byId = {for (final doc in h!.docs) doc.id: doc};
      out.add(
        Fleet([
          for (final doc in d!.docs)
            DeviceView(
              _device(doc, live[doc.id] ?? const {}),
              _health(
                doc.id,
                byId[doc.id],
                live[doc.id] ?? const {},
                serverNow,
              ),
            ),
        ], fromCache: d!.metadata.isFromCache || h!.metadata.isFromCache),
      );
    }

    // One live listener per device, added and dropped as the list changes.
    var want = <String>{};
    final retries = <String, Timer>{};

    void listenTo(String id) {
      final db = _live;
      if (db == null || liveSubs.containsKey(id)) return;
      liveSubs[id] = db
          .ref('live/$id')
          .onValue
          .listen(
            (e) {
              final v = e.snapshot.value;
              live[id] = v is Map ? v : const {};
              emit();
            },
            onError: (Object _) {
              // A refused read (for example a member entry still being
              // written): try again shortly, never give up while the device
              // is still in the list.
              live[id] = const {};
              liveSubs.remove(id);
              emit();
              retries[id]?.cancel();
              retries[id] = Timer(
                const Duration(seconds: AppConfig.liveRetryS),
                () {
                  retries.remove(id);
                  if (want.contains(id)) listenTo(id);
                },
              );
            },
          );
    }

    void follow(Iterable<String> ids) {
      want = ids.toSet();
      for (final id in liveSubs.keys.toList()) {
        if (!want.contains(id)) {
          liveSubs.remove(id)?.cancel();
          retries.remove(id)?.cancel();
          live.remove(id);
        }
      }
      want.forEach(listenTo);
    }

    out = StreamController<Fleet>(
      onListen: () {
        final db = _live;
        if (db != null) {
          subs.add(
            db.ref('.info/serverTimeOffset').onValue.listen((e) {
              final v = e.snapshot.value;
              offsetMs = v is num ? v.toInt() : 0;
            }, onError: (Object _) {}),
          );
        }
        // Re-checks silence every few seconds, so Offline shows on time.
        tick = Timer.periodic(
          const Duration(seconds: AppConfig.offlineCheckS),
          (_) => emit(),
        );
        subs.add(
          devices.listen((s) {
            d = s;
            follow(s.docs.map((x) => x.id));
            emit();
          }, onError: out.addError),
        );
        subs.add(
          health.listen((s) {
            h = s;
            emit();
          }, onError: out.addError),
        );
      },
      onCancel: () async {
        tick?.cancel();
        want = {};
        for (final t in retries.values) {
          t.cancel();
        }
        for (final s in [...subs, ...liveSubs.values]) {
          await s.cancel();
        }
      },
    );
    return out.stream;
  }

  @override
  Stream<UserProfile?> profile(String uid) =>
      _db.doc('users/$uid').snapshots().map((s) {
        final m = s.data();
        if (m == null) return null;
        return UserProfile(
          email: m['email'] as String?,
          phone: m['phone'] as String?,
          displayName: m['name'] as String?,
          username: m['username'] as String?,
        );
      });

  List<Problem> _overlapping(
    QuerySnapshot<Map<String, dynamic>> s,
    DateTime from,
    DateTime to,
  ) {
    final now = DateTime.now();
    return s.docs
        .map(_problem)
        .whereType<Problem>()
        .where((p) => p.overlaps(from, to, now))
        .toList();
  }

  @override
  Stream<List<Problem>> problems(DateTime from, DateTime to) => _db
      .collection('problems')
      .where('startedAt', isLessThan: Timestamp.fromDate(to))
      .orderBy('startedAt', descending: true)
      .limit(AppConfig.problemQueryLimit)
      .snapshots()
      .map((s) => _overlapping(s, from, to));

  @override
  Stream<List<Problem>> deviceProblems(String deviceId, DateTime since) => _db
      .collection('problems')
      .where('deviceId', isEqualTo: deviceId)
      .orderBy('startedAt', descending: true)
      .limit(AppConfig.stripProblemLimit)
      .snapshots()
      .map((s) => _overlapping(s, since, DateTime.now()));

  @override
  Future<Map<int, double>> dayReadings(String deviceId, String day) async {
    try {
      final s = await _db.doc('readings/${deviceId}_$day').get();
      final rates = s.data()?['rates'];
      if (rates is! Map) return const {};
      return {
        for (final e in rates.entries)
          if (int.tryParse('${e.key}') case final slot?)
            if (e.value is num) slot: (e.value as num).toDouble(),
      };
    } on FirebaseException catch (e) {
      // A day with no record reads as empty.
      if (e.code == 'permission-denied' || e.code == 'not-found') {
        return const {};
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteProblems(List<String> problemIds) async {
    for (var i = 0; i < problemIds.length; i += 400) {
      final batch = _db.batch();
      for (final id in problemIds.skip(i).take(400)) {
        batch.delete(_db.doc('problems/$id'));
      }
      await batch.commit();
    }
  }

  @override
  Future<int> deleteProblemsBefore(DateTime before) async {
    final s = await _db
        .collection('problems')
        .where('startedAt', isLessThan: Timestamp.fromDate(before))
        .get();
    final ids = [
      for (final d in s.docs)
        if (_problem(d) case final p?
            when p.endedAt != null && p.endedAt!.isBefore(before))
          p.id,
    ];
    await deleteProblems(ids);
    return ids.length;
  }

  @override
  Future<void> rename(String deviceId, String name) =>
      _updateDevice(deviceId, {'name': name});

  @override
  Future<void> setManualPin(String deviceId, double? lat, double? lng) =>
      _updateDevice(deviceId, {'manualLat': lat, 'manualLng': lng});

  @override
  Future<void> setFlowLimit(String deviceId, double? normalCutoff) =>
      _updateDevice(deviceId, {'userNormalCutoff': normalCutoff});

  @override
  Future<void> setSensorType(String deviceId, SensorType type) =>
      _updateDevice(deviceId, {'sensorType': type.wire});

  @override
  Stream<Pipeline?> pipeline() =>
      _db.doc(_pipelineDoc).snapshots().map((s) => Pipeline.fromMap(s.data()));

  @override
  Future<void> savePipeline(Pipeline pipeline) => _db.doc(_pipelineDoc).set({
    ...pipeline.toMap(),
    'updatedAt': FieldValue.serverTimestamp(),
  });
}
