import 'package:cloud_functions/cloud_functions.dart';

import '../core/config.dart';

// Admin privacy (CLAUDE.md D24): the admin site reads nothing from Firestore
// directly; every admin call goes through a callable that returns only the
// allowed fields. admin_privacy_test enforces this.

DateTime? _ms(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

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

  /// The label, else the ID: how the admin site names a device.
  String get display => label ?? id;

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

/// One row of adminListUsers (D24: profile and status only).
class AdminUser {
  const AdminUser({
    required this.uid,
    required this.name,
    required this.email,
    required this.phone,
    this.deviceCount = 0,
    this.passwordSet = false,
    this.suspended = false,
    this.purgeAfter,
    this.deletionRequestedAt,
    this.createdAt,
  });

  final String uid;
  final String name;
  final String email;

  /// 639XXXXXXXXX
  final String phone;
  final int deviceCount;
  final bool passwordSet;
  final bool suspended;
  final DateTime? purgeAfter;
  final DateTime? deletionRequestedAt;
  final DateTime? createdAt;

  factory AdminUser.fromMap(Map<Object?, Object?> m) => AdminUser(
    uid: m['uid'] as String,
    name: (m['name'] as String?) ?? '',
    email: (m['email'] as String?) ?? '',
    phone: (m['phone'] as String?) ?? '',
    deviceCount: (m['deviceCount'] as num?)?.toInt() ?? 0,
    passwordSet: m['passwordSet'] == true,
    suspended: m['status'] == 'suspended',
    purgeAfter: _ms(m['purgeAfterMs']),
    deletionRequestedAt: _ms(m['deletionRequestedAtMs']),
    createdAt: _ms(m['createdAtMs']),
  );
}

/// One admin from listAdmins.
class AdminInfo {
  const AdminInfo({
    required this.uid,
    required this.email,
    this.name,
    this.invited = false,
    this.you = false,
    this.inviteSentAt,
    this.inviteExpired = false,
    this.lastSignIn,
    this.activatedAt,
  });

  final String uid;
  final String? name;
  final String email;
  final bool invited;
  final bool you;
  final DateTime? inviteSentAt;
  final bool inviteExpired;
  final DateTime? lastSignIn;
  final DateTime? activatedAt;

  String get display => (name == null || name!.isEmpty) ? email : name!;

  factory AdminInfo.fromMap(Map<Object?, Object?> m) => AdminInfo(
    uid: m['uid'] as String,
    name: m['name'] as String?,
    email: (m['email'] as String?) ?? '',
    invited: m['status'] == 'invited',
    you: m['you'] == true,
    inviteSentAt: _ms(m['inviteSentAtMs']),
    inviteExpired: m['inviteExpired'] == true,
    lastSignIn: _ms(m['lastSignInMs']),
    activatedAt: _ms(m['activatedAtMs']),
  );
}

/// One entry of the admin activity log (D42).
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    this.at,
    this.adminEmail,
    this.targetId,
    this.targetName,
  });

  final String id;
  final DateTime? at;
  final String? adminEmail;
  final String action;
  final String? targetId;
  final String? targetName;

  factory AuditEntry.fromMap(Map<Object?, Object?> m) => AuditEntry(
    id: m['id'] as String,
    at: _ms(m['atMs']),
    adminEmail: m['adminEmail'] as String?,
    action: (m['action'] as String?) ?? '',
    targetId: m['targetId'] as String?,
    targetName: m['targetName'] as String?,
  );
}

/// Every admin action, each one a callable (CLAUDE.md section 6). Errors are
/// FirebaseFunctionsException with a details.code (EMAIL_IN_USE, PHONE_IN_USE,
/// CONFIRM_MISMATCH, LAST_ADMIN, ...).
abstract class AdminRepository {
  Future<List<AdminDevice>> devices();
  Future<void> addAllowedDevice(String deviceId, {String? label});
  Future<void> updateDeviceLabel(String deviceId, String? label);

  /// uid null unassigns. Moving a device deletes its history (D20).
  Future<void> assignDevice(String deviceId, String? uid);
  Future<void> removeDevice(String deviceId, {required String confirmLabel});
  Future<void> restoreDevice(String deviceId);

  Future<List<AdminUser>> users();

  /// Returns the new user's uid.
  Future<String> createUser({
    required String name,
    required String email,
    required String mobile,
  });
  Future<void> updateUser(
    String uid, {
    String? name,
    String? email,
    String? mobile,
  });
  Future<void> deleteUser(String uid, {required String confirmName});
  Future<void> restoreUser(String uid);

