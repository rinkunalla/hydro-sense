import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/config.dart';

/// One search result (the searchPlace callable, OpenStreetMap Nominatim data).
class Place {
  const Place(this.name, this.lat, this.lng);

  final String name;
  final double lat;
  final double lng;

  LatLng get at => LatLng(lat, lng);
}

/// Place search. Searches run on a button tap, never while typing (Nominatim
/// usage policy); the backend caches results and keeps the request rate.
abstract class PlaceSearch {
  /// Throws FirebaseFunctionsException with QUERY_INVALID, SEARCH_OFF,
  /// SEARCH_BUSY or SEARCH_FAILED.
  Future<List<Place>> search(String query);
}

class FunctionsPlaceSearch implements PlaceSearch {
  FunctionsPlaceSearch(this._functions);

  final FirebaseFunctions _functions;

  @override
  Future<List<Place>> search(String query) async {
    final r = await _functions.httpsCallable('searchPlace').call<Object?>({
      'query': query,
    });
    final list = r.data is Map ? (r.data as Map)['places'] : null;
    return [
      if (list is List)
        for (final p in list)
          if (p is Map && p['lat'] is num && p['lng'] is num)
            Place(
              '${p['name']}',
              (p['lat'] as num).toDouble(),
              (p['lng'] as num).toDouble(),
            ),
    ];
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
