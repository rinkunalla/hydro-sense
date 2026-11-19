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
import '../../data/pipeline.dart';
import '../../data/pipeline_logic.dart';
import '../../data/places.dart';
import '../../data/providers.dart';
import 'map_tiles.dart';
import 'place_search.dart';

/// Edit pipeline. Everything is a local draft
/// until Save; leaving with changes asks first.
class EditPipelineScreen extends ConsumerStatefulWidget {
  const EditPipelineScreen({super.key});

  @override
  ConsumerState<EditPipelineScreen> createState() => _EditPipelineState();
}

/// A manual pin change waiting for Save: a point, or null to go back to GPS.
typedef PinChange = ({LatLng? at});

class _EditPipelineState extends ConsumerState<EditPipelineScreen> {
  bool _loaded = false;
  bool _dirty = false;
  bool _saving = false;
  final _name = TextEditingController();
  final _sourceName = TextEditingController();
  final _endName = TextEditingController();
  LatLng? _source;
  LatLng? _end;
  List<String> _order = [];
  final _pins = <String, PinChange>{};

  @override
  void dispose() {
    _name.dispose();
    _sourceName.dispose();
    _endName.dispose();
    super.dispose();
  }

  void _load(Pipeline? p, List<DeviceView> views) {
    if (_loaded) return;
    _loaded = true;
    _name.text = p?.name ?? 'My pipeline';
    _sourceName.text = p?.source.name ?? 'Main water tank';
    final b = p != null && p.branches.isNotEmpty ? p.branches.first : null;
    _endName.text = b?.end.name ?? 'End';
    _source = p == null ? null : LatLng(p.source.lat, p.source.lng);
    _end = b == null ? null : LatLng(b.end.lat, b.end.lng);
    final known =
        b?.deviceIds.where((id) => views.any((v) => v.id == id)) ?? [];
    final rest = views.where((v) => !known.contains(v.id));
    // Devices not in the saved branch yet join it in distance order.
    final restOrdered = _source == null
        ? rest.toList()
        : defaultOrder(
            PipePoint('', _source!.latitude, _source!.longitude),
            rest,
          );
    _order = [...known, ...restOrdered.map((v) => v.id)];
  }

  void _changed(VoidCallback f) => setState(() {
    f();
    _dirty = true;
  });

  /// The device's location as the draft sees it (pending pin first).
  LatLng? _locationOf(DeviceView v) {
    final pending = _pins[v.id];
    if (pending != null) {
      return pending.at ??
          (v.hasGps ? LatLng(v.device.gpsLat!, v.device.gpsLng!) : null);
    }
    return v.hasLocation ? LatLng(v.device.lat!, v.device.lng!) : null;
  }

  bool _isManual(DeviceView v) {
    final pending = _pins[v.id];
    return pending != null ? pending.at != null : v.device.manualPin;
  }

