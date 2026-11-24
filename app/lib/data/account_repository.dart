import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The admin's own sign-in changes on the website (D40). Staff change nothing
/// of their account: the admin edits it (D64). Calls throw
/// FirebaseAuthException; screens map the codes to the spec wording. Widget
/// tests replace this with a fake.
abstract class AccountRepository {
  /// Re-enters the current password (recent sign-in for a change).
  Future<void> reauthenticate(String currentPassword);

  /// Firebase sends a link to the new address; the email changes once it is opened.
  Future<void> changeEmail(String currentPassword, String newEmail);

  /// Firebase ends the admin's other sessions on a password change.
  Future<void> changePassword(String currentPassword, String newPassword);
}

class FirebaseAccountRepository implements AccountRepository {
  FirebaseAccountRepository(this._auth);

  final FirebaseAuth _auth;

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
  Future<void> changeEmail(String currentPassword, String newEmail) async {
    await reauthenticate(currentPassword);
    await _auth.currentUser!.verifyBeforeUpdateEmail(newEmail);
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    await reauthenticate(currentPassword);
    await _auth.currentUser!.updatePassword(newPassword);
  }
}

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => FirebaseAccountRepository(FirebaseAuth.instance),
);
