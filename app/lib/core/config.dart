import 'package:flutter/foundation.dart' show kDebugMode;

// Every app tunable lives here.

abstract final class AppConfig {
  // Shown on Account (keep in step with pubspec.yaml version).
  static const String appVersion = '1.0.0';

  // Backend
  static const String firebaseProjectId = 'hydro-sense-dc836';
  static const String functionsRegion = 'asia-east1';
  // The live channel: Realtime Database in asia-southeast1.
  static const String databaseUrl =
      'https://hydro-sense-dc836-default-rtdb.asia-southeast1.firebasedatabase.app';

  // Emulator Suite: on by default in debug builds, off in release. Override with
  // --dart-define=USE_EMULATOR=false to point a debug build at the real project.
  static const bool useEmulator = bool.fromEnvironment(
    'USE_EMULATOR',
    defaultValue: kDebugMode,
  );

  // Emulator Suite ports (match firebase.json)
  static const String emulatorHostWeb = 'localhost';
  // 10.0.2.2 reaches the PC from an Android emulator. A real phone on USB uses
  // 127.0.0.1 with `adb reverse` on the four ports
  // (--dart-define=EMULATOR_HOST=127.0.0.1).
  static const String emulatorHostAndroid = String.fromEnvironment(
    'EMULATOR_HOST',
    defaultValue: '10.0.2.2',
  );
  static const int authEmulatorPort = 9099;
  static const int firestoreEmulatorPort = 8080;
  static const int functionsEmulatorPort = 5001;
  static const int databaseEmulatorPort = 9000;
  // A refused live read (node not created yet, owner being mirrored) is
  // retried after this many seconds.
  static const int liveRetryS = 5;

  // Data rules mirrored from the backend
  static const int nicknameMax = 24;
  static const int userNameMax = 60; // USER_NAME_MAX
  // Staff usernames (D64): USERNAME_MIN / USERNAME_MAX.
  static const int usernameMin = 3;
  static const int usernameMax = 20;
  static const int lowBatteryPercent = 20;
  // Starter cutoffs and the admin's limit range are per sensor: SensorType
  // in data/models.dart (D69).
  static const double userCutoffStep = 0.5;
  static const int minPasswordLength = 8;
  static final RegExp deviceIdPattern = RegExp(r'^[0-9A-F]{12}$');
  static final RegExp phMobilePattern = RegExp(
    r'^(09\d{9}|\+639\d{9}|639\d{9})$',
  );

  // History
  static const int problemNoteMax = 100; // PROBLEM_NOTE_MAX
  static const int problemKeepDays = 365; // PROBLEM_TTL_DAYS
  static const List<int> historyClearMonths = [3, 6, 12];
  // Year dropdowns start here: nothing was recorded before v2 went live.
  static const int firstRecordYear = 2026;
  // "Today so far" on the device cards: today's 15-minute readings, read again
  // this often while the app is open (the server adds one every 15 min).
  static const int todayRefreshMin = 15;
  static const int readingSlotMin = 15; // READING_SLOT_MIN
  // Problems read per History month or status strip (a busy month stays well under).
  static const int problemQueryLimit = 500;
  static const int stripProblemLimit = 50;

  // Lists and screens
  static const int devicesFilterFrom =
      1; // filter pills always (owners asked for them)
  static const int devicesSearchFrom = 8; // nickname search from this many
  // Google lets a Map Tiles tile be kept 24 h (Cache-Control max-age=86400).
  static const int tileCacheHours = 24;
  static const int tileCacheMaxMb = 100;
  static const int adminDevicesRefreshS = 60; // ADMIN_DEVICES_REFRESH_S
  static const int skeletonCards = 3;
  static const int toastS = 4; // TOAST_S
  static const int foregroundAlertS =
      10; // an alert shown while the app is open
  // Offline as the server decides it (OFFLINE_MISSED_HEARTBEATS 2,
  // OFFLINE_AFTER_MIN_S 60, OFFLINE_AFTER_S 180 with no reported heartbeat),
  // checked by the app on the server clock so it shows at once.
  static const int offlineMissedHeartbeats = 2;
  static const int offlineAfterMinS = 40; // OFFLINE_AFTER_MIN_S
  static const int offlineAfterDefaultS = 180;
  static const int offlineCheckS = 5; // how often the app re-checks
  static const int flowChartHours = 24; // FLOW_CHART_HOURS: the status strip
  static const int resetCodeLength = 6;
  static const int resetCodeTtlS = 300; // RESET_CODE_TTL_S
  static const int resetResendS = 60; // RESET_RESEND_S

  // Layout and accessibility
  static const double adminMaxContentWidth = 1200;
  // History on the website: the phone layout's calendar, kept this wide.
  static const double adminReadableWidth = 760;
  static const double adminRailBreakpoint = 800;
  static const double maxTextScale = 1.5;
  static const double minTapTarget = 48;
  static const double minTextContrast = 4.5;
  static const double minIconContrast = 3.0;

  // Device GPS: the NEO-6M is taken off the devices for now. While
  // false, a device's location is only what the owner sets (a placed pin or
  // the phone's location), old GPS fixes are ignored and "Use device GPS" is
  // hidden. Set to true when the GPS module is fitted again.
  static const bool deviceGpsEnabled = false;

  // Map (OpenStreetMap tile policy)
  static const String osmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String osmUserAgentPackage = 'com.hydrosense.hydro_sense';
  static const String tileUserAgent =
      'HydroSense/$appVersion (com.hydrosense.hydro_sense)';

  // Satellite (Google Map Tiles API): a public key passed at build time, never
  // committed. Empty = Satellite toggle hidden.
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
