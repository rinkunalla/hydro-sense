import 'dart:math' as math;
import 'dart:ui';

/// WCAG 2 relative luminance of an opaque color.
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2 contrast ratio, 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// White at [whiteAlpha] composited over an opaque [below]: what the eye sees
/// through glass (docs/UI_UX_SPEC.md section 2 measures at 22 % and 85 %).
Color whiteOver(double whiteAlpha, Color below) => Color.from(
  alpha: 1,
  red: whiteAlpha + (1 - whiteAlpha) * below.r,
  green: whiteAlpha + (1 - whiteAlpha) * below.g,
  blue: whiteAlpha + (1 - whiteAlpha) * below.b,
);
