import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import 'tile_cache.dart';
import '../../core/theme.dart';

// Map tiles. With a Google Map Tiles key
// (--dart-define=GOOGLE_MAP_TILES_KEY=...) both views are Google: road map and
// satellite. Place search (Google Places) may only be shown on a Google map,
// so it appears only while Google tiles are on screen. Without a key (tests,
// local builds) the Map view falls back to OpenStreetMap under its tile policy
// (own User-Agent, visible attribution) and the toggle and search are hidden.

enum MapView { map, satellite }

const _viewKey = 'map_view';

/// The Map | Satellite choice, remembered on the phone.
class MapViewNotifier extends StateNotifier<MapView> {
  MapViewNotifier() : super(MapView.map) {
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_viewKey);
      if (mounted && saved == MapView.satellite.name && googleTilesAvailable) {
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

bool get googleTilesAvailable => AppConfig.googleMapTilesKey.isNotEmpty;

/// OSM asks for an app-specific User-Agent, not a library default.
final osmTileProvider = NetworkTileProvider(
  httpClient: _tileClient,
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

/// Creates or reuses a session for one map type (Map Tiles API createSession).
/// Sessions last about two weeks and are kept on the phone, so opening the
/// map normally costs no extra request.
Future<GoogleSession?> googleSession(
  MapView view, {
  http.Client? client,
}) async {
  if (!googleTilesAvailable) return null;
  final type = view == MapView.map ? 'roadmap' : 'satellite';
  final keyToken = 'g_${type}_session';
  final keyExpiry = 'g_${type}_expiry';
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(keyToken);
    final until = prefs.getInt(keyExpiry) ?? 0;
    // Renew a day early so a long-open map never uses an expired session.
    if (saved != null &&
        DateTime.fromMillisecondsSinceEpoch(
          until,
        ).isAfter(DateTime.now().add(const Duration(days: 1)))) {
      return GoogleSession(saved, DateTime.fromMillisecondsSinceEpoch(until));
    }
    final res = await (client ?? _http).post(
      Uri.parse(
        'https://tile.googleapis.com/v1/createSession?key=${AppConfig.googleMapTilesKey}',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'mapType': type,
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
    await prefs.setString(keyToken, token);
    await prefs.setInt(keyExpiry, expiry.millisecondsSinceEpoch);
    return GoogleSession(token, expiry);
  } catch (_) {
    return null;
  }
}

/// One client for session and copyright requests.
final _http = http.Client();

final googleSessionProvider = FutureProvider.family<GoogleSession?, MapView>(
  (ref, view) => googleSession(view),
);

/// One long-lived connection for all tiles. flutter_map disposes a layer's
/// tile provider whenever the layer goes away (view switch, rebuild) and then
/// closes the provider's own client; a client passed in from outside is never
/// closed, so a later layer can't be left with a dead one (grey map).
// Wrapped in the phone's 24 h tile cache (Google allows max-age=86400).
final _tileClient = TileCacheClient(RetryClient(http.Client()));

/// Highest zoom with real tiles; the map zooms further by enlarging them.
/// Satellite imagery in rural areas often stops at 18.
const _roadmapMaxNative = 20;
const _satelliteMaxNative = 18;

TileLayer googleLayer(
  GoogleSession s,
  MapView view, {
  VoidCallback? onError,
}) => TileLayer(
  urlTemplate:
      'https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}?session=${s.token}&key=${AppConfig.googleMapTilesKey}',
  userAgentPackageName: AppConfig.osmUserAgentPackage,
  tileProvider: NetworkTileProvider(httpClient: _tileClient),
  // Each Google tile counts against the daily cap: load only what is on
  // screen (the default also loads a ring around it, about twice as many).
  panBuffer: 0,
  tileDimension: 256,
  retinaMode: false,
  maxNativeZoom: view == MapView.map ? _roadmapMaxNative : _satelliteMaxNative,
  errorTileCallback: (_, _, _) => onError?.call(),
);

/// The base map: Google once its session is ready; OpenStreetMap only when
/// there is no Google key or its session could not be made; nothing while it
/// loads (so the map never downloads OSM tiles just to replace them).
Widget baseLayer(
  AsyncValue<GoogleSession?> session,
  MapView view, {
  VoidCallback? onError,
}) {
  final s = session.valueOrNull;
  if (s != null) return googleLayer(s, view, onError: onError);
  if (googleTilesAvailable && session.isLoading) return const SizedBox.shrink();
  return osmLayer(onError: onError);
}

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
    final res = await (client ?? _http).get(uri);
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
  const MapAttribution({super.key, required this.google, this.googleCopyright});

  /// Google tiles are on screen (else OpenStreetMap).
  final bool google;
  final String? googleCopyright;

  @override
  Widget build(BuildContext context) {
    final osm = !google;
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
