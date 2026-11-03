import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// User-facing wording (docs/UI_UX_SPEC.md section 4, docs/ERROR_HANDLING.md section 4).
abstract final class Messages {
  static const wrongCredentials = 'Email or password is incorrect.';
  static const tooManyAttempts =
      'Too many tries. Wait a few minutes or reset your password.';
  static const noInternet =
      'No internet connection. Check your connection and try again.';
  static const resetSent =
      'If that email has an account, a reset link is on its way.';
  static const adminOnPhone = 'This account is for the admin website.';
  static const noAccess = 'This account does not have access to Hydro Sense.';
  static const signInAgain = 'Please sign in again.';
  static const generic = 'Something went wrong. Please try again.';
  static const permissionDenied = "You don't have permission to do that.";
  static const passwordsDontMatch = "Passwords don't match.";
  static const summaryFailed = "Couldn't update the summary. Try again later.";
  static const renameFailed = "Couldn't save the name. Check your connection.";
  static const nameEmpty = "Name can't be empty.";
  static const saveFailed = "Couldn't save. Check your connection.";
  static const devicesFailed = "Can't load your devices right now.";
  static const offlineBanner =
      'You are offline. Showing the last data this phone received. (may be outdated)';
  static const deviceRemoved = 'This device was removed.';
  static const mapFailed = "Map can't load. Device list still works.";
}

/// Maps a FirebaseAuthException code to the spec wording.
String authMessage(Object error) {
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-email':
      case 'user-disabled':
        return Messages.wrongCredentials;
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

/// A callable's app code (details.code) and retryAfterSeconds, if any.
({String? code, int? retryAfterSeconds}) callableDetails(Object error) {
  if (error is FirebaseFunctionsException) {
    final d = error.details;
    if (d is Map) {
      final retry = d['retryAfterSeconds'];
      return (
        code: d['code'] as String?,
        retryAfterSeconds: retry is num ? retry.toInt() : null,
      );
    }
    return (code: null, retryAfterSeconds: null);
  }
  return (code: null, retryAfterSeconds: null);
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