  // Above the tab bar, so nothing covers the map's own buttons.
  Future<PinResult?> _placePin(
    String title,
    LatLng? start,
    List<LatLng> near, {
    DeviceView? device,
  }) => Navigator.of(context, rootNavigator: true).push<PinResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PinPicker(
        title: title,
        start: start ?? (near.isNotEmpty ? near.first : null),
        forDevice: device != null,
        deviceGps: device != null && device.hasGps
            ? LatLng(device.device.gpsLat!, device.device.gpsLng!)
            : null,
      ),
    ),
  );

  void _sortByDistance(List<DeviceView> views) {
    if (_source == null) return;
    final byId = {for (final v in views) v.id: v};
    final draft = [
      for (final id in _order)
        if (byId[id] != null)
          DeviceView(
            Device(
              id: id,
              nickname: byId[id]!.nickname,
              lat: _locationOf(byId[id]!)?.latitude,
              lng: _locationOf(byId[id]!)?.longitude,
            ),
            byId[id]!.health,
          ),
    ];
    final sorted = defaultOrder(
      PipePoint('', _source!.latitude, _source!.longitude),
      draft,
    );
    _changed(() => _order = sorted.map((v) => v.id).toList());
  }

  Future<void> _save() async {
    final uid = ref.read(uidProvider);
    final name = _name.text.trim();
    if (uid == null) return;
    if (_source == null || _end == null) {
      showToast(context, 'Set the source and the end point on the map first.');
      return;
    }
    if (name.isEmpty ||
        _sourceName.text.trim().isEmpty ||
        _endName.text.trim().isEmpty) {
      showToast(
        context,
        'Give the pipeline, the source and the end point a name.',
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(repositoryProvider);
      for (final e in _pins.entries) {
        await repo.setManualPin(
          e.key,
          e.value.at?.latitude,
          e.value.at?.longitude,
        );
      }
      await repo.savePipeline(
        uid,
        Pipeline(
          name: _cut(name),
          source: PipePoint(
            _cut(_sourceName.text.trim()),
            _source!.latitude,
            _source!.longitude,
          ),
          branches: [
            Branch(
              id: 'b1',
              end: PipePoint(
                _cut(_endName.text.trim()),
                _end!.latitude,
                _end!.longitude,
              ),
              deviceIds: _order
                  .take(AppConfig.pipelineMaxDevicesPerBranch)
                  .toList(),
            ),
          ],
        ),
      );
      if (!mounted) return;
      _dirty = false;
      showToast(context, 'Pipeline saved');
      context.go('/map');
    } catch (_) {
      if (mounted) showToast(context, Messages.saveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _cut(String s) => s.length > 40 ? s.substring(0, 40) : s;

  Future<bool> _confirmDiscard() async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Discard your changes?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _leave() async {
    if (!_dirty || await _confirmDiscard()) {
      if (mounted) context.go('/map');
    }
  }

  @override
  Widget build(BuildContext context) {
    final views =
        ref.watch(fleetProvider).valueOrNull?.views ?? const <DeviceView>[];
    final pipeline = ref.watch(pipelineProvider);
    if (!pipeline.hasValue) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Padding(
          padding: EdgeInsets.all(AppSpace.l),
          child: SkeletonCard(height: 300),
        ),
      );
    }
    _load(pipeline.value, views);
    final byId = {for (final v in views) v.id: v};
    final ordered = [for (final id in _order) ?byId[id]];
    final near = [
      for (final v in ordered)
        if (_locationOf(v) != null) _locationOf(v)!,
    ];

    Widget point(
      String label,
      TextEditingController c,
      LatLng? at,
      ValueChanged<LatLng> set,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: c,
          maxLength: 40,
          decoration: InputDecoration(labelText: '$label name'),
          onChanged: (_) => _dirty = true,
        ),
        Text(
          at == null ? 'Not placed on the map yet' : 'Placed on the map',
          style: AppText.note,
        ),
        const SizedBox(height: AppSpace.s),
        Align(
          alignment: Alignment.centerLeft,
          child: SecondaryButton(
            label: at == null ? 'Set location' : 'Edit location',
            icon: Icons.edit_location_alt_outlined,
            onPressed: () async {
              final p = await _placePin(
                '${at == null ? 'Set' : 'Edit'} the ${label.toLowerCase()}',
                at,
                near,
              );
              if (p?.at != null) _changed(() => set(p!.at!));
            },
          ),
        ),
      ],
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.l,
              AppSpace.s,
              AppSpace.l,
              120,
            ),
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: _leave,
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text('Edit pipeline', style: AppText.title(24)),
                    ),
                  ),
                  PrimaryButton(label: 'Save', busy: _saving, onPressed: _save),
                ],
              ),
              const SizedBox(height: AppSpace.s),
              Text(
                'Water runs from the source, through each device in order, to the end point. Drag a device to change the order.',
                style: AppText.body.copyWith(color: AppColors.steel),
              ),
              const SizedBox(height: AppSpace.l),
              GlassPanel(
                child: TextField(
                  controller: _name,
                  maxLength: 40,
                  decoration: const InputDecoration(labelText: 'Pipeline name'),
                  onChanged: (_) => _dirty = true,
                ),
              ),
              const SizedBox(height: AppSpace.m),
              const SectionLabel('Source'),
              GlassPanel(
                child: point(
                  'Source',
                  _sourceName,
                  _source,
                  (p) => _source = p,
                ),
              ),
              const SizedBox(height: AppSpace.m),
              SectionLabel(
                'Branch to ${_endName.text.isEmpty ? 'the end point' : _endName.text}',
              ),
              GlassPanel(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.s,
                  AppSpace.m,
                  AppSpace.s,
                  AppSpace.m,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.s,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${ordered.length} ${ordered.length == 1 ? 'device' : 'devices'}',
                              style: AppText.strong,
                            ),
                          ),
                          TextButton(
                            onPressed: _source == null
                                ? null
                                : () => _sortByDistance(views),
                            child: const Text('Sort by distance'),
                          ),
                        ],
                      ),
                    ),
                    if (ordered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(AppSpace.s),
                        child: Text(
                          'No devices on your account yet.',
                          style: AppText.note,
                        ),
                      ),
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      onReorder: (from, to) => _changed(() {
                        final id = _order.removeAt(from);
                        _order.insert(to > from ? to - 1 : to, id);
                      }),
                      children: [
                        for (final (i, v) in ordered.indexed)
                          _DeviceRow(
                            key: ValueKey(v.id),
                            index: i,
                            view: v,
                            located: _locationOf(v) != null,
                            manual: _isManual(v),
                            onEdit: () async {
                              final p = await _placePin(
                                'Location of ${v.nickname}',
                                _locationOf(v),
                                near,
                                device: v,
                              );
                              if (p == null) return;
                              // Device GPS clears the manual pin.
                              _changed(
                                () => _pins[v.id] = (
                                  at: p.deviceGps ? null : p.at,
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.m),
              const SectionLabel('End point'),
              GlassPanel(
                child: point('End point', _endName, _end, (p) => _end = p),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    super.key,
    required this.index,
    required this.view,
    required this.located,
    required this.manual,
    required this.onEdit,
  });

  final int index;
  final DeviceView view;
  final bool located;
  final bool manual;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final where = !located
        ? 'No location yet'
        : manual
        ? 'Location set by you'
        : "Location from the device's GPS";
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.all(AppSpace.s),
              child: Icon(Icons.drag_indicator_rounded, color: AppColors.steel),
            ),
          ),
          SizedBox(
            width: 28,
            child: Text('${index + 1}', style: AppText.strong),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  view.nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.strong,
                ),
                Text(where, style: AppText.note),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 40),
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
                  label: Text(located ? 'Edit location' : 'Set location'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the picker chose: a point on the map (the pin, or the phone's
/// position), or "follow the device's own GPS" (clears a manual pin).
typedef PinResult = ({LatLng? at, bool deviceGps});

/// Edit location: move the map under the fixed centre mark and confirm, or
/// take the phone's position, or (devices only) the device's own GPS.
class PinPicker extends ConsumerStatefulWidget {
  const PinPicker({
    super.key,
    required this.title,
    this.start,
    this.forDevice = false,
    this.deviceGps,
  });

  final String title;
  final LatLng? start;

  /// Show "Use device GPS" (enabled only when the device has a fix).
  final bool forDevice;
  final LatLng? deviceGps;

  @override
  ConsumerState<PinPicker> createState() => _PinPickerState();
}

class _PinPickerState extends ConsumerState<PinPicker> {
  final _map = MapController();
  bool _locating = false;

  Future<void> _usePhone() async {
    setState(() => _locating = true);
    try {
      final at = await ref.read(myLocationProvider).current();
      if (mounted) {
        Navigator.pop<PinResult>(context, (at: at, deviceGps: false));
      }
    } on LocationError catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(mapViewProvider);
    final session = ref.watch(googleSessionProvider(view));
    final google = session.valueOrNull != null;
    final gps = widget.deviceGps;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(widget.title, style: AppText.title(20)),
        ),
        body: Stack(
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: widget.start ?? const LatLng(12.88, 121.77),
                initialZoom: widget.start == null ? 6 : 17,
                minZoom: AppConfig.mapMinZoom,
                maxZoom: AppConfig.mapMaxZoom,
              ),
              children: [
                baseLayer(session, view),
                if (gps != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: gps,
                        width: 22,
                        height: 22,
                        child: Semantics(
                          container: true,
                          label: "The device's GPS position",
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.royal,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                MapAttribution(google: google),
              ],
            ),
            const IgnorePointer(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 36),
                  child: Icon(
                    Icons.place_rounded,
                    size: 44,
                    color: AppColors.danger,
                  ),
                ),
              ),
            ),
            // Google place results only over Google tiles.
            if (google)
              Positioned(
                left: AppSpace.l,
                right: AppSpace.l,
                top: AppSpace.s,
                child: PlaceSearchBar(
                  near: () => _map.camera.center,
                  onPick: (p) => _map.move(p.at, AppConfig.placeZoom + 1),
                ),
              ),
            Positioned(
              left: AppSpace.l,
              right: AppSpace.l,
              bottom: AppSpace.xl,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: AppSpace.s,
                      runSpacing: AppSpace.s,
                      children: [
                        if (widget.forDevice && AppConfig.deviceGpsEnabled)
                          MapPillButton(
                            label: gps == null
                                ? 'No device GPS yet'
                                : 'Use device GPS',
                            icon: Icons.satellite_alt_rounded,
                            onTap: gps == null
                                ? null
                                : () => Navigator.pop<PinResult>(context, (
                                    at: null,
                                    deviceGps: true,
                                  )),
                          ),
                        MapPillButton(
                          label: "Use my phone's location",
                          icon: Icons.my_location_rounded,
                          busy: _locating,
                          onTap: _usePhone,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.m),
                    PrimaryButton(
                      label: 'Place the pin here',
                      onPressed: () => Navigator.pop<PinResult>(context, (
                        at: _map.camera.center,
                        deviceGps: false,
                      )),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
