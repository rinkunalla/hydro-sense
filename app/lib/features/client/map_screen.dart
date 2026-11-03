import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import 'widgets.dart';

/// OpenStreetMap with one pin per located device (docs/UI_UX_SPEC.md section 4.4).
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  bool _tileError = false;

  void _showSheet(DeviceView v) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(v.nickname, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpace.s),
              Row(
                children: [
                  StatusChip(v.status),
                  const SizedBox(width: AppSpace.m),
                  Text(
                    v.status == StatusKind.offline || v.device.flowRate == null
                        ? '- L/min'
                        : '${v.device.flowRate!.toStringAsFixed(1)} L/min',
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.l),
              FilledButton(
                onPressed: () {
                  Navigator.pop(c);
                  context.go('/devices/${v.id}');
                },
                child: const Text('Details'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final views =
        ref.watch(fleetProvider).valueOrNull?.views ?? const <DeviceView>[];
    final located = views.where((v) => v.hasLocation).toList();
    final missing = views.length - located.length;
    final points = [
      for (final v in located) LatLng(v.device.lat!, v.device.lng!),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Map')),
      body: Column(
        children: [
          if (_tileError)
            Container(
              width: double.infinity,
              color: AppColors.surfaceAlt,
              padding: const EdgeInsets.all(AppSpace.m),
              child: const Text(Messages.mapFailed),
            ),
          Expanded(
            child: points.isEmpty
                ? const Center(child: Text('No device has a location yet.'))
                : FlutterMap(
                    options: MapOptions(
                      initialCenter: points.first,
                      initialZoom: 15,
                      initialCameraFit: points.length > 1
                          ? CameraFit.coordinates(
                              coordinates: points,
                              padding: const EdgeInsets.all(48),
                              maxZoom: 17,
                            )
                          : null,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: AppConfig.osmTileUrl,
                        userAgentPackageName: AppConfig.osmUserAgentPackage,
                        errorTileCallback: (_, _, _) {
                          if (!_tileError && mounted) {
                            setState(() => _tileError = true);
                          }
                        },
                      ),
                      MarkerLayer(
                        markers: [
                          for (var i = 0; i < located.length; i++)
                            Marker(
                              point: points[i],
                              width: 48,
                              height: 48,
                              child: _Pin(
                                view: located[i],
                                onTap: () => _showSheet(located[i]),
                              ),
                            ),
                        ],
                      ),
                      const RichAttributionWidget(
                        attributions: [
                          TextSourceAttribution('OpenStreetMap contributors'),
                        ],
                      ),
                    ],
                  ),
          ),
          if (missing > 0)
            Padding(
              padding: const EdgeInsets.all(AppSpace.m),
              child: Text(
                missing == 1
                    ? '1 device has no location yet.'
                    : '$missing devices have no location yet.',
              ),
            ),
        ],
      ),
    );
  }
}

/// Strong status color with a white icon inside (contrast-tested).
class _Pin extends StatelessWidget {
  const _Pin({required this.view, required this.onTap});

  final DeviceView view;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = StatusStyle.of(view.status);
    return Semantics(
      button: true,
      label: '${view.nickname}, ${s.word.toLowerCase()}',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: s.strong,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Icon(s.icon, color: Colors.white, size: 26),
        ),
      ),
    );
  }
}
