import '../../core/config.dart';
import '../../core/errors.dart';

/// A password typed once, in plain view (a staff password the admin sets and
/// then tells them): the minimum length only. Null when valid.
String? validatePassword(String a) => a.length < AppConfig.minPasswordLength
    ? 'Use at least ${AppConfig.minPasswordLength} characters.'
    : null;

/// New password typed twice: minimum length, then both the same. Null when valid.
String? validateNewPassword(String a, String b) {
  if (a.length < AppConfig.minPasswordLength) {
    return 'Use at least ${AppConfig.minPasswordLength} characters.';
  }
  if (a != b) return Messages.passwordsDontMatch;
  return null;
}
