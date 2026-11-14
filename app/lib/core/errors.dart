import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// User-facing wording (docs/UI_UX_SPEC.md section 4, docs/ERROR_HANDLING.md section 4).
abstract final class Messages {
  static const wrongCredentials =
      'That email or password is not right. Try again.';
  static const suspended =
      'This account is suspended. Contact your Hydro Sense provider.';
  static const wrongPassword = 'That password is not right.';
  static const tooManyAttempts =
      'Too many tries. Wait a few minutes or reset your password.';
  static const noInternet =
      'No internet connection. Check your connection and try again.';
  static const resetSent =
      'If that email has an account, a reset link is on its way.';
  static const adminOnPhone = 'This account is for the admin website.';
  static const notAdmin = 'This account does not have admin access.';
  static const noAccess = 'This account does not have access to Hydro Sense.';
  static const signInAgain = 'Please sign in again.';
  static const generic = 'Something went wrong. Please try again.';
  static const permissionDenied = "You don't have permission to do that.";
  static const passwordsDontMatch = "Passwords don't match.";
  static const renameFailed = "Couldn't save the name. Check your internet.";
  static const nameEmpty = "Name can't be empty.";
  static const saveFailed = "Couldn't save. Check your internet.";
  static const devicesFailed = "Can't load your devices right now.";
  static const offlineBanner = 'No internet · Showing the last saved readings';
  static const deviceGone = 'This device is no longer on your account.';
  static const mapFailed = "Map can't load. Your devices list still works.";
  static const codeSent = 'If this number has an account, we sent a code.';
  static const codeExpired = 'This code has expired. Send a new one.';
  static const codeLocked = 'Too many wrong codes. Send a new one.';
  static const dailyLimit =
      'You have asked for too many codes today. Try again tomorrow.';
  static const phoneHint =
      'Enter a Philippine mobile number, for example 0917 123 4567.';
  static const phoneInUse = 'Another account already uses this number.';
  static const emailInUse = 'Another account already uses this email.';
  static const resetExpired = 'This reset has expired. Start again.';
}

/// Maps a FirebaseAuthException code to the spec wording.
String authMessage(Object error) {
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-email':
        return Messages.wrongCredentials;
      case 'user-disabled':
        return Messages.suspended;
      case 'email-already-in-use':
        return Messages.emailInUse;
      case 'too-many-requests':
        return Messages.tooManyAttempts;
      case 'network-request-failed':
        return Messages.noInternet;
      case 'weak-password':
        return 'Use at least 8 characters.';
      case 'requires-recent-login':
        return Messages.signInAgain;
    }
  }
  return Messages.generic;
}

/// A callable's app code (details.code), retryAfterSeconds and triesLeft, if any.
({String? code, int? retryAfterSeconds, int? triesLeft}) callableDetails(
  Object error,
) {
  int? n(Object? v) => v is num ? v.toInt() : null;
  if (error is FirebaseFunctionsException && error.details is Map) {
    final d = error.details as Map;
    return (
      code: d['code'] as String?,
      retryAfterSeconds: n(d['retryAfterSeconds']),
      triesLeft: n(d['triesLeft']),
    );
  }
  return (code: null, retryAfterSeconds: null, triesLeft: null);
}

/// Wording for a failed callable that has no screen-specific message.
String callableMessage(Object error) {
  if (error is FirebaseFunctionsException) {
    if (error.code == 'permission-denied') return Messages.permissionDenied;
    if (error.code == 'unauthenticated') return Messages.signInAgain;
    if (error.code == 'unavailable' || error.code == 'deadline-exceeded') {
      return Messages.noInternet;
    }
  }
  return Messages.generic;
}
