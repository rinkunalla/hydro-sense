import 'package:cloud_functions/cloud_functions.dart';

import '../core/config.dart';

// Admin privacy (CLAUDE.md D24): the admin site reads nothing from Firestore
// directly; every admin call goes through a callable that returns only the
// allowed fields. admin_privacy_test enforces this.

/// One row of adminListDevices.
class AdminDevice {
  const AdminDevice({
    required this.id,
    this.label,
    this.ownerUid,
    this.ownerName,
    this.registered = false,
    this.online = false,
    this.lastSeen,
    this.removedAt,
    this.purgeAfter,
  });

  final String id;
  final String? label;
  final String? ownerUid;
  final String? ownerName;
  final bool registered;
  final bool online;
  final DateTime? lastSeen;
  final DateTime? removedAt;
  final DateTime? purgeAfter;

  bool get removed => removedAt != null;

  /// What the typed confirmation must match (D42).
  String get confirmText => label ?? id;

  static DateTime? _ms(Object? v) =>
      v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

  factory AdminDevice.fromMap(Map<Object?, Object?> m) => AdminDevice(
    id: m['id'] as String,
    label: m['label'] as String?,
    ownerUid: m['ownerUid'] as String?,
    ownerName: m['ownerName'] as String?,
    registered: m['registered'] == true,
    online: m['online'] == true,
    lastSeen: _ms(m['lastSeenMs']),
    removedAt: _ms(m['removedAtMs']),
    purgeAfter: _ms(m['purgeAfterMs']),
  );
}

abstract class AdminRepository {
  Future<List<AdminDevice>> devices();
  Future<void> addAllowedDevice(String deviceId, {String? label});
  Future<void> removeDevice(String deviceId, {required String confirmLabel});
  Future<void> restoreDevice(String deviceId);

  /// Returns the new user's uid. Throws FirebaseFunctionsException with
  /// EMAIL_IN_USE, PHONE_IN_USE, NAME_INVALID, EMAIL_INVALID or PHONE_INVALID.
  Future<String> createUser({
    required String name,
    required String email,
    required String mobile,
  });
}

class FunctionsAdminRepository implements AdminRepository {
  FunctionsAdminRepository(this._functions);

  final FirebaseFunctions _functions;

  Future<Object?> _call(String name, [Map<String, Object?>? data]) async =>
      (await _functions.httpsCallable(name).call<Object?>(data)).data;

  @override
  Future<List<AdminDevice>> devices() async {
    final r = await _call('adminListDevices');
    final list = r is Map ? r['rows'] : null;
    return [
      if (list is List)
        for (final e in list)
          if (e is Map) AdminDevice.fromMap(e),
    ];
  }

  @override
  Future<void> addAllowedDevice(String deviceId, {String? label}) =>
      _call('addAllowedDevice', {
        'deviceId': deviceId,
        if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
      });

  @override
  Future<void> removeDevice(String deviceId, {required String confirmLabel}) =>
      _call('removeDevice', {
        'deviceId': deviceId,
        'confirmLabel': confirmLabel,
      });

  @override
  Future<void> restoreDevice(String deviceId) =>
      _call('restoreDevice', {'deviceId': deviceId});

  @override
  Future<String> createUser({
    required String name,
    required String email,
    required String mobile,
  }) async {
    final r = await _call('createUser', {
      'name': name,
      'email': email,
      'mobile': mobile,
    });
    return (r is Map ? r['uid'] as String? : null) ?? '';
  }
}

/// Admin input: lowercase and ":" / "-" separators accepted, like the backend.
String? normalizeDeviceId(String input) {
  final id = input.replaceAll(RegExp(r'[\s:-]'), '').toUpperCase();
  return AppConfig.deviceIdPattern.hasMatch(id) ? id : null;
}
