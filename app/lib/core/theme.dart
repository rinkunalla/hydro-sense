import 'package:flutter/material.dart';

/// Arctic Hologram tokens. Explicit values
/// so they do not drift; test/contrast_test.dart checks every pair.
abstract final class AppColors {
  // Palette
  static const frost = Color(0xFFF2F6FA);
  static const glacier = Color(0xFFDCE5EF);
  static const mist = Color(0xFFEEF1F7); // last background stop
  static const deepCyan = Color(0xFF00789A);
  static const royal = Color(0xFF2563EB); // middle of the button gradient
  static const indigo = Color(0xFF4F46E5);
  static const ink = Color(0xFF0A1B2E);
  static const steel = Color(0xFF3A4A5E);
  static const link = Color(0xFF4338CA);
  static const tint = Color(0xFFE0F2F7);
  static const water = Color(0xFF22C3DD);
  static const solidGlass = Color(0xFFF7F9FC); // reduce-transparency fallback
  static const rim = Color(0xCCFFFFFF);
  static const errorText = Color(0xFFA12A1F);
  static const danger = Color(0xFFD03A2B);
  static const errorFill = Color(0xFFFDECEA);

  /// Background stops, top to bottom.
  static const backgroundStops = [frost, glacier, mist];

  /// Primary button gradient stops.
  static const buttonStops = [deepCyan, royal, indigo];

  // Older names still used by the admin website.
  static const background = glacier;
  static const surface = solidGlass;
  static const surfaceAlt = tint;
  static const primary = deepCyan;
  static const onPrimary = Color(0xFFFFFFFF);
  static const secondary = link;
  static const accent = water;
  static const text = ink;
  static const textMuted = steel;
  static const outline = Color(0xFFC5D2E0);
}

/// What a card, chip or pin shows for a device. Never colour alone: colour + icon + word.
enum StatusKind {
  normal,
  lowFlow,
  noFlow,
  offline,
  lowBattery,
  waiting,
  notSetUp,
}

class StatusStyle {
  const StatusStyle(this.icon, this.strong, this.word);

  final IconData icon;

  /// The status colour: icons, dots, bars, pipe tint and pin fill only (never text).
  final Color strong;
  final String word;

  /// Chip fill: near-white so the status icon reaches 3:1 (white at 92 %).
  Color get soft => const Color(0xEBFFFFFF);

  /// Words beside a status icon are always ink.
  Color get chipText => AppColors.ink;

  static const Map<StatusKind, StatusStyle> all = {
    StatusKind.normal: StatusStyle(
      Icons.check_circle_rounded,
      Color(0xFF17845A),
      'Normal',
    ),
    StatusKind.lowFlow: StatusStyle(
      Icons.trending_down_rounded,
      Color(0xFFB87A00),
      'Low flow',
    ),
    StatusKind.noFlow: StatusStyle(
      Icons.block_rounded,
      Color(0xFFD03A2B),
      'No flow',
    ),
    StatusKind.offline: StatusStyle(
      Icons.cloud_off_rounded,
      Color(0xFF5B6B80),
      'Offline',
    ),
    StatusKind.lowBattery: StatusStyle(
      Icons.battery_alert_rounded,
      Color(0xFFB87A00),
      'Low battery',
    ),
    StatusKind.waiting: StatusStyle(
      Icons.hourglass_empty_rounded,
      Color(0xFF5B6B80),
      'Waiting for first reading',
    ),
    StatusKind.notSetUp: StatusStyle(
      Icons.wifi_find_rounded,
      AppColors.deepCyan,
      'Not set up yet',
    ),
  };

  static StatusStyle of(StatusKind k) => all[k]!;
}

abstract final class AppSpace {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const cardRadius = 28.0;
  static const tileRadius = 16.0;
  static const pill = 999.0;
}

/// Variable fonts take their weight from the wght axis.
TextStyle _font(String family, double size, FontWeight weight) => TextStyle(
  fontFamily: family,
  fontSize: size,
  fontWeight: weight,
  fontVariations: [FontVariation.weight(weight.value.toDouble())],
  color: AppColors.ink,
);

abstract final class AppText {
  /// The big L/min reading (Plus Jakarta Sans ExtraBold).
  static TextStyle reading(double size) =>
      _font('PlusJakartaSans', size, FontWeight.w800);

  /// Titles and names (Plus Jakarta Sans Bold).
  static TextStyle title(double size) =>
      _font('PlusJakartaSans', size, FontWeight.w700);

  static final body = _font('Inter', 16, FontWeight.w400);
  static final note = _font(
    'Inter',
    13,
    FontWeight.w400,
  ).copyWith(color: AppColors.steel);
  static final strong = _font('Inter', 16, FontWeight.w600);

  /// Section labels: Inter SemiBold 12, upper case (callers pass upper case), spaced.
  static final label = _font(
    'Inter',
    12,
    FontWeight.w600,
  ).copyWith(color: AppColors.steel, letterSpacing: 1.2);
}

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.deepCyan).copyWith(
    primary: AppColors.deepCyan,
    onPrimary: AppColors.onPrimary,
    secondary: AppColors.link,
    surface: AppColors.solidGlass,
    onSurface: AppColors.ink,
    onSurfaceVariant: AppColors.steel,
    surfaceContainerHighest: AppColors.tint,
    outline: AppColors.outline,
    error: AppColors.errorText,
  );
  final text = TextTheme(
    displaySmall: AppText.reading(44),
    headlineSmall: AppText.title(26),
    titleLarge: AppText.title(20),
    titleMedium: AppText.strong,
    bodyLarge: AppText.body,
    bodyMedium: AppText.body.copyWith(fontSize: 14),
    bodySmall: AppText.note,
    labelLarge: AppText.strong.copyWith(fontSize: 15),
    labelSmall: AppText.label,
  );
  final pillShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppSpace.pill),
  );
  OutlineInputBorder edge(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppSpace.pill),
    borderSide: BorderSide(color: c, width: w),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: AppColors.glacier,
    textTheme: text,
    cardTheme: CardThemeData(
      color: AppColors.solidGlass,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpace.cardRadius),
        side: const BorderSide(color: AppColors.rim),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: pillShape,
        backgroundColor: AppColors.deepCyan,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: pillShape,
        foregroundColor: AppColors.link,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: AppColors.link,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xF2FFFFFF),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      border: edge(AppColors.outline),
      enabledBorder: edge(AppColors.outline),
      focusedBorder: edge(AppColors.deepCyan, 2),
      errorBorder: edge(AppColors.danger),
      focusedErrorBorder: edge(AppColors.danger, 2),
      errorStyle: AppText.note.copyWith(color: AppColors.errorText),
      errorMaxLines: 3,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
      contentTextStyle: AppText.body.copyWith(color: Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpace.tileRadius),
      ),
    ),
    materialTapTargetSize: MaterialTapTargetSize.padded,
    focusColor: AppColors.deepCyan.withValues(alpha: 0.24),
  );
}
