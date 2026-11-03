// docs/UI_UX_SPEC.md section 2: every text pair at least 4.5:1, every icon pair 3:1.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/contrast.dart';
import 'package:hydro_sense/core/theme.dart';

void main() {
  test('contrast math matches known values', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(
      contrastRatio(AppColors.primary, AppColors.onPrimary),
      closeTo(5.0, 0.1),
    );
  });

  group('text pairs are at least 4.5:1', () {
    final pairs = <String, (Color, Color)>{
      'text on surface': (AppColors.text, AppColors.surface),
      'text on background': (AppColors.text, AppColors.background),
      'text on surfaceAlt': (AppColors.text, AppColors.surfaceAlt),
      'textMuted on surface': (AppColors.textMuted, AppColors.surface),
      'textMuted on background': (AppColors.textMuted, AppColors.background),
      'onPrimary on primary': (AppColors.onPrimary, AppColors.primary),
      'primary on surface (links)': (AppColors.primary, AppColors.surface),
      for (final e in StatusStyle.all.entries)
        '${e.key.name} chip text on its soft fill': (
          e.value.chipText,
          e.value.soft,
        ),
    };
    for (final p in pairs.entries) {
      test(p.key, () {
        expect(
          contrastRatio(p.value.$1, p.value.$2),
          greaterThanOrEqualTo(4.5),
          reason:
              '${p.key}: ${contrastRatio(p.value.$1, p.value.$2).toStringAsFixed(2)}:1',
        );
      });
    }
  });

  group('icon pairs are at least 3:1', () {
    for (final e in StatusStyle.all.entries) {
      final s = e.value;
      for (final bg in {
        'background': AppColors.background,
        'surface': AppColors.surface,
        'its soft fill': s.soft,
      }.entries) {
        test('${e.key.name} icon on ${bg.key}', () {
          expect(
            contrastRatio(s.strong, bg.value),
            greaterThanOrEqualTo(3.0),
            reason: contrastRatio(s.strong, bg.value).toStringAsFixed(2),
          );
        });
      }
      test('white icon on ${e.key.name} map pin', () {
        expect(
          contrastRatio(Colors.white, s.strong),
          greaterThanOrEqualTo(3.0),
          reason: contrastRatio(Colors.white, s.strong).toStringAsFixed(2),
        );
      });
    }
  });
}
