import 'package:flutter/material.dart';

/// Design tokens (docs/UI_UX_SPEC.md section 2). Explicit values so they do not drift.
abstract final class AppColors {
  static const background = Color(0xFFDCE9E7);
  static const surface = Color(0xFFF1F6F5);
  static const surfaceAlt = Color(0xFFC9DCDA);
  static const primary = Color(0xFF25788A);
  static const onPrimary = Color(0xFFFFFFFF);
  static const secondary = Color(0xFF4F7CA8);
  static const accent = Color(0xFF4DB3BC);
  static const text = Color(0xFF1F3A44);
  static const textMuted = Color(0xFF4C6670);
  static const outline = Color(0xFF9DB8B6);
}

/// What a card, chip or pin shows for a device. Never color alone: color + icon + word.
enum StatusKind {
  normal,
  lowFlow,
  noFlow,
  offline,
  lowBattery,
  paused,
  waiting,
}

class StatusStyle {
  const StatusStyle(
    this.icon,
    this.strong,
    this.soft,
    this.chipText,
    this.word,
  );

  final IconData icon;
  final Color strong;
  final Color soft;
  final Color chipText;
  final String word;

  static const Map<StatusKind, StatusStyle> all = {
    StatusKind.normal: StatusStyle(
      Icons.check_circle,
      Color(0xFF2F7D57),
      Color(0xFFD5EFE1),
      Color(0xFF1B5E3F),
      'Normal',
    ),
    StatusKind.lowFlow: StatusStyle(
      Icons.trending_down,
      Color(0xFFA86F00),
      Color(0xFFFBE9C4),
      Color(0xFF7A4E00),
      'Low flow',
    ),
    StatusKind.noFlow: StatusStyle(
      Icons.block,
      Color(0xFFD4574A),
      Color(0xFFF9D9D4),
      Color(0xFF8A2A20),
      'No flow',
    ),
    StatusKind.offline: StatusStyle(
      Icons.cloud_off,
      Color(0xFF6B7682),
      Color(0xFFE2E6EA),
      Color(0xFF4A5561),
      'Offline',
    ),
    StatusKind.lowBattery: StatusStyle(
      Icons.battery_alert,
      Color(0xFFA86F00),
      Color(0xFFFBE9C4),
      Color(0xFF7A4E00),
      'Low battery',
    ),
    StatusKind.paused: StatusStyle(
      Icons.notifications_paused,
      Color(0xFF4C6670),
      Color(0xFFE2E6EA),
      Color(0xFF4A5561),
      'Alerts paused',
    ),
    StatusKind.waiting: StatusStyle(
      Icons.hourglass_empty,
      Color(0xFF4C6670),
      Color(0xFFE2E6EA),
      Color(0xFF4A5561),
      'Waiting for first reading',
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
  static const cardRadius = 16.0;
}

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.primary).copyWith(
    primary: AppColors.primary,
    onPrimary: AppColors.onPrimary,
    secondary: AppColors.secondary,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.textMuted,
    surfaceContainerHighest: AppColors.surfaceAlt,
    outline: AppColors.outline,
  );
  const base = TextTheme(
    bodySmall: TextStyle(fontSize: 12),
    bodyMedium: TextStyle(fontSize: 14),
    bodyLarge: TextStyle(fontSize: 16),
    titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    textTheme: base.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpace.cardRadius),
        side: const BorderSide(color: AppColors.outline),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceAlt,
      border: OutlineInputBorder(),
    ),
    materialTapTargetSize: MaterialTapTargetSize.padded,
    focusColor: AppColors.primary.withValues(alpha: 0.24),
  );
}
