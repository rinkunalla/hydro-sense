import 'dart:math' as math;

import '../core/theme.dart';
import 'models.dart';
import 'pipeline.dart';

/// Great-circle distance in metres (haversine).
double distanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Default branch order: devices with a location by distance from the
/// source, nearest first; devices without one are listed after them (not placed).
List<DeviceView> defaultOrder(PipePoint source, Iterable<DeviceView> views) {
  double d(DeviceView v) =>
      distanceM(source.lat, source.lng, v.device.lat!, v.device.lng!);
  final located = views.where((v) => v.hasLocation).toList()
    ..sort((a, b) {
      final c = d(a).compareTo(d(b));
      return c != 0
          ? c
          : a.nickname.toLowerCase().compareTo(b.nickname.toLowerCase());
    });
  final missing = views.where((v) => !v.hasLocation).toList()
    ..sort(
      (a, b) => a.nickname.toLowerCase().compareTo(b.nickname.toLowerCase()),
    );
  return [...located, ...missing];
}

/// The branch's devices in their saved order; IDs no longer on the account are
/// skipped (a device can be reassigned away).
List<DeviceView> inBranch(Branch b, Iterable<DeviceView> views) {
  final byId = {for (final v in views) v.id: v};
  return [for (final id in b.deviceIds) ?byId[id]];
}

/// "1st", "2nd", "3rd", "4th", "11th", "21st" for "2nd from the source".
String ordinal(int n) {
  final t = n % 100;
  if (t >= 11 && t <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

/// Where water stops along one branch.
class WaterStop {
  const WaterStop({required this.fromIndex, required this.toIndex});

  /// Index in the ordered branch of the last device that still has water,
  /// or -1 when water stops right after the source.
  final int fromIndex;

  /// Index of the first device with Low or No Flow.
  final int toIndex;
}

/// Finds where water stops along an ordered branch:
/// the last Normal device before the first Low or No Flow device (or the
/// source), skipping Offline devices. Null when the branch has no problem.
WaterStop? waterStops(List<DeviceView> ordered) {
  var lastWater = -1; // the source until a Normal device is seen
  for (var i = 0; i < ordered.length; i++) {
    switch (ordered[i].status) {
      case StatusKind.normal:
        lastWater = i;
      case StatusKind.lowFlow || StatusKind.noFlow:
        return WaterStop(fromIndex: lastWater, toIndex: i);
      default:
        // Offline, waiting or not set up: no proof of water, no fault. Skip.
        break;
    }
  }
  return null;
}

/// "Problem on the Home branch · Water stops between North tank and Home line"
/// or the source wording when water stops right after it.
String? mapBanner(Branch b, List<DeviceView> ordered) {
  final stop = waterStops(ordered);
  if (stop == null) return null;
  final to = ordered[stop.toIndex].nickname;
  final from = stop.fromIndex < 0
      ? 'the source'
      : ordered[stop.fromIndex].nickname;
  return 'Problem on the ${b.end.name} branch · Water stops between $from and $to';
}

/// A map rotation in degrees, normalised to (-180, 180]; 0 is north up.
double normalRotation(double degrees) {
  var r = degrees % 360;
  if (r > 180) r -= 360;
  if (r <= -180) r += 360;
  return r;
}

/// Where "Source at the top" points the pipeline: the first branch's end
/// point, or the middle of the placed devices when there is no branch yet.
PipePoint? pipelineToward(Pipeline p, Iterable<DeviceView> views) {
  if (p.branches.isNotEmpty) return p.branches.first.end;
  final placed = [
    for (final v in views)
      if (v.hasLocation) v,
  ];
  if (placed.isEmpty) return null;
  final lat = placed.map((v) => v.device.lat!).reduce((a, b) => a + b);
  final lng = placed.map((v) => v.device.lng!).reduce((a, b) => a + b);
  return PipePoint('', lat / placed.length, lng / placed.length);
}

/// The map rotation (degrees, flutter_map's camera convention) that puts
/// [source] at the top of the screen with the pipeline running straight down
/// to [toward]. Works in Web Mercator, the projection the map draws in, so
/// "straight down" is exact on screen. Null when the two points coincide.
double? rotationForSourceAtTop(PipePoint source, PipePoint toward) {
  double rad(double d) => d * math.pi / 180;
  // Mercator x grows east, y grows north; on an unrotated screen y grows down.
  double mercY(double lat) => math.log(math.tan(math.pi / 4 + rad(lat) / 2));
  final dx = rad(toward.lng - source.lng);
  final dyScreen = -(mercY(toward.lat) - mercY(source.lat));
  if (dx.abs() < 1e-12 && dyScreen.abs() < 1e-12) return null;
  // Angle of the source -> toward vector from "straight down" (positive
  // toward the left of the screen). flutter_map's camera rotation turns the
  // drawing the other way, so the camera needs the negative (checked in
  // pipeline_test.dart with flutter_map's own MapCamera projection).
  final fromDown = math.atan2(-dx, dyScreen) * 180 / math.pi;
  return normalRotation(-fromDown);
}
