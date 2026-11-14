import '../core/config.dart';
import '../core/theme.dart';

/// `devices/{id}` (CLAUDE.md section 4).
class Device {
  const Device({
    required this.id,
    required this.nickname,
    this.flowStatus,
    this.flowRate,
    this.lat,
    this.lng,
    this.lowFlowCutoff = 0.2,
    this.normalFlowCutoff = 2.0,
    this.calibratedAt,
    this.statusChangedAt,
  });

  final String id;
  final String nickname;
  final String?
  flowStatus; // "Normal Flow" | "Low Flow" | "No Flow" | null (no reading yet)
  final double? flowRate;
  final double? lat;
  final double? lng;
  final double lowFlowCutoff;
  final double normalFlowCutoff;
  final DateTime? calibratedAt;
  final DateTime? statusChangedAt;
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
}

/// One device as the client sees it: `devices` and `device_health` joined by ID.
class DeviceView {
  const DeviceView(this.device, this.health);

  final Device device;
  final Health? health;

  String get id => device.id;
  String get nickname => device.nickname;

  /// Offline replaces the stale flow status (D9); the phone clock never decides it.
  StatusKind get status {
    final h = health;
    if (h != null && !h.online && h.lastSeen != null) return StatusKind.offline;
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
}

class StatusChange {
  const StatusChange(this.at, this.flowStatus);

  final DateTime at;
  final String flowStatus;
}

class UserProfile {
  const UserProfile({
    this.email,
    this.phone,
    this.displayName,
    this.mustChangePassword = false,
  });

  final String? email;
  final String? phone;
  final String? displayName;
  final bool mustChangePassword;
}

/// The client's fleet, with whether it came from the offline cache.
class Fleet {
  const Fleet(this.views, {this.fromCache = false});

  final List<DeviceView> views;
  final bool fromCache;
}
