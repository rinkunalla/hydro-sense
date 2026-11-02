// Every app tunable lives here (CLAUDE.md working rule 5). Values come from
// CLAUDE.md sections 4 and 9 and docs/UI_UX_SPEC.md.

abstract final class AppConfig {
  // Backend
  static const String firebaseProjectId = 'hydro-sense-dc836';
  static const String functionsRegion = 'asia-east1';

  // Emulator Suite (debug builds only; ports match firebase.json)
  static const String emulatorHostWeb = 'localhost';
  static const String emulatorHostAndroid = '10.0.2.2';
  static const int authEmulatorPort = 9099;
  static const int firestoreEmulatorPort = 8080;
  static const int functionsEmulatorPort = 5001;

  // Data rules mirrored from the backend
  static const int nicknameMax = 24;
  static const int lowBatteryPercent = 20;
  static const int pauseMaxDays = 7;
  static const List<Duration> pauseOptions = [
    Duration(hours: 1),
    Duration(hours: 24),
  ];
  static const int minPasswordLength = 8;
  static final RegExp deviceIdPattern = RegExp(r'^[0-9A-F]{12}$');
  static final RegExp phMobilePattern = RegExp(
    r'^(09\d{9}|\+639\d{9}|639\d{9})$',
  );

  // Lists and screens
  static const int recentStatusChanges = 10;
  static const int skeletonCards = 3;
  static const int errorLogsPageSize = 100;
  static const int batteryHistoryDays = 7;

  // Layout and accessibility
  static const double adminMaxContentWidth = 1200;
  static const double adminRailBreakpoint = 800;
  static const double maxTextScale = 1.5;
  static const double minTapTarget = 48;
  static const double minTextContrast = 4.5;
  static const double minIconContrast = 3.0;

  // Map (OpenStreetMap tile policy)
  static const String osmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String osmUserAgentPackage = 'com.hydrosense.hydro_sense';
}
