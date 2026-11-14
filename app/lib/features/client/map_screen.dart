import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/places.dart';
import '../../data/pipeline_logic.dart';
import '../../data/providers.dart';
import 'map_tiles.dart';
import 'place_search.dart';
import 'widgets.dart';

/// Map (docs/UI_UX_SPEC.md 4.4, D26, D33, D37): the pipeline as a pipe line from
/// the source through its devices to the end point, pins in status colours,
/// and the segment where water stops drawn as a red dashed break.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key, this.focusProblem = false});

  /// Opened from a batched push: centre on the problem segment (D37).
  final bool focusProblem;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _map = MapController();
  bool _tileError = false;
  bool _ready = false;
  bool _fitted = false;
  String? _googleCopyright;

  /// The place picked from a search and the phone's own position, if asked for.
  Place? _picked;
  LatLng? _me;

  void _onError() {
    if (!_tileError && mounted) setState(() => _tileError = true);
  }

  Future<void> _refreshCopyright() async {
    final session = ref.read(googleSessionProvider).valueOrNull;
    if (session == null || ref.read(mapViewProvider) != MapView.satellite) {
      return;
    }
    final b = _map.camera.visibleBounds;
    final text = await googleCopyright(
      session,
      LatLngBoundsLike(b.north, b.south, b.east, b.west),
      _map.camera.zoom.round(),
    );
    if (mounted && text != _googleCopyright) {
      setState(() => _googleCopyright = text);
    }
  }

  /// Fit every placed point once, or the problem segment when asked to (D37).
  void _fit(List<LatLng> all, List<LatLng> problem) {
    if (!_ready || _fitted) return;
    final target = widget.focusProblem && problem.length == 2 ? problem : all;
    if (target.isEmpty) return;
    _fitted = true;
    if (target.length == 1) {
      _map.move(target.single, AppConfig.mapDefaultZoom);
    } else {
      _map.fitCamera(
        CameraFit.coordinates(
          coordinates: target,
          padding: const EdgeInsets.all(AppConfig.mapFitPadding),
          maxZoom: 18,
        ),
      );
    }
  }

  void _showSheet(DeviceView v, int? position) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: GlassPanel(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.nickname, style: AppText.title(20)),
                const SizedBox(height: AppSpace.s),
                Wrap(
                  spacing: AppSpace.m,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip(v.status),
                    Text(
                      v.status == StatusKind.offline ||
                              v.device.flowRate == null
                          ? '– L/min'
                          : '${v.device.flowRate!.toStringAsFixed(1)} L/min',
                      style: AppText.strong,
                    ),
                  ],
                ),
                if (position != null) ...[
                  const SizedBox(height: AppSpace.s),
                  Text(
                    '${ordinal(position)} from the source',
                    style: AppText.note,
                  ),
                ],
                const SizedBox(height: AppSpace.l),
                PrimaryButton(
                  label: 'Details',
                  onPressed: () {
                    Navigator.pop(c);
                    context.go('/devices/${v.id}');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final views =
        ref.watch(fleetProvider).valueOrNull?.views ?? const <DeviceView>[];
    final pipeline = ref.watch(pipelineProvider);
    final view = ref.watch(mapViewProvider);
    final session = ref.watch(googleSessionProvider).valueOrNull;
    final p = pipeline.valueOrNull;
    final branch = p != null && p.branches.isNotEmpty ? p.branches.first : null;
    final ordered = branch == null ? <DeviceView>[] : inBranch(branch, views);
    final inPipe = {for (final v in ordered) v.id};
    final banner = branch == null ? null : mapBanner(branch, ordered);
    final stop = waterStops(ordered);
    final missing = views.where((v) => !v.hasLocation).length;
    final satellite = view == MapView.satellite && session != null;

    LatLng pt(DeviceView v) => LatLng(v.device.lat!, v.device.lng!);

    // The pipe: source -> placed devices in order -> end point.
    final path = <({LatLng at, int index})>[
      if (p != null) (at: LatLng(p.source.lat, p.source.lng), index: -1),
      for (final (i, v) in ordered.indexed)
        if (v.hasLocation) (at: pt(v), index: i),
      if (branch != null)
        (at: LatLng(branch.end.lat, branch.end.lng), index: ordered.length),
    ];
    final problem = <LatLng>[];
    final lines = <Polyline>[];
    for (var k = 1; k < path.length; k++) {
      final a = path[k - 1];
      final b = path[k];
      // Every segment from the last device with water up to the first faulty one.
      final broken =
          stop != null && a.index >= stop.fromIndex && a.index < stop.toIndex;
      final dry = stop != null && a.index >= stop.toIndex;
      if (broken) problem.addAll([a.at, b.at]);
      lines
        ..add(
          Polyline(
            points: [a.at, b.at],
            strokeWidth: 9,
            color: const Color(0xCCFFFFFF),
          ),
        )
        ..add(
          Polyline(
            points: [a.at, b.at],
            strokeWidth: 5,
            color: broken
                ? StatusStyle.of(StatusKind.noFlow).strong
                : dry
                ? const Color(0xFF9AA8B8)
                : AppColors.water,
            pattern: broken
                ? StrokePattern.dashed(segments: const [10, 8])
                : const StrokePattern.solid(),
          ),
        );
    }

    final placed = <LatLng>[
      for (final v in views)
        if (v.hasLocation) pt(v),
      if (p != null) LatLng(p.source.lat, p.source.lng),
      if (branch != null) LatLng(branch.end.lat, branch.end.lng),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit(placed, problem));

    final markers = <Marker>[
      if (_picked != null)
        Marker(
          point: _picked!.at,
          width: 40,
          height: 40,
          alignment: Alignment.topCenter,
          child: Semantics(
            container: true,
            label: 'Search result: ${_picked!.name}',
            child: const Icon(
              Icons.location_on_rounded,
              size: 40,
              color: AppColors.indigo,
            ),
          ),
        ),
      if (_me != null)
        Marker(point: _me!, width: 28, height: 28, child: const YouAreHere()),
      if (p != null)
        Marker(
          point: LatLng(p.source.lat, p.source.lng),
          width: 44,
          height: 44,
          child: Semantics(
            container: true,
            label: 'Source: ${p.source.name}',
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppSpace.tileRadius - 4),
                gradient: const LinearGradient(colors: AppColors.buttonStops),
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.water_rounded, color: Colors.white),
            ),
          ),
        ),
      if (branch != null)
        Marker(
          point: LatLng(branch.end.lat, branch.end.lng),
          width: 120,
          height: 34,
          child: Semantics(
            container: true,
            label: 'End point: ${branch.end.name}',
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xEBFFFFFF),
                  borderRadius: BorderRadius.circular(AppSpace.pill),
                  border: Border.all(color: AppColors.deepCyan),
                ),
                child: Text(
                  branch.end.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.strong.copyWith(fontSize: 12),
                ),
              ),
            ),
          ),
        ),
      for (final v in views)
        if (v.hasLocation)
          Marker(
            point: pt(v),
            width: 48,
            height: 48,
            child: Semantics(
              button: true,
              label: '${v.nickname}, ${StatusStyle.of(v.status).word}',
              child: GestureDetector(
                onTap: () => _showSheet(
                  v,
                  inPipe.contains(v.id) ? ordered.indexOf(v) + 1 : null,
                ),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: StatusStyle.of(v.status).strong,
                      border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: const [
                        BoxShadow(color: Color(0x330A1B2E), blurRadius: 6),
                      ],
                    ),
                    child: Icon(
                      StatusStyle.of(v.status).icon,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.l,
                AppSpace.l,
                AppSpace.s,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        p?.name ?? 'Map',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.title(26),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.s),
                  // Labelled, not a bare pencil: owners didn't read the icon.
                  // Shrinks instead of overflowing with large text sizes.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 170),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SecondaryButton(
                        label: 'Edit pipeline',
                        icon: Icons.edit_rounded,
                        onPressed: () => context.go('/map/edit'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (satelliteAvailable)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.l,
                  AppSpace.s,
                  AppSpace.l,
                  0,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _ViewToggle(
                    value: view,
                    onChanged: (v) {
                      ref.read(mapViewProvider.notifier).set(v);
                      setState(() => _tileError = false);
                      if (v == MapView.satellite) _refreshCopyright();
                    },
                  ),
                ),
              ),
            if (banner != null || _tileError)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.l,
                  AppSpace.s,
                  AppSpace.l,
                  0,
                ),
                child: AppBanner(
                  icon: _tileError
                      ? Icons.map_outlined
                      : StatusStyle.of(StatusKind.noFlow).icon,
                  color: _tileError
                      ? AppColors.steel
                      : StatusStyle.of(StatusKind.noFlow).strong,
                  text: _tileError ? Messages.mapFailed : banner!,
                ),
              ),
            const SizedBox(height: AppSpace.s),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.l,
                  0,
                  AppSpace.l,
                  96,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppSpace.cardRadius),
                  child: Stack(
                    children: [
                      FlutterMap(
                        mapController: _map,
                        options: MapOptions(
                          initialCenter: placed.isEmpty
                              ? const LatLng(12.88, 121.77) // the Philippines
                              : placed.first,
                          initialZoom: placed.isEmpty
                              ? 5
                              : AppConfig.mapDefaultZoom,
                          onMapReady: () {
                            _ready = true;
                            _fit(placed, problem);
                            _refreshCopyright();
                          },
                          onMapEvent: (e) {
                            if (e is MapEventMoveEnd ||
                                e is MapEventFlingAnimationEnd ||
                                e is MapEventDoubleTapZoomEnd) {
                              _refreshCopyright();
                            }
                          },
                        ),
                        children: [
                          satellite
                              ? googleSatelliteLayer(session, onError: _onError)
                              : osmLayer(onError: _onError),
                          PolylineLayer(polylines: lines),
                          MarkerLayer(markers: markers),
                          MapAttribution(
                            view: satellite ? MapView.satellite : MapView.map,
                            googleCopyright: _googleCopyright,
                          ),
                        ],
                      ),
                      Positioned(
                        left: AppSpace.m,
                        right: AppSpace.m,
                        top: AppSpace.m,
                        child: PlaceSearchBar(
                          onPick: (place) {
                            setState(() => _picked = place);
                            _map.move(place.at, AppConfig.placeZoom);
                          },
                        ),
                      ),
                      Positioned(
                        right: AppSpace.m,
                        bottom: 40,
                        child: MyLocationButton(
                          onFound: (at) {
                            setState(() => _me = at);
                            _map.move(at, AppConfig.placeZoom + 1);
                          },
                        ),
                      ),
                      if (pipeline.hasValue && p == null)
                        Positioned(
                          left: AppSpace.m,
                          right: 76,
                          bottom: 40,
                          child: GlassPanel(
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Draw your pipeline: set the source, then add a branch.',
                                    style: AppText.strong,
                                  ),
                                ),
                                const SizedBox(width: AppSpace.s),
                                PrimaryButton(
                                  label: 'Start',
                                  onPressed: () => context.go('/map/edit'),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (missing > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.l,
                  0,
                  AppSpace.l,
                  0,
                ),
                child: Transform.translate(
                  offset: const Offset(0, -88),
                  child: Text(
                    missing == 1
                        ? '1 device has no location yet. Set it in Edit pipeline.'
                        : '$missing devices have no location yet. Set them in Edit pipeline.',
                    style: AppText.note.copyWith(color: AppColors.ink),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Glass Map | Satellite toggle (docs/UI_UX_SPEC.md 4.4).
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.value, required this.onChanged});

  final MapView value;
  final ValueChanged<MapView> onChanged;

  @override
  Widget build(BuildContext context) => GlassPanel(
    radius: AppSpace.pill,
    padding: const EdgeInsets.all(4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final v in MapView.values)
          Semantics(
            button: true,
            selected: v == value,
            label: v == MapView.map ? 'Map' : 'Satellite',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppSpace.pill),
              onTap: () => onChanged(v),
              child: Container(
                constraints: const BoxConstraints(minHeight: 40, minWidth: 96),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppSpace.pill),
                  gradient: v == value
                      ? const LinearGradient(colors: AppColors.buttonStops)
                      : null,
                ),
                child: Text(
                  v == MapView.map ? 'Map' : 'Satellite',
                  style: AppText.strong.copyWith(
                    fontSize: 14,
                    color: v == value ? Colors.white : AppColors.ink,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
