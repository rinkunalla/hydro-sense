import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'theme.dart';

// Liquid glass components.

/// The OS "Remove animations" setting (Android) / "Reduce motion" (iOS).
bool reduceMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

const _solidGlassKey = 'solid_glass';

/// In-app "Solid glass" switch. Android has no reduce-transparency setting and
/// Flutter's highContrast flag is iOS-only, so the app offers its own (Account).
class SolidGlassNotifier extends StateNotifier<bool> {
  SolidGlassNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (mounted) state = p.getBool(_solidGlassKey) ?? false;
    } catch (_) {
      // No storage (tests): keep the default.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(
        _solidGlassKey,
        value,
      );
    } catch (_) {}
  }
}

final solidGlassProvider = StateNotifierProvider<SolidGlassNotifier, bool>(
  (ref) => SolidGlassNotifier(),
);

/// Glass becomes solid #F7F9FC when the person asked for it or the OS asks for
/// high contrast (iOS).
bool solidGlass(BuildContext context, WidgetRef ref) =>
    ref.watch(solidGlassProvider) ||
    (MediaQuery.maybeHighContrastOf(context) ?? false);

/// The cool silver-white page background with faint glows and bubble rings.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget ring(double size) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0x66FFFFFF), width: 1.5),
      ),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-0.35, -1),
          end: Alignment(0.35, 1),
          colors: AppColors.backgroundStops,
          stops: [0, 0.5, 1],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-0.8, -0.9),
                    radius: 0.9,
                    colors: [Color(0x1422C3DD), Color(0x0022C3DD)],
                  ),
                ),
              ),
            ),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0.9, 0.7),
                    radius: 0.8,
                    colors: [Color(0x104F46E5), Color(0x004F46E5)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 90,
            right: -20,
            child: IgnorePointer(child: ring(90)),
          ),
          Positioned(
            top: 300,
            left: -30,
            child: IgnorePointer(child: ring(60)),
          ),
          Positioned(
            bottom: 140,
            right: 30,
            child: IgnorePointer(child: ring(34)),
          ),
          child,
        ],
      ),
    );
  }
}

/// A glass panel: frosted gradient, 18 px blur, silver rim, soft shadow.
/// Never put one inside another (no glass on glass).
class GlassPanel extends ConsumerWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.l),
    this.radius = AppSpace.cardRadius,
    this.edge,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// A status-coloured edge for problem and offline cards.
  final Color? edge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final solid = solidGlass(context, ref);
    final shape = BorderRadius.circular(radius);
    final decoration = BoxDecoration(
      borderRadius: shape,
      color: solid ? AppColors.solidGlass : null,
      gradient: solid
          ? null
          : const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0x8CFFFFFF), Color(0x38FFFFFF), Color(0x57FFFFFF)],
              stops: [0, 0.55, 1],
            ),
      border: Border.all(
        color: edge ?? AppColors.rim,
        width: edge == null ? 1 : 2,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1A0A1B2E),
          blurRadius: 24,
          offset: Offset(0, 10),
        ),
      ],
    );
    final body = DecoratedBox(
      decoration: decoration,
      child: Padding(padding: padding, child: child),
    );
    if (solid) return body;
    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: body,
      ),
    );
  }
}

/// Section label: Inter SemiBold 12, upper case, letter-spaced, steel.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: AppSpace.s),
    child: Semantics(
      header: true,
      child: Text(text.toUpperCase(), style: AppText.label),
    ),
  );
}

/// The one primary action on a screen: gradient pill, white text, glow.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled || busy ? 1 : 0.5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpace.pill),
            gradient: const LinearGradient(
              colors: AppColors.buttonStops,
              stops: [0, 0.55, 1],
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x404F46E5),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppSpace.pill),
              onTap: enabled ? onPressed : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 50),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Center(
                    widthFactor: 1,
                    child: busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (icon != null) ...[
                                Icon(icon, color: Colors.white, size: 20),
                                const SizedBox(width: AppSpace.s),
                              ],
                              Flexible(
                                child: Text(
                                  label,
                                  textAlign: TextAlign.center,
                                  style: AppText.strong.copyWith(
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Near-white glossy pill with link-coloured text.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;

  /// White pill with a red edge and red text ("Remove", "Sign out").
  final bool destructive;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? AppColors.errorText : AppColors.link;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon == null ? null : Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        backgroundColor: const Color(0xE6FFFFFF),
        side: BorderSide(
          color: destructive ? AppColors.danger : const Color(0xE6FFFFFF),
        ),
        textStyle: AppText.strong.copyWith(fontSize: 15),
        minimumSize: const Size(48, 46),
        padding: const EdgeInsets.symmetric(horizontal: 18),
      ),
    );
  }
}

/// Things that stay true until fixed, at the top of a screen.
class AppBanner extends StatelessWidget {
  const AppBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    label: text,
    excludeSemantics: true,
    child: GlassPanel(
      radius: AppSpace.tileRadius + 4,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      edge: color,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: const BoxDecoration(
              color: Color(0xEBFFFFFF),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: AppSpace.m),
          Expanded(child: Text(text, style: AppText.strong)),
        ],
      ),
    ),
  );
}

/// Short result toast, gone in TOAST_S, with an optional action.
void showToast(
  BuildContext context,
  String text, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: AppConfig.toastS),
        action: actionLabel == null
            ? null
            : SnackBarAction(
                label: actionLabel,
                textColor: AppColors.water,
                onPressed: onAction ?? () {},
              ),
      ),
    );
}

/// Glass card with a soft shimmer, still under reduce motion. Lists never spin.
class SkeletonCard extends StatefulWidget {
  const SkeletonCard({super.key, this.height = 132});

  final double height;

  @override
  State<SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    child: GlassPanel(
      child: SizedBox(
        height: widget.height - 2 * AppSpace.l,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = reduceMotion(context) ? 0.5 : _c.value;
            Widget bar(double w) => FractionallySizedBox(
              widthFactor: w,
              child: Container(
                height: 14,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppSpace.pill),
                  gradient: LinearGradient(
                    begin: Alignment(-1 + 2 * t - 0.6, 0),
                    end: Alignment(-1 + 2 * t + 0.6, 0),
                    colors: const [
                      Color(0x66FFFFFF),
                      Color(0xCCFFFFFF),
                      Color(0x66FFFFFF),
                    ],
                  ),
                ),
              ),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [bar(0.5), bar(0.3), bar(0.7)],
            );
          },
        ),
      ),
    ),
  );
}
