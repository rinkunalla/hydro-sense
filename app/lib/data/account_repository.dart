import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';

/// Sign-in codes and account changes (CLAUDE.md D22, D31, D42). Every call that
/// can fail throws FirebaseFunctionsException or FirebaseAuthException; screens map
/// the codes to the spec wording. Widget tests replace this with a fake.
abstract class AccountRepository {
  /// Reset step 1. Returns the resend gap; throws COOLDOWN / DAILY_LIMIT / PHONE_INVALID.
  Future<int> requestResetCode(String mobile);

  /// Reset step 2. Returns the one-time reset token.
  Future<String> verifyResetCode(String mobile, String code);

  /// Reset step 3. Sets the password, then signs in with it.
  Future<void> setPasswordAndSignIn(String resetToken, String newPassword);

  /// Re-enters the current password (recent sign-in for a change, D31).
  Future<void> reauthenticate(String currentPassword);

  Future<void> updateMyName(String name);

  /// Mobile change step 1, after [reauthenticate]: returns the masked new number.
  Future<({int resendAfterSeconds, String sentTo})> requestPhoneChangeCode(
    String newMobile,
  );

  /// Mobile change step 2: returns the masked new number.
  Future<String> confirmPhoneChange(String code);

  /// Firebase sends a link to the new address; the email changes once it is opened.
  Future<void> changeEmail(String currentPassword, String newEmail);

  /// Copies a verified new email into the profile (after the link was opened).
  Future<void> syncMyEmail();

  /// Signs out the user's other phones (Firebase revokes on a password change).
  Future<void> changePassword(String currentPassword, String newPassword);

  Future<void> requestAccountDeletion();
}

class FirebaseAccountRepository implements AccountRepository {
  FirebaseAccountRepository(this._auth, this._functions);

  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;

  Future<Map<Object?, Object?>> _call(
    String name,
    Map<String, Object?> data,
  ) async {
    final r = await _functions.httpsCallable(name).call<Object?>(data);
    return r.data is Map ? r.data as Map<Object?, Object?> : const {};
  }

  @override
  Future<int> requestResetCode(String mobile) async {
    final r = await _call('requestResetCode', {'mobile': mobile});
    return (r['resendAfterSeconds'] as num?)?.toInt() ?? AppConfig.resetResendS;
  }

  @override
  Future<String> verifyResetCode(String mobile, String code) async {
    final r = await _call('verifyResetCode', {'mobile': mobile, 'code': code});
    return r['resetToken'] as String;
  }

  @override
  Future<void> setPasswordAndSignIn(
    String resetToken,
    String newPassword,
  ) async {
    final r = await _call('setPasswordWithResetToken', {
      'resetToken': resetToken,
      'newPassword': newPassword,
    });
    await _auth.signInWithEmailAndPassword(
      email: r['email'] as String,
      password: newPassword,
    );
  }

  @override
  Future<void> reauthenticate(String currentPassword) async {
    final user = _auth.currentUser!;
    await user.reauthenticateWithCredential(
      EmailAuthProvider.credential(
        email: user.email!,
        password: currentPassword,
      ),
    );
  }

  @override
  Future<void> updateMyName(String name) =>
      _call('updateMyName', {'name': name});

  @override
  Future<({int resendAfterSeconds, String sentTo})> requestPhoneChangeCode(
    String newMobile,
  ) async {
    final r = await _call('requestPhoneChangeCode', {'newMobile': newMobile});
    return (
      resendAfterSeconds:
          (r['resendAfterSeconds'] as num?)?.toInt() ?? AppConfig.resetResendS,
      sentTo: r['sentTo'] as String? ?? '',
    );
  }

  @override
  Future<String> confirmPhoneChange(String code) async {
    final r = await _call('confirmPhoneChange', {'code': code});
    return r['phone'] as String? ?? '';
  }

  @override
  Future<void> changeEmail(String currentPassword, String newEmail) async {
    await reauthenticate(currentPassword);
    await _auth.currentUser!.verifyBeforeUpdateEmail(newEmail);
  }

  @override
  Future<void> syncMyEmail() async {
    await _auth.currentUser?.reload();
    await _call('syncMyEmail', {});
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    await reauthenticate(currentPassword);
    await _auth.currentUser!.updatePassword(newPassword);
  }

  @override
  Future<void> requestAccountDeletion() => _call('requestAccountDeletion', {});
}

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => FirebaseAccountRepository(
    FirebaseAuth.instance,
    FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion),
  ),
);
