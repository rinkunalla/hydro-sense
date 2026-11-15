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
/// Full-screen map (D46): the tab bar and the title hide, the map fills the
/// screen. Back or the button returns.
final mapFullscreenProvider = StateProvider<bool>((ref) => false);

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key, this.focusProblem = false, this.focusDevice});

  /// Opened from a batched push: centre on the problem segment (D37).
  final bool focusProblem;

  /// Opened from a device's "Show on map": centre on it and ring its pin.
  final String? focusDevice;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _map = MapController();
  bool _tileError = false;
  int _tileErrors = 0;

  /// Every placed point (devices, source, end point): where "Back" returns to.
  List<LatLng> _home = const [];

  /// The device the camera was last centred on for "Show on map".
  String? _centredOn;
  bool _mapReady = false;
  String? _googleCopyright;

  /// The place picked from a search and the phone's own position, if asked for.
  Place? _picked;

  void _onError() {
    _tileErrors++;
    if (!_tileError &&
        mounted &&
        _tileErrors >= AppConfig.mapTileErrorsForBanner) {
      setState(() => _tileError = true);
    }
  }

  Future<void> _refreshCopyright() async {
    final session = ref
        .read(googleSessionProvider(ref.read(mapViewProvider)))
        .valueOrNull;
    if (session == null) return;
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

  void _ready() {
    _mapReady = true;
    _refreshCopyright();
  }

  /// Back to the pipeline and devices after panning away.
  void _backHome() {
    if (_home.isEmpty) return;
    if (_home.length == 1) {
      _map.move(_home.single, AppConfig.mapDefaultZoom);
    } else {
      _map.fitCamera(
        CameraFit.coordinates(
          coordinates: _home,
          padding: const EdgeInsets.all(AppConfig.mapFitPadding),
          maxZoom: 18,
        ),
      );
    }
  }

  /// Opens straight on the devices (or the problem segment, D37), so the map
  /// never loads the whole country first and then jumps.
  MapOptions _options(List<LatLng> all, List<LatLng> problem, LatLng? device) {
    final target = device != null
        ? [device]
        : widget.focusProblem && problem.length == 2
        ? problem
        : all;
    if (device != null) _centredOn = widget.focusDevice;
    void onEvent(MapEvent e) {
      if (e is MapEventMoveEnd ||
          e is MapEventFlingAnimationEnd ||
          e is MapEventDoubleTapZoomEnd) {
        _refreshCopyright();
      }
    }

    if (target.length >= 2) {
      return MapOptions(
        initialCameraFit: CameraFit.coordinates(
          coordinates: target,
          padding: const EdgeInsets.all(AppConfig.mapFitPadding),
          maxZoom: 18,
        ),
        minZoom: AppConfig.mapMinZoom,
        maxZoom: AppConfig.mapMaxZoom,
        onMapReady: _ready,
        onMapEvent: onEvent,
      );
    }
    return MapOptions(
      initialCenter: target.isEmpty
          ? const LatLng(12.88, 121.77) // the Philippines
          : target.single,
      initialZoom: target.isEmpty
          ? 5
          : device != null
          ? AppConfig.placeZoom
          : AppConfig.mapDefaultZoom,
      minZoom: AppConfig.mapMinZoom,
      maxZoom: AppConfig.mapMaxZoom,
      onMapReady: _ready,
      onMapEvent: onEvent,
    );
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
    final session = ref.watch(googleSessionProvider(view));
    final google = session.valueOrNull != null;
    final full = ref.watch(mapFullscreenProvider);
    final loaded = ref.watch(fleetProvider).hasValue && pipeline.hasValue;
    ref.listen(googleSessionProvider(view), (_, next) {
      if (next.valueOrNull != null) _refreshCopyright();
    });
    final p = pipeline.valueOrNull;
    final branch = p != null && p.branches.isNotEmpty ? p.branches.first : null;
    final ordered = branch == null ? <DeviceView>[] : inBranch(branch, views);
    final inPipe = {for (final v in ordered) v.id};
    final banner = branch == null ? null : mapBanner(branch, ordered);
    final stop = waterStops(ordered);
    final missing = views.where((v) => !v.hasLocation).length;

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

    final placed = _home = <LatLng>[
      for (final v in views)
        if (v.hasLocation) pt(v),
      if (p != null) LatLng(p.source.lat, p.source.lng),
      if (branch != null) LatLng(branch.end.lat, branch.end.lng),
    ];

    // "Show on map" from a device's Details. The Map tab keeps its state, so
    // a map that is already open moves to the device instead of reopening.
    LatLng? focusAt;
    for (final v in views) {
      if (v.id == widget.focusDevice && v.hasLocation) focusAt = pt(v);
    }
    if (focusAt != null && _mapReady && _centredOn != widget.focusDevice) {
      _centredOn = widget.focusDevice;
      final at = focusAt;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _map.move(at, AppConfig.placeZoom),
      );
    }

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
            width: v.id == widget.focusDevice ? 64 : 48,
            height: v.id == widget.focusDevice ? 64 : 48,
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
                    // The device opened with "Show on map" gets a ring.
                    padding: EdgeInsets.all(v.id == widget.focusDevice ? 6 : 0),
                    decoration: v.id == widget.focusDevice
                        ? BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x334F46E5),
                            border: Border.all(
                              color: AppColors.indigo,
                              width: 3,
                            ),
                          )
                        : null,
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
          ),
    ];

    void setFull(bool v) => ref.read(mapFullscreenProvider.notifier).state = v;

    return PopScope(
      canPop: !full,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setFull(false);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!full)
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
                            // One way in: "Draw" until there is a pipeline.
                            label: p == null
                                ? 'Draw pipeline'
                                : 'Edit pipeline',
                            icon: Icons.edit_rounded,
                            onPressed: () => context.go('/map/edit'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (googleTilesAvailable)
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
                        setState(() {
                          _tileError = false;
                          _tileErrors = 0;
                          _googleCopyright = null;
                        });
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
                  padding: full
                      ? EdgeInsets.zero
                      : const EdgeInsets.fromLTRB(
                          AppSpace.l,
                          0,
                          AppSpace.l,
                          96,
                        ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      full ? 0 : AppSpace.cardRadius,
                    ),
                    child: Stack(
                      children: [
                        if (!loaded)
                          const Center(child: CircularProgressIndicator())
                        else
                          FlutterMap(
                            mapController: _map,
                            options: _options(placed, problem, focusAt),
                            children: [
                              baseLayer(session, view, onError: _onError),
                              PolylineLayer(polylines: lines),
                              MarkerLayer(markers: markers),
                              MapAttribution(
                                google: google,
                                googleCopyright: _googleCopyright,
                              ),
                            ],
                          ),
                        // Google place results only over Google tiles (D46).
                        if (google && loaded)
                          Positioned(
                            left: AppSpace.m,
                            right: AppSpace.m,
                            top: AppSpace.m,
                            child: PlaceSearchBar(
                              near: () => _map.camera.center,
                              onPick: (place) {
                                setState(() => _picked = place);
                                _map.move(place.at, AppConfig.placeZoom);
                              },
                            ),
                          ),
                        // Labelled, not bare icons: owners could not tell
                        // round icon buttons apart.
                        if (loaded)
                          Positioned(
                            right: AppSpace.m,
                            bottom: 40,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (_home.isNotEmpty) ...[
                                  MapPillButton(
                                    label: p == null
                                        ? 'My devices'
                                        : 'My pipeline',
                                    icon: Icons.filter_center_focus_rounded,
                                    onTap: _backHome,
                                  ),
                                  const SizedBox(height: AppSpace.s),
                                ],
                                MapPillButton(
                                  label: full
                                      ? 'Exit full screen'
                                      : 'Full screen',
                                  icon: full
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                  onTap: () => setFull(!full),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (missing > 0 && !full)
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
