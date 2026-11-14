import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../core/config.dart';
import 'models.dart';

/// Everything the client app reads and writes. Widget tests use a fake.
abstract class ClientRepository {
  /// The client's devices joined with their health (both filtered by ownerUid,
  /// as the rules require).
  Stream<Fleet> fleet(String uid);
  Stream<UserProfile?> profile(String uid);
  Stream<List<StatusChange>> statusChanges(String deviceId);

  Future<void> rename(String deviceId, String nickname);

  Future<void> confirmPasswordChanged();
}

DateTime? _time(Object? v) => v is Timestamp ? v.toDate() : null;
double? _num(Object? v) => v is num ? v.toDouble() : null;

class FirestoreClientRepository implements ClientRepository {
  FirestoreClientRepository(this._db, this._functions);

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  static Device _device(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const {};
    return Device(
      id: d.id,
      nickname: (m['nickname'] as String?) ?? d.id,
      flowStatus: m['flowStatus'] as String?,
      flowRate: _num(m['flowRate']),
      // Effective location (D25): the user's manual pin, else the GPS fix.
      lat: _num(m['manualLat']) ?? _num(m['gpsLat']),
      lng: _num(m['manualLat']) == null
          ? _num(m['gpsLng'])
          : _num(m['manualLng']),
      lowFlowCutoff: _num(m['lowFlowCutoff']) ?? 0.2,
      normalFlowCutoff: _num(m['normalFlowCutoff']) ?? 2.0,
      calibratedAt: _time(m['calibratedAt']),
      statusChangedAt: _time(m['statusChangedAt']),
    );
  }

  static Health _health(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const {};
    return Health(
      id: d.id,
      online: m['online'] == true,
      lastSeen: _time(m['lastSeen']),
      batteryPercent: (m['batteryPercent'] as num?)?.toInt(),
      batteryVoltage: _num(m['batteryVoltage']),
      batteryFault: m['batteryFault'] == true,
      chargingStatus: m['chargingStatus'] as String?,
      lowVoltageSleep: m['lowVoltageSleep'] == true,
      rssi: (m['rssi'] as num?)?.toInt(),
      firmware: m['firmware'] as String?,
    );
  }

  @override
  Stream<Fleet> fleet(String uid) {
    final devices = _db
        .collection('devices')
        .where('ownerUid', isEqualTo: uid)
        .snapshots(includeMetadataChanges: true);
    final health = _db
        .collection('device_health')
        .where('ownerUid', isEqualTo: uid)
        .snapshots(includeMetadataChanges: true);

    late StreamController<Fleet> out;
    QuerySnapshot<Map<String, dynamic>>? d;
    QuerySnapshot<Map<String, dynamic>>? h;
    final subs = <StreamSubscription<Object?>>[];

    void emit() {
      if (d == null || h == null) return;
      final byId = {for (final doc in h!.docs) doc.id: _health(doc)};
      out.add(
        Fleet([
          for (final doc in d!.docs) DeviceView(_device(doc), byId[doc.id]),
        ], fromCache: d!.metadata.isFromCache || h!.metadata.isFromCache),
      );
    }

    out = StreamController<Fleet>(
      onListen: () {
        subs.add(
          devices.listen((s) {
            d = s;
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
        for (final s in subs) {
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
          mustChangePassword: m['mustChangePassword'] == true,
        );
      });

  @override
  Stream<List<StatusChange>> statusChanges(String deviceId) => _db
      .collection('devices/$deviceId/flow_logs')
      .where('trigger', isEqualTo: 'status_change')
      .orderBy('ts', descending: true)
      .limit(AppConfig.recentStatusChanges)
      .snapshots()
      .map(
        (s) => [
          for (final d in s.docs)
            if (_time(d.data()['ts']) != null)
              StatusChange(
                _time(d.data()['ts'])!,
                d.data()['flowStatus'] as String? ?? '',
              ),
        ],
      );

  @override
  Future<void> rename(String deviceId, String nickname) =>
      _db.doc('devices/$deviceId').update({'nickname': nickname});

  @override
  Future<void> confirmPasswordChanged() async {
    await _functions.httpsCallable('confirmPasswordChanged').call<Object?>();
  }
}
