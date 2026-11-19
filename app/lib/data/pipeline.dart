/// `pipelines/{uid}`: a source and its branches. Each
/// branch is the ordered list of devices from the source to its end point.
class PipePoint {
  const PipePoint(this.name, this.lat, this.lng);

  final String name;
  final double lat;
  final double lng;

  PipePoint copyWith({String? name, double? lat, double? lng}) =>
      PipePoint(name ?? this.name, lat ?? this.lat, lng ?? this.lng);
}

class Branch {
  const Branch({
    required this.id,
    required this.end,
    this.deviceIds = const [],
  });

  final String id;
  final PipePoint end;

  /// Ordered from the source to the end point.
  final List<String> deviceIds;

  Branch copyWith({PipePoint? end, List<String>? deviceIds}) => Branch(
    id: id,
    end: end ?? this.end,
    deviceIds: deviceIds ?? this.deviceIds,
  );

  Map<String, Object> toMap() => {
    'id': id,
    'endName': end.name,
    'endLat': end.lat,
    'endLng': end.lng,
    'deviceIds': deviceIds,
  };

  /// Defensive: the rules check sizes and types, not every list entry.
  static Branch? fromMap(Object? v) {
    if (v is! Map) return null;
    final lat = v['endLat'];
    final lng = v['endLng'];
    if (lat is! num || lng is! num) return null;
    return Branch(
      id: v['id'] is String ? v['id'] as String : 'b1',
      end: PipePoint(
        v['endName'] is String ? v['endName'] as String : 'End',
        lat.toDouble(),
        lng.toDouble(),
      ),
      deviceIds: [
        for (final id
            in (v['deviceIds'] is List ? v['deviceIds'] as List : const []))
          if (id is String) id,
      ],
    );
  }
}

class Pipeline {
  const Pipeline({
    required this.name,
    required this.source,
    this.branches = const [],
  });

  final String name;
  final PipePoint source;
  final List<Branch> branches;

  Pipeline copyWith({
    String? name,
    PipePoint? source,
    List<Branch>? branches,
  }) => Pipeline(
    name: name ?? this.name,
    source: source ?? this.source,
    branches: branches ?? this.branches,
  );

  /// Without updatedAt: the repository adds the server time the rules require.
  Map<String, Object> toMap() => {
    'name': name,
    'source': {'name': source.name, 'lat': source.lat, 'lng': source.lng},
    'branches': [for (final b in branches) b.toMap()],
  };

  static Pipeline? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final s = m['source'];
    if (s is! Map || s['lat'] is! num || s['lng'] is! num) return null;
    return Pipeline(
      name: m['name'] is String ? m['name'] as String : 'My pipeline',
      source: PipePoint(
        s['name'] is String ? s['name'] as String : 'Source',
        (s['lat'] as num).toDouble(),
        (s['lng'] as num).toDouble(),
      ),
      branches: [
        for (final b
            in (m['branches'] is List ? m['branches'] as List : const []))
          ?Branch.fromMap(b),
      ],
    );
  }
}
