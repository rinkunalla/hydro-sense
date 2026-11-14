import '../../core/config.dart';
import '../../core/errors.dart';

/// New password typed twice: minimum length, then both the same. Null when valid.
String? validateNewPassword(String a, String b) {
  if (a.length < AppConfig.minPasswordLength) {
    return 'Use at least ${AppConfig.minPasswordLength} characters.';
  }
  if (a != b) return Messages.passwordsDontMatch;
  return null;
}
