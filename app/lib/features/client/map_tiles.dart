import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/theme.dart';

// Map tiles (CLAUDE.md section 9, D26). Map view: OpenStreetMap under its tile
// policy (own User-Agent, visible attribution, no prefetch or offline use).
// Satellite: Google Map Tiles API, only when a key was passed at build time
// (--dart-define=GOOGLE_MAP_TILES_KEY=...); without one the toggle is hidden.

enum MapView { map, satellite }

const _viewKey = 'map_view';

/// The Map | Satellite choice, remembered on the phone (docs/UI_UX_SPEC.md 4.4).
class MapViewNotifier extends StateNotifier<MapView> {
  MapViewNotifier() : super(MapView.map) {
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_viewKey);
      if (mounted && saved == MapView.satellite.name && satelliteAvailable) {
        state = MapView.satellite;
      }
    } catch (_) {}
  }

  Future<void> set(MapView v) async {
    state = v;
    try {
      await (await SharedPreferences.getInstance()).setString(_viewKey, v.name);
    } catch (_) {}
  }
}

final mapViewProvider = StateNotifierProvider<MapViewNotifier, MapView>(
  (ref) => MapViewNotifier(),
);

bool get satelliteAvailable => AppConfig.googleMapTilesKey.isNotEmpty;

/// OSM asks for an app-specific User-Agent, not a library default.
final osmTileProvider = NetworkTileProvider(
  headers: {'User-Agent': AppConfig.tileUserAgent},
);

TileLayer osmLayer({VoidCallback? onError}) => TileLayer(
  urlTemplate: AppConfig.osmTileUrl,
  userAgentPackageName: AppConfig.osmUserAgentPackage,
  tileProvider: osmTileProvider,
  maxNativeZoom: 19,
  errorTileCallback: (_, _, _) => onError?.call(),
);

/// A Google Map Tiles session: about two weeks long, created with the key.
class GoogleSession {
  const GoogleSession(this.token, this.expiresAt);

  final String token;
  final DateTime expiresAt;
}

/// Creates or reuses a satellite session (Map Tiles API createSession).
Future<GoogleSession?> googleSatelliteSession({http.Client? client}) async {
  if (!satelliteAvailable) return null;
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('gsat_session');
    final until = prefs.getInt('gsat_expiry') ?? 0;
    // Renew a day early so a long-open map never uses an expired session.
    if (saved != null &&
        DateTime.fromMillisecondsSinceEpoch(
          until,
        ).isAfter(DateTime.now().add(const Duration(days: 1)))) {
      return GoogleSession(saved, DateTime.fromMillisecondsSinceEpoch(until));
    }
    final res = await (client ?? http.Client()).post(
      Uri.parse(
        'https://tile.googleapis.com/v1/createSession?key=${AppConfig.googleMapTilesKey}',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'mapType': 'satellite',
        'language': 'en-US',
        'region': 'PH',
        'scale': 'scaleFactor2x',
        'highDpi': true,
      }),
    );
    if (res.statusCode != 200) return null;
    final m = jsonDecode(res.body) as Map<String, dynamic>;
    final token = m['session'] as String;
    final expiry = DateTime.fromMillisecondsSinceEpoch(
      int.parse('${m['expiry']}') * 1000,
    );
    await prefs.setString('gsat_session', token);
    await prefs.setInt('gsat_expiry', expiry.millisecondsSinceEpoch);
    return GoogleSession(token, expiry);
  } catch (_) {
    return null;
  }
}

final googleSessionProvider = FutureProvider<GoogleSession?>(
  (ref) => googleSatelliteSession(),
);

TileLayer googleSatelliteLayer(
  GoogleSession s, {
  VoidCallback? onError,
}) => TileLayer(
  urlTemplate:
      'https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}?session=${s.token}&key=${AppConfig.googleMapTilesKey}',
  userAgentPackageName: AppConfig.osmUserAgentPackage,
  tileDimension: 256,
  retinaMode: false,
  maxNativeZoom: 20,
  errorTileCallback: (_, _, _) => onError?.call(),
);

/// The copyright text Google requires for the tiles in view (viewport info).
Future<String?> googleCopyright(
  GoogleSession s,
  LatLngBoundsLike bounds,
  int zoom, {
  http.Client? client,
}) async {
  try {
    final uri = Uri.parse(
      'https://tile.googleapis.com/tile/v1/viewport'
      '?session=${s.token}&key=${AppConfig.googleMapTilesKey}&zoom=$zoom'
      '&north=${bounds.north}&south=${bounds.south}'
      '&east=${bounds.east}&west=${bounds.west}',
    );
    final res = await (client ?? http.Client()).get(uri);
    if (res.statusCode != 200) return null;
    return (jsonDecode(res.body) as Map<String, dynamic>)['copyright']
        as String?;
  } catch (_) {
    return null;
  }
}

/// North/south/east/west of the visible map, clamped to the API's ranges.
class LatLngBoundsLike {
  LatLngBoundsLike(double n, double s, double e, double w)
    : north = n.clamp(-89.9, 89.9),
      south = s.clamp(-89.9, 89.9),
      east = e.clamp(-179.9, 179.9),
      west = w.clamp(-179.9, 179.9);

  final double north;
  final double south;
  final double east;
  final double west;
}

/// Always-visible attribution (never hidden behind a button, OSM policy).
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key, required this.view, this.googleCopyright});

  final MapView view;
  final String? googleCopyright;

  @override
  Widget build(BuildContext context) {
    final osm = view == MapView.map;
    final text = osm
        ? '© OpenStreetMap contributors'
        : 'Google Maps${googleCopyright == null || googleCopyright!.isEmpty ? '' : ' · ${googleCopyright!}'}';
    return Align(
      alignment: Alignment.bottomRight,
      child: Semantics(
        link: osm,
        label: osm
            ? 'Map data © OpenStreetMap contributors'
            : 'Google Maps. $text',
        excludeSemantics: true,
        child: GestureDetector(
          onTap: osm
              ? () => launchUrl(
                  Uri.parse('https://www.openstreetmap.org/copyright'),
                  mode: LaunchMode.externalApplication,
                )
              : null,
          child: Container(
            margin: const EdgeInsets.all(AppSpace.xs),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xE6FFFFFF),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.note.copyWith(
                fontSize: 11,
                color: AppColors.ink,
                decoration: osm ? TextDecoration.underline : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
