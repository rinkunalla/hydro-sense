// Automated check: every text colour at least
// 4.5:1 and every icon 3:1 against glass at its thinnest (22 % white) and the chip
// fill (85 % white) over each background stop, plus white on the button gradient.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/contrast.dart';
import 'package:hydro_sense/core/theme.dart';

void main() {
  const stops = {
    'frost': AppColors.frost,
    'glacier': AppColors.glacier,
    'mist': AppColors.mist,
  };
  final surfaces = <String, Color>{
    for (final s in stops.entries) ...{
      'thin glass on ${s.key}': whiteOver(0.22, s.value),
      'chip fill on ${s.key}': whiteOver(0.85, s.value),
    },
    'solid glass': AppColors.solidGlass,
  };

  void atLeast(String name, Color fg, Color bg, double min) {
    test(name, () {
      final r = contrastRatio(fg, bg);
      expect(
        r,
        greaterThanOrEqualTo(min),
        reason: '$name: ${r.toStringAsFixed(2)}:1',
      );
    });
  }

  test('contrast math matches known values', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(whiteOver(1, Colors.black), const Color(0xFFFFFFFF));
    expect(whiteOver(0, AppColors.glacier), AppColors.glacier);
  });

  group('text is at least 4.5:1', () {
    for (final s in surfaces.entries) {
      atLeast('ink on ${s.key}', AppColors.ink, s.value, 4.5);
      atLeast('steel on ${s.key}', AppColors.steel, s.value, 4.5);
      atLeast('link on ${s.key}', AppColors.link, s.value, 4.5);
      atLeast('error text on ${s.key}', AppColors.errorText, s.value, 4.5);
    }
    atLeast(
      'error text on its fill',
      AppColors.errorText,
      AppColors.errorFill,
      4.5,
    );
    for (final (i, c) in AppColors.buttonStops.indexed) {
      atLeast('white on button stop $i', Colors.white, c, 4.5);
    }
    atLeast('white on the danger button', Colors.white, AppColors.danger, 4.5);
    // D68: a selected menu item, chip or tab is dark text on the pale tint.
    atLeast(
      'selected text on the action tint',
      AppColors.onActionTint,
      AppColors.actionTint,
      4.5,
    );
  });

  group('icons are at least 3:1', () {
    for (final s in stops.entries) {
      final chip = whiteOver(0.85, s.value);
      for (final e in StatusStyle.all.entries) {
        atLeast(
          '${e.key.name} icon on chip fill on ${s.key}',
          e.value.strong,
          chip,
          3,
        );
      }
      atLeast(
        'deep cyan icon on thin glass on ${s.key}',
        AppColors.deepCyan,
        whiteOver(0.22, s.value),
        3,
      );
    }
    for (final e in StatusStyle.all.entries) {
      atLeast(
        'white icon on ${e.key.name} pin',
        Colors.white,
        e.value.strong,
        3,
      );
    }
  });
}
