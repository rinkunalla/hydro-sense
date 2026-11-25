import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../client/map_screen.dart';

/// The website's first page: the app's own map with the pipeline (and Edit
/// pipeline for the admin), across the full width. Problems show on the map
/// (pin colours, the red break in the pipe) and in the alert banner above it;
/// tapping the banner, and old /map links, open this page centred on the
/// problem (D67, 2026-11-25).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    this.focusProblem = false,
    this.focusDevice,
  });

  /// Centre the map on the problem section of the pipeline.
  final bool focusProblem;

  /// Centre the map on this device and ring its pin.
  final String? focusDevice;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpace.l),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(AppSpace.cardRadius),
      child: MapScreen(focusProblem: focusProblem, focusDevice: focusDevice),
    ),
  );
}
