import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';

/// A picked place: the suggestion's name and its location (D46).
class Place {
  const Place(this.name, this.lat, this.lng);

  final String name;
  final double lat;
  final double lng;

  LatLng get at => LatLng(lat, lng);
}

/// One live suggestion (Google Places autocomplete, through placeSuggest).
class PlaceSuggestion {
  const PlaceSuggestion(this.placeId, this.main, this.secondary);

  final String placeId;
  final String main;
  final String secondary;
}

/// A fresh Places session token (UUID v4, URL-safe). One per search: from the
/// first letter typed to the place picked, so Google bills it as one session.
String newPlacesSession([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Live place search. Both calls throw FirebaseFunctionsException with
/// QUERY_INVALID, SEARCH_OFF, SEARCH_FAILED, PLACES_USER_LIMIT or
/// PLACES_PROJECT_LIMIT.
abstract class PlaceSearch {
  Future<List<PlaceSuggestion>> suggest(
    String input,
    String session, {
    LatLng? near,
  });

  /// Ends the session: the picked place's location.
  Future<LatLng> locate(String placeId, String session);
}

class FunctionsPlaceSearch implements PlaceSearch {
  FunctionsPlaceSearch(this._functions);

  final FirebaseFunctions _functions;

  @override
  Future<List<PlaceSuggestion>> suggest(
    String input,
    String session, {
    LatLng? near,
  }) async {
    final r = await _functions.httpsCallable('placeSuggest').call<Object?>({
      'input': input,
      'sessionToken': session,
      if (near != null) 'near': {'lat': near.latitude, 'lng': near.longitude},
    });
    final list = r.data is Map ? (r.data as Map)['suggestions'] : null;
    return [
      if (list is List)
        for (final p in list)
          if (p is Map && p['placeId'] is String && p['main'] is String)
            PlaceSuggestion(
              p['placeId'] as String,
              p['main'] as String,
              (p['secondary'] as String?) ?? '',
            ),
    ];
  }

  @override
  Future<LatLng> locate(String placeId, String session) async {
    final r = await _functions.httpsCallable('placeLocation').call<Object?>({
      'placeId': placeId,
      'sessionToken': session,
    });
    final m = r.data as Map;
    return LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble());
  }
}

final placeSearchProvider = Provider<PlaceSearch>(
  (ref) => FunctionsPlaceSearch(
    FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion),
  ),
);

/// Why the phone's location is not available, each with its own wording.
enum LocationProblem { servicesOff, denied, blocked, unavailable }

class LocationError implements Exception {
  const LocationError(this.problem);

  final LocationProblem problem;

  String get message => switch (problem) {
    LocationProblem.servicesOff =>
      'Turn on Location in your phone settings, then try again.',
    LocationProblem.denied => 'Allow location to show where you are.',
    LocationProblem.blocked =>
      "Location is blocked for Hydro Sense. Allow it in the phone's app settings.",
    LocationProblem.unavailable =>
      "Couldn't find your location. Try again outdoors.",
  };
}

/// The phone's own position, asked for only when the person taps My location.
abstract class MyLocation {
  /// Throws [LocationError].
  Future<LatLng> current();
}

class GeolocatorLocation implements MyLocation {
  @override
  Future<LatLng> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationError(LocationProblem.servicesOff);
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const LocationError(LocationProblem.denied);
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationError(LocationProblem.blocked);
    }
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: AppConfig.myLocationTimeoutS),
        ),
      );
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      throw const LocationError(LocationProblem.unavailable);
    }
  }
}

final myLocationProvider = Provider<MyLocation>((ref) => GeolocatorLocation());
