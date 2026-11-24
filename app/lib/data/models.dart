import '../core/config.dart';
import '../core/theme.dart';

/// A device's flow sensor (D69); mirrors SENSORS in functions/src/config.ts.
enum SensorType {
  yfS201(
    'yf_s201',
    'YF-S201',
    starterLow: 0.2,
    starterNormal: 2.0,
    cutoffMin: 1.0,
    cutoffMax: 30,
  ),
  zjDn50(
    'zj_dn50',
    'ZJ-DN50',
    starterLow: 5,
    starterNormal: 20,
    cutoffMin: 10,
    cutoffMax: 150,
  );

  const SensorType(
    this.wire,
    this.label, {
    required this.starterLow,
    required this.starterNormal,
    required this.cutoffMin,
    required this.cutoffMax,
  });

  /// The value stored in `devices/{id}.sensorType`.
  final String wire;
  final String label;
  final double starterLow;
  final double starterNormal;

  /// The range the admin's own limit must stay in (the sensor's reliable range).
  final double cutoffMin;
  final double cutoffMax;

  /// A stored value; devices made before v3 have a YF-S201.
  static SensorType fromWire(Object? v) {
    for (final t in values) {
      if (t.wire == v) return t;
    }
    return yfS201;
  }
}

/// `devices/{id}`.
class Device {
  const Device({
    required this.id,
    required this.nickname,
    this.sensorType = SensorType.yfS201,
    this.flowStatus,
    this.flowRate,
    this.lat,
    this.lng,
    this.gpsLat,
    this.gpsLng,
    this.manualPin = false,
    this.lowFlowCutoff = 0.2,
    this.normalFlowCutoff = 2.0,
    this.userNormalCutoff,
    this.calibratedAt,
    this.statusChangedAt,
    this.abnormalSince,
  });

  final String id;

  /// The device's name, set by the admin (D63).
  final String nickname;
  final SensorType sensorType;
  final String?
  flowStatus; // "Normal Flow" | "Low Flow" | "No Flow" | null (no reading yet)
  final double? flowRate;

  /// Effective location: the manual pin, else the GPS fix, else null.
  final double? lat;
  final double? lng;

  /// The device's own GPS fix, kept so the user can go back to it.
  final double? gpsLat;
  final double? gpsLng;

  /// The effective location is a pin the user placed.
  final bool manualPin;
  final double lowFlowCutoff;
  final double normalFlowCutoff;

  /// The admin's own "Low flow below X L/min"; null = automatic.
  final double? userNormalCutoff;
  final DateTime? calibratedAt;

  /// The admin set the limit (a value the server would accept for this sensor).
  bool get ownLimit {
    final u = userNormalCutoff;
    return u != null && u >= sensorType.cutoffMin && u <= sensorType.cutoffMax;
  }

  /// The limits the device classifies with; mirrors the server's
  /// effectiveCutoffs (functions/src/lib/cutoffs.ts).
  ({double low, double normal}) get limits {
    if (ownLimit) {
      return (low: sensorType.starterLow, normal: userNormalCutoff!);
    }
    return lowFlowCutoff < normalFlowCutoff
        ? (low: lowFlowCutoff, normal: normalFlowCutoff)
        : (low: sensorType.starterLow, normal: sensorType.starterNormal);
  }

  final DateTime? statusChangedAt;

  /// Start of the current Low/No Flow stretch (kept across Low <-> No).
  final DateTime? abnormalSince;
}

/// `device_health/{id}`.
class Health {
  const Health({
    required this.id,
    this.online = false,
    this.lastSeen,
    this.batteryPercent,
    this.batteryVoltage,
    this.batteryFault = false,
    this.chargingStatus,
    this.lowVoltageSleep = false,
    this.rssi,
    this.firmware,
    this.registeredAt,
  });

  final String id;
  final bool online;
  final DateTime? lastSeen;
  final int? batteryPercent;
  final double? batteryVoltage;
  final bool batteryFault;
  final String? chargingStatus;
  final bool lowVoltageSleep;
  final int? rssi;
  final String? firmware;

