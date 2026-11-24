import '../../core/config.dart';

/// The hidden Firebase Auth address behind a staff username (D64). Mirrors
/// `parseUsername` + `staffLoginEmail` in functions/src/lib/userInput.ts: the
/// server stores usernames trimmed and lowercase, so "Juan.DC " finds juan.dc.
/// Anything that is not a valid username still becomes an address; Firebase
/// then answers "wrong credentials", the same reply as a wrong password.
String staffSignInAddress(String username) =>
    '${username.trim().toLowerCase()}@${AppConfig.staffLoginDomain}';
