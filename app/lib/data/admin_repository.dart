import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../core/config.dart';
import 'models.dart' show Health;

// Admin privacy (CLAUDE.md section 4): this file is the admin site's only data
// access. It must never name the client's flow collections; a test enforces it.

class AllowedEntry {
  const AllowedEntry(this.id, this.addedAt);

  final String id;
  final DateTime? addedAt;
}

class RemovedEntry {
  const RemovedEntry(this.id, this.removedAt);

  final String id;
  final DateTime? removedAt;
}

class ErrorEntry {
  const ErrorEntry({
    required this.id,
    this.deviceId,
    required this.source,
    required this.code,
    required this.message,
    this.ts,
  });

  final String id;
  final String? deviceId;
  final String source;
  final String code;
  final String message;
  final DateTime? ts;
}

class BatteryPoint {
  const BatteryPoint(this.at, this.voltage, this.percent, {this.sleep = false});

  final DateTime at;
  final double voltage;
  final int? percent;
  final bool sleep;
}

class Diagnostics {
  const Diagnostics({this.text, this.lastUpdated});

  final String? text;
  final DateTime? lastUpdated;
}

class ClientInfo {
  const ClientInfo({required this.uid, this.name, this.email});

  final String uid;
  final String? name;
  final String? email;
}

class CreateClientResult {
  const CreateClientResult({
    this.temporaryPassword,
    this.emailSent,
    this.adopted = 0,
  });

  final String? temporaryPassword;
  final bool? emailSent;
  final int adopted;
}

abstract class AdminRepository {
  Stream<List<Health>> health();
  Stream<List<AllowedEntry>> allowed();
  Stream<List<RemovedEntry>> removed();
  Stream<List<ErrorEntry>> errors({String? deviceId, String? code, int limit});
  Stream<List<BatteryPoint>> batteryHistory(String deviceId, Duration window);
  Stream<Diagnostics?> diagnostics();
  Stream<ClientInfo?> client();

  Future<void> addAllowedDevice(String deviceId);
  Future<void> removeDevice(String deviceId);
  Future<void> allowDevice(String deviceId);
  Future<CreateClientResult> createClient({
    required String name,
    required String email,
    required String phone,
    required bool temporaryPassword,
  });
  Future<void> runHardwareReport();
}

DateTime? _time(Object? v) => v is Timestamp ? v.toDate() : null;

class FirestoreAdminRepository implements AdminRepository {
  FirestoreAdminRepository(this._db, this._functions);

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  @override
  Stream<List<Health>> health() => _db
      .collection('device_health')
      .snapshots()
      .map(
        (s) => [
          for (final d in s.docs)
            Health(
              id: d.id,
              online: d.data()['online'] == true,
              lastSeen: _time(d.data()['lastSeen']),
              batteryPercent: (d.data()['batteryPercent'] as num?)?.toInt(),
              batteryVoltage: (d.data()['batteryVoltage'] as num?)?.toDouble(),
              batteryFault: d.data()['batteryFault'] == true,
              chargingStatus: d.data()['chargingStatus'] as String?,
              lowVoltageSleep: d.data()['lowVoltageSleep'] == true,
              rssi: (d.data()['rssi'] as num?)?.toInt(),
              firmware: d.data()['firmware'] as String?,
            ),
        ],
      );

  @override
  Stream<List<AllowedEntry>> allowed() => _db
      .collection('allowed_devices')
      .snapshots()
      .map(
        (s) => [
          for (final d in s.docs)
            AllowedEntry(d.id, _time(d.data()['addedAt'])),
        ],
      );

  @override
  Stream<List<RemovedEntry>> removed() => _db
      .collection('removed_devices')
      .snapshots()
      .map(
        (s) => [
          for (final d in s.docs)
            RemovedEntry(d.id, _time(d.data()['removedAt'])),
        ],
      );

  @override
  Stream<List<ErrorEntry>> errors({
    String? deviceId,
    String? code,
    int limit = 100,
  }) {
    Query<Map<String, dynamic>> q = _db.collection('error_logs');
    if (deviceId != null) q = q.where('deviceId', isEqualTo: deviceId);
    if (code != null) q = q.where('code', isEqualTo: code);
    return q
        .orderBy('ts', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (s) => [
            for (final d in s.docs)
              ErrorEntry(
                id: d.id,
                deviceId: d.data()['deviceId'] as String?,
                source: (d.data()['source'] as String?) ?? '',
                code: (d.data()['code'] as String?) ?? '',
                message: (d.data()['message'] as String?) ?? '',
                ts: _time(d.data()['ts']),
              ),
          ],
        );
  }

  @override
  Stream<List<BatteryPoint>> batteryHistory(String deviceId, Duration window) =>
      _db
          .collection('device_health/$deviceId/battery_logs')
          .where(
            'ts',
            isGreaterThanOrEqualTo: Timestamp.fromDate(
              DateTime.now().subtract(window),
            ),
          )
          .orderBy('ts')
          .snapshots()
          .map(
            (s) => [
              for (final d in s.docs)
                if (_time(d.data()['ts']) != null &&
                    d.data()['batteryVoltage'] is num)
                  BatteryPoint(
                    _time(d.data()['ts'])!,
                    (d.data()['batteryVoltage'] as num).toDouble(),
                    (d.data()['batteryPercent'] as num?)?.toInt(),
                    sleep: d.data()['lowVoltageSleep'] == true,
                  ),
            ],
          );

  @override
  Stream<Diagnostics?> diagnostics() =>
      _db.doc('ai_insights/admin_diagnostics').snapshots().map((s) {
        final m = s.data();
        return m == null
            ? null
            : Diagnostics(
                text: m['text'] as String?,
                lastUpdated: _time(m['lastUpdated']),
              );
      });

  @override
  Stream<ClientInfo?> client() => _db.doc('config/system').snapshots().map((s) {
    final m = s.data();
    final uid = m?['clientUid'] as String?;
    if (uid == null) return null;
    return ClientInfo(
      uid: uid,
      name: m?['clientName'] as String?,
      email: m?['clientEmail'] as String?,
    );
  });

  Future<Object?> _call(String name, [Map<String, Object?>? data]) async =>
      (await _functions.httpsCallable(name).call<Object?>(data)).data;

  @override
  Future<void> addAllowedDevice(String deviceId) =>
      _call('addAllowedDevice', {'deviceId': deviceId});

  @override
  Future<void> removeDevice(String deviceId) =>
      _call('removeDevice', {'deviceId': deviceId});

  @override
  Future<void> allowDevice(String deviceId) =>
      _call('allowDevice', {'deviceId': deviceId});

  @override
  Future<CreateClientResult> createClient({
    required String name,
    required String email,
    required String phone,
    required bool temporaryPassword,
  }) async {
    final r = await _call('createClientAccount', {
      'name': name,
      'email': email,
      'phone': phone,
      'setupMethod': temporaryPassword ? 'temporary' : 'email',
    });
    final m = r is Map ? r : const {};
    return CreateClientResult(
      temporaryPassword: m['temporaryPassword'] as String?,
      emailSent: m['emailSent'] as bool?,
      adopted: (m['adopted'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> runHardwareReport() => _call('generateAdminHardwareReport');
}

/// Admin input: lowercase and ":" / "-" separators accepted, like the backend.
String? normalizeDeviceId(String input) {
  final id = input.replaceAll(RegExp(r'[\s:-]'), '').toUpperCase();
  return AppConfig.deviceIdPattern.hasMatch(id) ? id : null;
}
