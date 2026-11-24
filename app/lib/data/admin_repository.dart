import 'package:cloud_functions/cloud_functions.dart';

import '../core/config.dart';
import 'models.dart' show SensorType;

// The admin website's account and device actions, each one a callable (v3,
// D63, D64). The admin reads devices, live data, History and the pipeline
// directly through the shared ClientRepository; only changes go through here.

DateTime? _ms(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

/// One staff member from adminListStaff (D64).
class StaffMember {
  const StaffMember({
    required this.uid,
    required this.name,
    required this.username,
    this.email,
    this.phone,
    this.disabled = false,
    this.createdAt,
    this.lastSignIn,
  });

  final String uid;
  final String name;
  final String username;
  final String? email;

  /// 639XXXXXXXXX, or null when the admin entered none.
  final String? phone;
  final bool disabled;
  final DateTime? createdAt;
  final DateTime? lastSignIn;

  factory StaffMember.fromMap(Map<Object?, Object?> m) => StaffMember(
    uid: m['uid'] as String,
    name: (m['name'] as String?) ?? '',
    username: (m['username'] as String?) ?? '',
    email: m['email'] as String?,
    phone: m['phone'] as String?,
    disabled: m['status'] == 'disabled',
    createdAt: _ms(m['createdAtMs']),
    lastSignIn: _ms(m['lastSignInMs']),
  );
}

/// One admin from listAdmins.
class AdminInfo {
  const AdminInfo({
    required this.uid,
    required this.email,
    this.name,
    this.phone,
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

  /// The admin's own number for SMS alerts (D65), or null.
  final String? phone;
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
    phone: m['phone'] as String?,
    invited: m['status'] == 'invited',
    you: m['you'] == true,
    inviteSentAt: _ms(m['inviteSentAtMs']),
    inviteExpired: m['inviteExpired'] == true,
    lastSignIn: _ms(m['lastSignInMs']),
    activatedAt: _ms(m['activatedAtMs']),
  );
}

/// Every admin change, each one a callable. Errors are
/// FirebaseFunctionsException with a details.code (USERNAME_IN_USE,
/// PHONE_IN_USE, CONFIRM_MISMATCH, LAST_ADMIN, DEVICE_EXISTS, ...).
abstract class AdminRepository {
  Future<List<StaffMember>> staff();
  Future<String> createStaff({
    required String name,
    required String username,
    required String password,
    String? mobile,
    String? email,
  });

  /// Only the given fields change; an empty mobile or email removes it.
  Future<void> updateStaff(
    String uid, {
    String? name,
    String? username,
    String? mobile,
    String? email,
    bool? disabled,
  });
  Future<void> resetStaffPassword(String uid, String password);
  Future<void> deleteStaff(String uid, {required String confirmName});

  /// Lists the ID and creates its records (Not set up yet).
  Future<void> addDevice(String deviceId, {String? name, SensorType? sensor});
  Future<void> removeDevice(String deviceId, {required String confirmName});

  Future<({List<AdminInfo> admins, bool belowRecommended})> admins();
  Future<void> inviteAdmin(String email);
  Future<void> resendAdminInvite(String uid);
  Future<void> cancelAdminInvite(String uid);
  Future<void> removeAdmin(String uid);
  Future<void> updateMyAdminName(String name);

  /// The admin's own mobile for SMS alerts; empty removes it.
  Future<void> updateMyAdminMobile(String mobile);

  /// After every admin sign-in: marks an invited admin active, copies a
  /// verified new email, and lets the account read the live channel.
  Future<void> syncMyAdmin();
  Future<void> signOutEverywhere();

  /// Unauthenticated: emails a fresh setup link to an invited admin.
  Future<void> requestAdminSetup(String email);

  /// Unauthenticated: sets the password with the emailed one-time token.
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
  Future<List<StaffMember>> staff() async => [
    for (final m in _rows(await _call('adminListStaff'), 'staff'))
      StaffMember.fromMap(m),
  ];

  @override
  Future<String> createStaff({
    required String name,
    required String username,
    required String password,
    String? mobile,
    String? email,
  }) async {
    final r = await _call('createStaff', {
      'name': name,
      'username': username,
      'password': password,
      'mobile': ?mobile,
      'email': ?email,
    });
    return (r is Map ? r['uid'] as String? : null) ?? '';
  }

  @override
  Future<void> updateStaff(
    String uid, {
    String? name,
    String? username,
    String? mobile,
    String? email,
    bool? disabled,
  }) => _call('updateStaff', {
    'uid': uid,
    'name': ?name,
    'username': ?username,
    'mobile': ?mobile,
    'email': ?email,
    'disabled': ?disabled,
  });

  @override
  Future<void> resetStaffPassword(String uid, String password) =>
      _call('resetStaffPassword', {'uid': uid, 'password': password});

  @override
  Future<void> deleteStaff(String uid, {required String confirmName}) =>
      _call('deleteStaff', {'uid': uid, 'confirmName': confirmName});

  @override
  Future<void> addDevice(String deviceId, {String? name, SensorType? sensor}) =>
      _call('addAllowedDevice', {
        'deviceId': deviceId,
        'name': ?name,
        'sensorType': ?sensor?.wire,
      });

  @override
  Future<void> removeDevice(String deviceId, {required String confirmName}) =>
      _call('removeDevice', {'deviceId': deviceId, 'confirmName': confirmName});

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
  Future<void> updateMyAdminMobile(String mobile) =>
      _call('updateMyAdminMobile', {'mobile': mobile});

  @override
  Future<void> syncMyAdmin() => _call('syncMyAdmin');

  @override
  Future<void> signOutEverywhere() => _call('signOutEverywhere');

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
