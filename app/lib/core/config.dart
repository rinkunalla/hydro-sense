import 'package:flutter/foundation.dart' show kDebugMode;

// Every app tunable lives here (CLAUDE.md working rule 5). Values come from
// CLAUDE.md sections 4 and 9 and docs/UI_UX_SPEC.md.

abstract final class AppConfig {
  // Shown on Account (keep in step with pubspec.yaml version).
  static const String appVersion = '1.0.0';

  // Backend
  static const String firebaseProjectId = 'hydro-sense-dc836';
  static const String functionsRegion = 'asia-east1';

  // Emulator Suite: on by default in debug builds, off in release. Override with
  // --dart-define=USE_EMULATOR=false to point a debug build at the real project.
  static const bool useEmulator = bool.fromEnvironment(
    'USE_EMULATOR',
    defaultValue: kDebugMode,
  );

  // Emulator Suite ports (match firebase.json)
  static const String emulatorHostWeb = 'localhost';
  static const String emulatorHostAndroid = '10.0.2.2';
  static const int authEmulatorPort = 9099;
  static const int firestoreEmulatorPort = 8080;
  static const int functionsEmulatorPort = 5001;

  // Data rules mirrored from the backend
  static const int nicknameMax = 24;
  static const int lowBatteryPercent = 20;
  static const double starterLowCutoff = 0.2; // STARTER_LOW_FLOW_CUTOFF
  static const double starterNormalCutoff = 2.0; // STARTER_NORMAL_FLOW_CUTOFF
  static const double userCutoffMin = 1.0; // USER_NORMAL_CUTOFF_MIN (D43)
  static const double userCutoffMax = 30; // USER_NORMAL_CUTOFF_MAX
  static const double userCutoffStep = 0.5;
  static const int minPasswordLength = 8;
  static final RegExp deviceIdPattern = RegExp(r'^[0-9A-F]{12}$');
  static final RegExp phMobilePattern = RegExp(
    r'^(09\d{9}|\+639\d{9}|639\d{9})$',
  );

  // Lists and screens
  static const int recentStatusChanges = 10;
  static const int adminDevicesRefreshS = 60; // ADMIN_DEVICES_REFRESH_S
  static const int skeletonCards = 3;
  static const int toastS = 4; // TOAST_S
  static const int liveLateAfterS = 90; // LIVE_LATE_AFTER_S (D35)
  static const int flowChartHours = 24; // FLOW_CHART_HOURS
  static const int flowLogChartLimit =
      400; // ~288 samples + status changes per day
  static const int resetCodeLength = 6;
  static const int resetCodeTtlS = 300; // RESET_CODE_TTL_S
  static const int resetResendS = 60; // RESET_RESEND_S

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
  static const String tileUserAgent =
      'HydroSense/$appVersion (com.hydrosense.hydro_sense)';

  // Satellite (Google Map Tiles API): a public key passed at build time, never
  // committed. Empty = Satellite toggle hidden (CLAUDE.md section 9).
  static const String googleMapTilesKey = String.fromEnvironment(
    'GOOGLE_MAP_TILES_KEY',
  );

  // Map
  static const double mapFitPadding = 56;
  static const double mapDefaultZoom = 15;
  // Out to the whole country (no repeated world copies), in to street level.
  static const double mapMinZoom = 4;
  static const double mapMaxZoom = 20;
  // A few missing tiles (rural imagery, a slow connection) are normal; only
  // this many failures since the last view change show "Map can't load".
  static const int mapTileErrorsForBanner = 8;
  static const double placeZoom = 16;
  static const int myLocationTimeoutS = 15;
  static const int placeQueryMin = 3; // PLACES_INPUT_MIN
  static const int placeQueryMax = 100; // PLACES_INPUT_MAX
  static const int placeTypingPauseMs = 350; // wait this long after a key
  static const int pipelineMaxDevicesPerBranch =
      50; // PIPELINE_MAX_DEVICES_PER_BRANCH
}
