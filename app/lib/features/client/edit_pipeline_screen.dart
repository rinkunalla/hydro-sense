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
import '../../data/providers.dart';
import 'map_tiles.dart';

/// Edit pipeline (docs/UI_UX_SPEC.md 4.5, D25, D26). Everything is a local draft
/// until Save; leaving with changes asks first. Stage 5a edits one branch.
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
    // Devices not in the saved branch yet join it in distance order (D26).
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

  Future<LatLng?> _placePin(String title, LatLng? start, List<LatLng> near) =>
      Navigator.of(context).push<LatLng>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => PinPicker(
            title: title,
            start: start ?? (near.isNotEmpty ? near.first : null),
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
        Row(
          children: [
            Expanded(
              child: Text(
                at == null ? 'Not placed on the map yet' : 'Placed on the map',
                style: AppText.note,
              ),
            ),
            SecondaryButton(
              label: 'Move pin',
              icon: Icons.place_outlined,
              onPressed: () async {
                final p = await _placePin(
                  'Place the ${label.toLowerCase()}',
                  at,
                  near,
                );
                if (p != null) _changed(() => set(p));
              },
            ),
          ],
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
                            onPin: () async {
                              final p = await _placePin(
                                'Place ${v.nickname}',
                                _locationOf(v),
                                near,
                              );
                              if (p != null) {
                                _changed(() => _pins[v.id] = (at: p));
                              }
                            },
                            onUseGps: _isManual(v) && v.hasGps
                                ? () => _changed(() => _pins[v.id] = (at: null))
                                : null,
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
    required this.onPin,
    this.onUseGps,
  });

  final int index;
  final DeviceView view;
  final bool located;
  final bool manual;
  final VoidCallback onPin;
  final VoidCallback? onUseGps;

  @override
  Widget build(BuildContext context) {
    final where = !located
        ? 'No location yet. Tap the pin to set it.'
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
                if (onUseGps != null)
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: onUseGps,
                    child: const Text('Use GPS instead'),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Set the location of ${view.nickname}',
            icon: Icon(
              located ? Icons.place_rounded : Icons.add_location_alt_outlined,
              color: AppColors.deepCyan,
            ),
            onPressed: onPin,
          ),
        ],
      ),
    );
  }
}

/// Places a pin: move the map under the fixed centre mark, then confirm.
class PinPicker extends ConsumerStatefulWidget {
  const PinPicker({super.key, required this.title, this.start});

  final String title;
  final LatLng? start;

  @override
  ConsumerState<PinPicker> createState() => _PinPickerState();
}

class _PinPickerState extends ConsumerState<PinPicker> {
  final _map = MapController();

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(mapViewProvider);
    final session = ref.watch(googleSessionProvider).valueOrNull;
    final satellite = view == MapView.satellite && session != null;
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
              ),
              children: [
                satellite ? googleSatelliteLayer(session) : osmLayer(),
                MapAttribution(
                  view: satellite ? MapView.satellite : MapView.map,
                ),
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
            Positioned(
              left: AppSpace.l,
              right: AppSpace.l,
              bottom: AppSpace.xl,
              child: SafeArea(
                child: PrimaryButton(
                  label: 'Place the pin here',
                  onPressed: () => Navigator.pop(context, _map.camera.center),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