  Future<({List<AdminInfo> admins, bool belowRecommended})> admins();
  Future<void> inviteAdmin(String email);
  Future<void> resendAdminInvite(String uid);
  Future<void> cancelAdminInvite(String uid);
  Future<void> removeAdmin(String uid);
  Future<void> updateMyAdminName(String name);

  /// After every admin sign-in: marks an invited admin active and copies a
  /// verified new email into the record (D40).
  Future<void> syncMyAdmin();
  Future<void> signOutEverywhere();
  Future<List<AuditEntry>> audit();

  /// Unauthenticated (D23): always "ok", whether or not the email was invited.
  Future<void> requestAdminSetup(String email);

  /// Returns the admin's email, to sign in with right after.
  Future<String> completeAdminSetup(String token, String password);
}

class FunctionsAdminRepository implements AdminRepository {
  FunctionsAdminRepository(this._functions);

  final FirebaseFunctions _functions;

  Future<Object?> _call(String name, [Map<String, Object?>? data]) async =>
      (await _functions.httpsCallable(name).call<Object?>(data)).data;

  List<Map<Object?, Object?>> _rows(Object? r, String key) => [
    if (r is Map && r[key] is List)
      for (final e in r[key] as List)
        if (e is Map) e.cast<Object?, Object?>(),
  ];

  @override
  Future<List<AdminDevice>> devices() async => [
    for (final m in _rows(await _call('adminListDevices'), 'rows'))
      AdminDevice.fromMap(m),
  ];

  @override
  Future<void> addAllowedDevice(String deviceId, {String? label}) =>
      _call('addAllowedDevice', {
        'deviceId': deviceId,
        if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
      });

  @override
  Future<void> updateDeviceLabel(String deviceId, String? label) =>
      _call('updateDeviceLabel', {
        'deviceId': deviceId,
        'label': (label == null || label.trim().isEmpty) ? null : label.trim(),
      });

  @override
  Future<void> assignDevice(String deviceId, String? uid) =>
      _call('assignDevice', {'deviceId': deviceId, 'uid': uid});

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
  Future<List<AdminUser>> users() async => [
    for (final m in _rows(await _call('adminListUsers'), 'users'))
      AdminUser.fromMap(m),
  ];

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

  @override
  Future<void> updateUser(
    String uid, {
    String? name,
    String? email,
    String? mobile,
  }) => _call('updateUser', {
    'uid': uid,
    'name': ?name,
    'email': ?email,
    'mobile': ?mobile,
  });

  @override
  Future<void> deleteUser(String uid, {required String confirmName}) =>
      _call('deleteUser', {'uid': uid, 'confirmName': confirmName});

  @override
  Future<void> restoreUser(String uid) => _call('restoreUser', {'uid': uid});

  @override
  Future<({List<AdminInfo> admins, bool belowRecommended})> admins() async {
    final r = await _call('listAdmins');
    return (
      admins: [for (final m in _rows(r, 'admins')) AdminInfo.fromMap(m)],
      belowRecommended: r is Map && r['belowRecommended'] == true,
    );
  }

  @override
  Future<void> inviteAdmin(String email) =>
      _call('inviteAdmin', {'email': email});

  @override
  Future<void> resendAdminInvite(String uid) =>
      _call('resendAdminInvite', {'uid': uid});

  @override
  Future<void> cancelAdminInvite(String uid) =>
      _call('cancelAdminInvite', {'uid': uid});

  @override
  Future<void> removeAdmin(String uid) => _call('removeAdmin', {'uid': uid});

  @override
  Future<void> updateMyAdminName(String name) =>
      _call('updateMyAdminName', {'name': name});

  @override
  Future<void> syncMyAdmin() => _call('syncMyAdmin');

  @override
  Future<void> signOutEverywhere() => _call('signOutEverywhere');

  @override
  Future<List<AuditEntry>> audit() async => [
    for (final m in _rows(await _call('listAdminAudit'), 'entries'))
      AuditEntry.fromMap(m),
  ];

  @override
  Future<void> requestAdminSetup(String email) =>
      _call('requestAdminSetup', {'email': email});

  @override
  Future<String> completeAdminSetup(String token, String password) async {
    final r = await _call('completeAdminSetup', {
      'token': token,
      'password': password,
    });
    return (r is Map ? r['email'] as String? : null) ?? '';
  }
}

/// Admin input: lowercase and ":" / "-" separators accepted, like the backend.
String? normalizeDeviceId(String input) {
  final id = input.replaceAll(RegExp(r'[\s:-]'), '').toUpperCase();
  return AppConfig.deviceIdPattern.hasMatch(id) ? id : null;
}