  /// Null until the device first registers (assigned before delivery).
  final DateTime? registeredAt;

  bool get registered => registeredAt != null || lastSeen != null;
}

/// One device as the client sees it: `devices` and `device_health` joined by ID.
class DeviceView {
  const DeviceView(this.device, this.health);

  final Device device;
  final Health? health;

  String get id => device.id;
  String get nickname => device.nickname;

  /// Offline replaces the stale flow status; the phone clock never decides it.
  StatusKind get status {
    final h = health;
    if (h == null || !h.registered) return StatusKind.notSetUp;
    if (!h.online && h.lastSeen != null) return StatusKind.offline;
    switch (device.flowStatus) {
      case 'Normal Flow':
        return StatusKind.normal;
      case 'Low Flow':
        return StatusKind.lowFlow;
      case 'No Flow':
        return StatusKind.noFlow;
      default:
        return StatusKind.waiting;
    }
  }

  bool get isProblem =>
      status == StatusKind.noFlow || status == StatusKind.lowFlow;

  bool get lowBattery {
    final h = health;
    return h != null &&
        !h.batteryFault &&
        h.batteryPercent != null &&
        h.batteryPercent! < AppConfig.lowBatteryPercent;
  }

  bool get hasLocation => device.lat != null && device.lng != null;

  bool get hasGps => device.gpsLat != null && device.gpsLng != null;

  /// When the current problem started: abnormalSince for Low/No Flow,
  /// the last upload for Offline, otherwise null.
  DateTime? get since => switch (status) {
    StatusKind.noFlow || StatusKind.lowFlow => device.abnormalSince,
    StatusKind.offline => health?.lastSeen,
    _ => null,
  };

  /// The Live cue. Live while online: with Offline at 60 s on the
  /// server's clock a separate "Late" stage lasted only seconds and
  /// confused owners, so it was removed.
  Freshness freshnessAt(DateTime now) {
    final h = health;
    if (h == null || !h.registered) return Freshness.none;
    if (!h.online) return Freshness.offline;
    return h.lastSeen == null ? Freshness.none : Freshness.live;
  }
}

enum Freshness { live, offline, none }

/// `users/{uid}` of a staff member (D64). Read only: the admin changes it.
class UserProfile {
  const UserProfile({this.email, this.phone, this.displayName, this.username});

  final String? email;
  final String? phone;
  final String? displayName;
  final String? username;

  /// "Juan" from "Juan Dela Cruz", for "Welcome back, {first name}".
  String get firstName =>
      (displayName ?? '').trim().split(RegExp(r'\s+')).first;
}

/// The kinds of problem History records, in the order they matter.
enum ProblemType {
  noFlow('no_flow'),
  lowFlow('low_flow'),
  offline('offline'),
  batteryLow('battery_low');

  const ProblemType(this.wire);

  /// The value stored in `problems/{id}.type`.
  final String wire;

  static ProblemType? fromWire(String? v) {
    for (final t in values) {
      if (t.wire == v) return t;
    }
    return null;
  }
}

/// One `problems/{id}` record: a problem with a start and, once over, an end.
class Problem {
  const Problem({
    required this.id,
    required this.deviceId,
    required this.type,
    required this.startedAt,
    this.endedAt,
  });

  final String id;
  final String deviceId;
  final ProblemType type;
  final DateTime startedAt;

  /// Null while the problem is still going on.
  final DateTime? endedAt;

  bool get ongoing => endedAt == null;

  /// The end, or [now] while it is ongoing.
  DateTime endOr(DateTime now) => endedAt ?? now;

  /// True when the problem covers any part of [from, to).
  bool overlaps(DateTime from, DateTime to, DateTime now) =>
      startedAt.isBefore(to) && endOr(now).isAfter(from);
}

/// Every device of the organization, with whether it came from the offline cache.
class Fleet {
  const Fleet(this.views, {this.fromCache = false});

  final List<DeviceView> views;
  final bool fromCache;
}
